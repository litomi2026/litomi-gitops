#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SKIP_PUBLIC_CHECK=false
MANAGEMENT_KUBECTL_ARGS=()
MANAGEMENT_VAULT_ENDPOINT=""
CURRENT_KUBECTL_ARGS=()

usage() {
  cat <<'EOF'
Usage: scripts/verify-platform.sh --management-inventory <path> [common flags]

Verifies the fixed multi-cluster GitOps topology:
- management cluster Argo CD bootstrap and central ops stack readiness
- remote cluster registration labels and parent Applications
- environment-runtime clusters: core + agent stack, env-local Redis, and public exposure
EOF
  usage_common_flags
  cat <<'EOF'
Extra flags:
  --skip-public-check   Skip workload ingress hostname checks.
EOF
}

parse_verify_args() {
  local remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-public-check)
        SKIP_PUBLIC_CHECK=true
        shift
        ;;
      *)
        remaining+=("$1")
        shift
        ;;
    esac
  done

  parse_common_args "${remaining[@]}"
}

check_ready_condition() {
  local description="$1"
  local namespace="$2"
  local resource_type="$3"
  shift 3
  local kubectl_args=("$@")
  local output

  output="$(kubectl "${kubectl_args[@]}" -n "${namespace}" get "${resource_type}" -o json 2>/dev/null)" || {
    warn "${description}: resource lookup failed"
    return 1
  }

  if ! jq -e '
    (.items | length) > 0 and
    all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' <<<"${output}" >/dev/null; then
    warn "${description}: not all resources are Ready"
    return 1
  fi

  log "${description}: Ready"
}

check_ready_pods() {
  local description="$1"
  local namespace="$2"
  local selector="$3"
  shift 3
  local kubectl_args=("$@")
  local output

  if [[ -n "${selector}" ]]; then
    output="$(kubectl "${kubectl_args[@]}" -n "${namespace}" get pods -l "${selector}" -o json 2>/dev/null)" || {
      warn "${description}: pod lookup failed"
      return 1
    }
  else
    output="$(kubectl "${kubectl_args[@]}" -n "${namespace}" get pods -o json 2>/dev/null)" || {
      warn "${description}: pod lookup failed"
      return 1
    }
  fi

  if ! jq -e '
    (.items | length) > 0 and
    all(.items[]; .status.phase == "Running" and all(.status.containerStatuses[]?; .ready == true))
  ' <<<"${output}" >/dev/null; then
    warn "${description}: pods are not all Ready"
    return 1
  fi

  log "${description}: Ready"
}

require_secret_keys() {
  local namespace="$1"
  local secret_name="$2"
  shift 2
  local expected_keys=("$@")
  local secret_json
  local key_name

  secret_json="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n "${namespace}" get secret "${secret_name}" -o json)"

  for key_name in "${expected_keys[@]}"; do
    jq -e --arg key "${key_name}" '.data[$key] // empty' <<<"${secret_json}" >/dev/null || {
      die "Secret ${namespace}/${secret_name} is missing key ${key_name}"
    }
  done
}

decode_secret_value() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  local encoded

  encoded="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n "${namespace}" get secret "${secret_name}" -o "jsonpath={.data.${key_name}}")"
  [[ -n "${encoded}" ]] || die "Secret ${namespace}/${secret_name} is missing encoded key ${key_name}"
  printf '%s' "${encoded}" | base64_decode
}

assert_jsonpath_equals() {
  local description="$1"
  local expected="$2"
  local jsonpath="$3"
  shift 3
  local actual

  actual="$("$@" -o "jsonpath=${jsonpath}")"
  [[ "${actual}" == "${expected}" ]] || die "${description}: expected '${expected}', got '${actual}'"
  log "${description}: ${actual}"
}

build_kubectl_args_from_inventory() {
  local inventory_file="$1"
  local kubeconfig_path kube_context

  kubeconfig_path="$(resolve_repo_path "$(inventory_kubeconfig "${inventory_file}")")"
  kube_context="$(inventory_context "${inventory_file}")"
  require_file "${kubeconfig_path}"

  local args=()
  args+=(--kubeconfig "${kubeconfig_path}")
  if [[ -n "${kube_context}" ]]; then
    args+=(--context "${kube_context}")
  fi

  printf '%s\n' "${args[@]}"
}

expected_public_hosts_for_environment() {
  local environment_name="$1"

  case "${environment_name}" in
    stg)
      cat <<'EOF'
stg.litomi.in
api-stg.litomi.in
img-stg.litomi.in
anal-stg.litomi.in
anal-preview-stg.litomi.in
EOF
      ;;
    prod)
      cat <<'EOF'
litomi.in
api.litomi.in
img.litomi.in
anal.litomi.in
anal-preview.litomi.in
EOF
      ;;
  esac
}

verify_management_cluster() {
  local management_kubectl_args=("$@")
  local root_json repo_secret_json owner_kind

  log "Checking management-cluster Argo CD"
  for resource_name in \
    deployment/argocd-server \
    deployment/argocd-repo-server \
    deployment/argocd-applicationset-controller \
    statefulset/argocd-application-controller \
    deployment/argocd-redis; do
    kubectl_wait_rollout_if_exists "argocd" "${resource_name}" "120s" "${management_kubectl_args[@]}"
  done

  root_json="$(kubectl "${management_kubectl_args[@]}" -n argocd get application root -o json)"
  log "root: sync=$(jq -r '.status.sync.status // "Unknown"' <<<"${root_json}") health=$(jq -r '.status.health.status // "Unknown"' <<<"${root_json}")"

  repo_secret_json="$(kubectl "${management_kubectl_args[@]}" -n argocd get secret github-repo-creds -o json)"
  [[ "$(jq -r '.metadata.labels["argocd.argoproj.io/secret-type"] // ""' <<<"${repo_secret_json}")" == "repo-creds" ]] || die "github-repo-creds is missing repo-creds label"
  [[ "$(jq -r '.data.githubAppID // empty' <<<"${repo_secret_json}")" != "" ]] || die "github-repo-creds is missing githubAppID"
  [[ "$(jq -r '.data.githubAppInstallationID // empty' <<<"${repo_secret_json}")" != "" ]] || die "github-repo-creds is missing githubAppInstallationID"
  [[ "$(jq -r '.data.githubAppPrivateKey // empty' <<<"${repo_secret_json}")" != "" ]] || die "github-repo-creds is missing githubAppPrivateKey"

  if [[ "$(jq -r '.data.username // empty' <<<"${repo_secret_json}")" != "" ]] || [[ "$(jq -r '.data.password // empty' <<<"${repo_secret_json}")" != "" ]]; then
    warn "github-repo-creds still exposes username/password fields; expected GitHub App credentials only"
  fi

  owner_kind="$(jq -r '.metadata.ownerReferences[0].kind // empty' <<<"${repo_secret_json}")"
  if [[ "${owner_kind}" == "ExternalSecret" ]]; then
    log "Repo credentials are owned by ExternalSecret"
  else
    warn "Repo credentials exist but are not yet owned by ExternalSecret"
  fi

  check_ready_pods "Vault pods" "vault" "" "${management_kubectl_args[@]}" || true
  check_ready_pods "MinIO tenant pods" "minio" "v1.min.io/tenant=minio" "${management_kubectl_args[@]}" || true
  check_ready_pods "Monitoring pods" "monitoring" "" "${management_kubectl_args[@]}" || true
  check_ready_pods "Logging pods" "logging" "" "${management_kubectl_args[@]}" || true
  check_ready_pods "Tracing pods" "tracing" "" "${management_kubectl_args[@]}" || true
  check_ready_pods "Velero pods" "velero" "" "${management_kubectl_args[@]}" || true

  assert_jsonpath_equals \
    "Vault ready replicas" \
    "1" \
    '{.status.readyReplicas}' \
    kubectl "${management_kubectl_args[@]}" -n vault get statefulset vault

  for ns in argocd minio monitoring logging tracing velero; do
    check_ready_condition "Management SecretStores in ${ns}" "${ns}" "secretstore" "${management_kubectl_args[@]}" || true
    assert_jsonpath_equals \
      "Management ${ns} Vault endpoint" \
      "${MANAGEMENT_VAULT_ENDPOINT}" \
      '{.spec.provider.vault.server}' \
      kubectl "${management_kubectl_args[@]}" -n "${ns}" get secretstore vault
  done

  require_kubectl_connectivity "management" "${management_kubectl_args[@]}"
}

verify_cluster_registration() {
  local cluster_name="$1"
  local cluster_role="$2"
  local environment_name="$3"
  local cluster_class="$4"
  local control_plane_mode="$5"
  local cluster_secret_json

  cluster_secret_json="$(kubectl "${MANAGEMENT_KUBECTL_ARGS[@]}" -n argocd get secret "${cluster_name}" -o json)"
  [[ "$(jq -r '.metadata.labels.role // ""' <<<"${cluster_secret_json}")" == "${cluster_role}" ]] || die "Cluster secret ${cluster_name} has wrong role label"
  [[ "$(jq -r '.metadata.labels.environment // ""' <<<"${cluster_secret_json}")" == "${environment_name}" ]] || die "Cluster secret ${cluster_name} has wrong environment label"
  [[ "$(jq -r '.metadata.labels["litomi.io/cluster-class"] // ""' <<<"${cluster_secret_json}")" == "${cluster_class}" ]] || die "Cluster secret ${cluster_name} has wrong cluster class label"
  [[ "$(jq -r '.metadata.labels["litomi.io/control-plane-mode"] // ""' <<<"${cluster_secret_json}")" == "${control_plane_mode}" ]] || die "Cluster secret ${cluster_name} has wrong control plane mode label"
}

verify_environment_runtime_cluster() {
  local cluster_name="$1"
  local environment_name="$2"
  local public_hosts public_app public_api public_image public_gtm public_gtm_preview
  local ingress_hosts public_ingress_hosts gtm_ingress_hosts
  local backend_min_replicas web_min_replicas
  local backend_spread_count web_spread_count cloudflared_spread_count gtm_tagging_spread_count gtm_preview_spread_count
  local redis_pod_count redis_url traefik_ip priority_value

  kubectl_wait_rollout_if_exists "external-secrets" "deployment/external-secrets" "120s" "${CURRENT_KUBECTL_ARGS[@]}"
  kubectl_wait_rollout_if_exists "traefik" "deployment/traefik" "120s" "${CURRENT_KUBECTL_ARGS[@]}"

  check_ready_pods "${cluster_name} logging" "logging" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} tracing" "tracing" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} velero" "velero" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} litomi" "litomi" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} cloudflared" "cloudflared" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} gtm-server" "gtm-server" "" "${CURRENT_KUBECTL_ARGS[@]}" || true

  for ns in velero litomi cloudflared gtm-server; do
    check_ready_condition "${cluster_name} SecretStores in ${ns}" "${ns}" "secretstore" "${CURRENT_KUBECTL_ARGS[@]}" || true
    assert_jsonpath_equals \
      "${cluster_name} ${ns} Vault endpoint" \
      "${MANAGEMENT_VAULT_ENDPOINT}" \
      '{.spec.provider.vault.server}' \
      kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n "${ns}" get secretstore vault
  done

  require_secret_keys "velero" "velero-cloud-credentials" "cloud"
  require_secret_keys "litomi" "litomi-backend-secret" "REDIS_PASSWORD" "REDIS_URL"
  require_secret_keys "cloudflared" "cloudflared-token" "token"
  require_secret_keys "gtm-server" "gtm-server-secret" "CONTAINER_CONFIG"

  traefik_ip="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [[ -n "${traefik_ip}" ]] || die "${cluster_name} traefik Service has no LoadBalancer IP"
  log "${cluster_name} traefik LoadBalancer IP: ${traefik_ip}"

  case "${environment_name}" in
    prod)
      priority_value="100000"
      ;;
    stg|dev)
      priority_value="1000"
      ;;
    *)
      die "Unsupported runtime environment for ${cluster_name}: ${environment_name}"
      ;;
  esac

  assert_jsonpath_equals \
    "${cluster_name} litomi-runtime PriorityClass value" \
    "${priority_value}" \
    '{.value}' \
    kubectl "${CURRENT_KUBECTL_ARGS[@]}" get priorityclass litomi-runtime

  if [[ "${SKIP_PUBLIC_CHECK}" == "false" ]]; then
    mapfile -t public_hosts < <(expected_public_hosts_for_environment "${environment_name}")
    (( ${#public_hosts[@]} == 5 )) || die "Unsupported workload environment for public exposure checks: ${environment_name}"
    public_app="${public_hosts[0]}"
    public_api="${public_hosts[1]}"
    public_image="${public_hosts[2]}"
    public_gtm="${public_hosts[3]}"
    public_gtm_preview="${public_hosts[4]}"

    ingress_hosts="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get ingress litomi-internal -o json | jq -r '.spec.rules[].host')"
    grep -qx "app.${environment_name}.litomi.internal" <<<"${ingress_hosts}" || die "${cluster_name} internal ingress is missing app.${environment_name}.litomi.internal"
    grep -qx "api.${environment_name}.litomi.internal" <<<"${ingress_hosts}" || die "${cluster_name} internal ingress is missing api.${environment_name}.litomi.internal"
    log "${cluster_name} internal ingress hosts look correct"

    public_ingress_hosts="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get ingress litomi-public -o json | jq -r '.spec.rules[].host')"
    grep -qx "${public_app}" <<<"${public_ingress_hosts}" || die "${cluster_name} public ingress is missing ${public_app}"
    grep -qx "${public_api}" <<<"${public_ingress_hosts}" || die "${cluster_name} public ingress is missing ${public_api}"
    grep -qx "${public_image}" <<<"${public_ingress_hosts}" || die "${cluster_name} public ingress is missing ${public_image}"
    log "${cluster_name} public ingress hosts look correct"

    gtm_ingress_hosts="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get ingress gtm-server -o json | jq -r '.spec.rules[].host')"
    grep -qx "${public_gtm}" <<<"${gtm_ingress_hosts}" || die "${cluster_name} GTM ingress is missing ${public_gtm}"
    grep -qx "${public_gtm_preview}" <<<"${gtm_ingress_hosts}" || die "${cluster_name} GTM ingress is missing ${public_gtm_preview}"
    log "${cluster_name} GTM ingress hosts look correct"
  fi

  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get pdb litomi-backend >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get pdb litomi-web >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n cloudflared get pdb cloudflared >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get pdb gtm-server-tagging >/dev/null
  log "${cluster_name} PDBs exist for web/backend/cloudflared/gtm-server-tagging"

  backend_min_replicas="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get hpa litomi-backend -o jsonpath='{.spec.minReplicas}')"
  web_min_replicas="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get hpa litomi-web -o jsonpath='{.spec.minReplicas}')"
  [[ "${backend_min_replicas}" -ge 2 ]] || die "${cluster_name} backend minReplicas is below 2"
  [[ "${web_min_replicas}" -ge 2 ]] || die "${cluster_name} web minReplicas is below 2"

  backend_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get deployment litomi-backend -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  web_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get deployment litomi-web -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  cloudflared_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n cloudflared get deployment cloudflared -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  gtm_tagging_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get deployment gtm-server-tagging -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  gtm_preview_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get deployment gtm-server-preview -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  [[ "${backend_spread_count}" -ge 1 ]] || die "${cluster_name} backend is missing topologySpreadConstraints"
  [[ "${web_spread_count}" -ge 1 ]] || die "${cluster_name} web is missing topologySpreadConstraints"
  [[ "${cloudflared_spread_count}" -ge 1 ]] || die "${cluster_name} cloudflared is missing topologySpreadConstraints"
  [[ "${gtm_tagging_spread_count}" -ge 1 ]] || die "${cluster_name} gtm-server-tagging is missing topologySpreadConstraints"
  [[ "${gtm_preview_spread_count}" -ge 1 ]] || die "${cluster_name} gtm-server-preview is missing topologySpreadConstraints"
  log "${cluster_name} spread and HPA checks passed"

  assert_jsonpath_equals \
    "${cluster_name} gtm-server-preview replicas" \
    "1" \
    '{.spec.replicas}' \
    kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get deployment gtm-server-preview

  if kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get pdb gtm-server-preview >/dev/null 2>&1; then
    die "${cluster_name} gtm-server-preview should not have a PodDisruptionBudget"
  fi
  if kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get hpa gtm-server-preview >/dev/null 2>&1; then
    die "${cluster_name} gtm-server-preview should not have a HorizontalPodAutoscaler"
  fi
  log "${cluster_name} gtm-server-preview remains singleton without HPA/PDB"

  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get networkpolicy litomi-web-ingress >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get networkpolicy litomi-backend-ingress >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get networkpolicy redis-ingress >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n cloudflared get networkpolicy cloudflared-metrics-ingress >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get networkpolicy gtm-server-ingress >/dev/null
  log "${cluster_name} ingress NetworkPolicies exist for litomi/cloudflared/gtm-server/redis"

  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get service redis >/dev/null
  redis_pod_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get pods -l app.kubernetes.io/name=valkey,app.kubernetes.io/instance=redis -o json | jq '.items | length')"
  [[ "${redis_pod_count}" -ge 1 ]] || die "${cluster_name} local redis pod count is below 1"
  check_ready_pods "${cluster_name} redis" "litomi" "app.kubernetes.io/name=valkey,app.kubernetes.io/instance=redis" "${CURRENT_KUBECTL_ARGS[@]}" || true

  redis_url="$(decode_secret_value "litomi" "litomi-backend-secret" "REDIS_URL")"
  [[ "${redis_url}" == *"@redis:6379"* ]] || die "${cluster_name} REDIS_URL must point to env-local redis:6379"
  [[ "${redis_url}" != *".shared."* ]] || die "${cluster_name} REDIS_URL still points at shared-services"
  [[ "${redis_url}" != *".mgmt."* ]] || die "${cluster_name} REDIS_URL must not point at management"
  log "${cluster_name} uses env-local Redis without cross-cluster runtime dependency"

  if [[ "${environment_name}" == "stg" || "${environment_name}" == "dev" ]]; then
    kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get resourcequota litomi-runtime >/dev/null
    kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n cloudflared get resourcequota cloudflared-runtime >/dev/null
    kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n gtm-server get resourcequota gtm-server-runtime >/dev/null
    log "${cluster_name} non-prod quotas exist"
  fi
}

if ! parse_verify_args "$@"; then
  usage
  exit 0
fi

require_command kubectl jq yq base64
[[ -n "${MANAGEMENT_INVENTORY_FILE}" ]] || die "--management-inventory is required"

management_inventory="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
inventory_validate "${management_inventory}"

remote_inventories=()
if [[ -n "${INVENTORY_FILE}" ]]; then
  remote_inventories+=("$(resolve_repo_path "${INVENTORY_FILE}")")
fi
for remote_inventory in "${REMOTE_INVENTORY_FILES[@]}"; do
  remote_inventories+=("$(resolve_repo_path "${remote_inventory}")")
done
for remote_inventory in "${remote_inventories[@]}"; do
  inventory_validate "${remote_inventory}"
done

mapfile -t MANAGEMENT_KUBECTL_ARGS < <(build_kubectl_args_from_inventory "${management_inventory}")
require_kubectl_connectivity "management" "${MANAGEMENT_KUBECTL_ARGS[@]}"

management_internal_domain="$(inventory_internal_domain "${management_inventory}")"
MANAGEMENT_VAULT_ENDPOINT="https://vault.${management_internal_domain}"

verify_management_cluster "${MANAGEMENT_KUBECTL_ARGS[@]}"

for remote_inventory in "${remote_inventories[@]}"; do
  cluster_name="$(inventory_name "${remote_inventory}")"
  cluster_role="$(inventory_role "${remote_inventory}")"
  environment_name="$(inventory_environment "${remote_inventory}")"
  cluster_class="$(inventory_cluster_class "${remote_inventory}")"
  control_plane_mode="$(inventory_control_plane_mode "${remote_inventory}")"

  verify_cluster_registration "${cluster_name}" "${cluster_role}" "${environment_name}" "${cluster_class}" "${control_plane_mode}"

  app_json="$(kubectl "${MANAGEMENT_KUBECTL_ARGS[@]}" -n argocd get application "platform-${cluster_name}" -o json)"
  log "platform-${cluster_name}: sync=$(jq -r '.status.sync.status // "Unknown"' <<<"${app_json}") health=$(jq -r '.status.health.status // "Unknown"' <<<"${app_json}")"

  case "${cluster_class}" in
    environment-runtime)
      app_json="$(kubectl "${MANAGEMENT_KUBECTL_ARGS[@]}" -n argocd get application "litomi-${cluster_name}" -o json)"
      log "litomi-${cluster_name}: sync=$(jq -r '.status.sync.status // "Unknown"' <<<"${app_json}") health=$(jq -r '.status.health.status // "Unknown"' <<<"${app_json}")"
      ;;
    *)
      warn "Skipping unsupported remote cluster class for ${cluster_name}: ${cluster_class}"
      ;;
  esac

  mapfile -t CURRENT_KUBECTL_ARGS < <(build_kubectl_args_from_inventory "${remote_inventory}")
  require_kubectl_connectivity "${cluster_name}" "${CURRENT_KUBECTL_ARGS[@]}"

  case "${cluster_class}" in
    environment-runtime)
      verify_environment_runtime_cluster "${cluster_name}" "${environment_name}"
      ;;
  esac
done

if [[ "${SKIP_PUBLIC_CHECK}" == "true" ]]; then
  log "Public ingress hostname checks were skipped."
fi

log "Verification completed."
