#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SKIP_PUBLIC_CHECK=false

usage() {
  cat <<'EOF'
Usage: scripts/verify-platform.sh --management-inventory <path> [common flags]

Verifies the multi-cluster GitOps topology:
- management Argo CD bootstrap and repo credential takeover
- workload cluster registration labels and parent Applications
- central Vault SecretStore wiring
- central MinIO credential delivery for Loki/Tempo/Velero
- internal ingress, PDBs, HPAs, and addon-disabled defaults
EOF
  usage_common_flags
  cat <<'EOF'
Extra flags:
  --skip-public-check   Compatibility flag from the previous runbooks (ignored).
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

if ! parse_verify_args "$@"; then
  usage
  exit 0
fi

require_command kubectl jq yq
[[ -n "${MANAGEMENT_INVENTORY_FILE}" ]] || die "--management-inventory is required"

management_inventory="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
inventory_validate "${management_inventory}"

workload_inventories=()
if [[ -n "${INVENTORY_FILE}" ]]; then
  workload_inventories+=("$(resolve_repo_path "${INVENTORY_FILE}")")
fi
for workload_inventory in "${WORKLOAD_INVENTORY_FILES[@]}"; do
  workload_inventories+=("$(resolve_repo_path "${workload_inventory}")")
done
for workload_inventory in "${workload_inventories[@]}"; do
  inventory_validate "${workload_inventory}"
done

management_kubeconfig="$(resolve_repo_path "$(inventory_kubeconfig "${management_inventory}")")"
management_context="$(inventory_context "${management_inventory}")"
require_file "${management_kubeconfig}"

management_kubectl_args=()
management_kubectl_args+=(--kubeconfig "${management_kubeconfig}")
if [[ -n "${management_context}" ]]; then
  management_kubectl_args+=(--context "${management_context}")
fi

require_kubectl_connectivity "management" "${management_kubectl_args[@]}"

log "Checking management-cluster Argo CD"
for resource_name in \
  deployment/argocd-server \
  deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller \
  statefulset/argocd-application-controller \
  deployment/argocd-redis-ha-haproxy \
  statefulset/argocd-redis-ha-server; do
  kubectl_wait_rollout_if_exists "argocd" "${resource_name}" "120s" "${management_kubectl_args[@]}"
done

root_json="$(kubectl "${management_kubectl_args[@]}" -n argocd get application root -o json)"
log "root: sync=$(jq -r '.status.sync.status // "Unknown"' <<<"${root_json}") health=$(jq -r '.status.health.status // "Unknown"' <<<"${root_json}")"

repo_secret_json="$(kubectl "${management_kubectl_args[@]}" -n argocd get secret github-repo-creds -o json)"
[[ "$(jq -r '.metadata.labels["argocd.argoproj.io/secret-type"] // ""' <<<"${repo_secret_json}")" == "repo-creds" ]] || die "github-repo-creds is missing repo-creds label"

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
check_ready_pods "Velero pods" "velero" "" "${management_kubectl_args[@]}" || true

assert_jsonpath_equals \
  "Vault ready replicas" \
  "3" \
  '{.status.readyReplicas}' \
  kubectl "${management_kubectl_args[@]}" -n vault get statefulset vault

check_ready_condition "Argo CD SecretStores" "argocd" "secretstore" "${management_kubectl_args[@]}" || true
check_ready_condition "MinIO SecretStores" "minio" "secretstore" "${management_kubectl_args[@]}" || true
check_ready_condition "Management monitoring SecretStores" "monitoring" "secretstore" "${management_kubectl_args[@]}" || true
check_ready_condition "Management logging SecretStores" "logging" "secretstore" "${management_kubectl_args[@]}" || true
check_ready_condition "Management velero SecretStores" "velero" "secretstore" "${management_kubectl_args[@]}" || true

for workload_inventory in "${workload_inventories[@]}"; do
  cluster_name="$(inventory_name "${workload_inventory}")"
  environment_name="$(inventory_environment "${workload_inventory}")"
  public_edge="$(inventory_public_edge "${workload_inventory}")"
  expected_app_host="app.${environment_name}.litomi.internal"
  expected_api_host="api.${environment_name}.litomi.internal"

  cluster_secret_json="$(kubectl "${management_kubectl_args[@]}" -n argocd get secret "${cluster_name}" -o json)"
  [[ "$(jq -r '.metadata.labels.role // ""' <<<"${cluster_secret_json}")" == "workload" ]] || die "Cluster secret ${cluster_name} is missing role=workload"
  [[ "$(jq -r '.metadata.labels.environment // ""' <<<"${cluster_secret_json}")" == "${environment_name}" ]] || die "Cluster secret ${cluster_name} has wrong environment label"
  [[ "$(jq -r '.metadata.labels["litomi.io/addon-public-edge"] // ""' <<<"${cluster_secret_json}")" == "${public_edge}" ]] || die "Cluster secret ${cluster_name} has wrong public-edge label"

  for app_name in "platform-${cluster_name}" "litomi-${cluster_name}"; do
    app_json="$(kubectl "${management_kubectl_args[@]}" -n argocd get application "${app_name}" -o json)"
    log "${app_name}: sync=$(jq -r '.status.sync.status // "Unknown"' <<<"${app_json}") health=$(jq -r '.status.health.status // "Unknown"' <<<"${app_json}")"
  done

  if [[ "${public_edge}" == "enabled" ]]; then
    kubectl "${management_kubectl_args[@]}" -n argocd get application "public-edge-${cluster_name}" >/dev/null
    log "public-edge-${cluster_name}: present"
  else
    if kubectl "${management_kubectl_args[@]}" -n argocd get application "public-edge-${cluster_name}" >/dev/null 2>&1; then
      die "public-edge-${cluster_name} exists even though addon label is disabled"
    fi
    log "public-edge-${cluster_name}: correctly absent"
  fi

  workload_kubeconfig="$(resolve_repo_path "$(inventory_kubeconfig "${workload_inventory}")")"
  workload_context="$(inventory_context "${workload_inventory}")"
  require_file "${workload_kubeconfig}"

  CURRENT_KUBECTL_ARGS=()
  CURRENT_KUBECTL_ARGS+=(--kubeconfig "${workload_kubeconfig}")
  if [[ -n "${workload_context}" ]]; then
    CURRENT_KUBECTL_ARGS+=(--context "${workload_context}")
  fi

  require_kubectl_connectivity "${cluster_name}" "${CURRENT_KUBECTL_ARGS[@]}"

  kubectl_wait_rollout_if_exists "external-secrets" "deployment/external-secrets" "120s" "${CURRENT_KUBECTL_ARGS[@]}"
  kubectl_wait_rollout_if_exists "traefik" "deployment/traefik" "120s" "${CURRENT_KUBECTL_ARGS[@]}"

  check_ready_pods "${cluster_name} longhorn" "longhorn-system" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} monitoring" "monitoring" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} logging" "logging" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} tracing" "tracing" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} velero" "velero" "" "${CURRENT_KUBECTL_ARGS[@]}" || true
  check_ready_pods "${cluster_name} litomi" "litomi" "" "${CURRENT_KUBECTL_ARGS[@]}" || true

  for ns in monitoring logging tracing velero litomi; do
    check_ready_condition "${cluster_name} SecretStores in ${ns}" "${ns}" "secretstore" "${CURRENT_KUBECTL_ARGS[@]}" || true
    assert_jsonpath_equals \
      "${cluster_name} ${ns} Vault endpoint" \
      "https://vault.mgmt.litomi.internal" \
      '{.spec.provider.vault.server}' \
      kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n "${ns}" get secretstore vault
  done

  require_secret_keys "monitoring" "grafana-admin" "admin_user" "admin_password"
  require_secret_keys "logging" "loki-minio" "access_key" "secret_key" "bucket_chunks" "bucket_ruler"
  require_secret_keys "tracing" "tempo-minio" "access_key" "secret_key" "bucket_traces"
  require_secret_keys "velero" "velero-cloud-credentials" "cloud"
  require_secret_keys "litomi" "litomi-backend-secret"

  if [[ "${public_edge}" == "enabled" ]]; then
    require_secret_keys "cloudflared" "cloudflared-token" "token"
    require_secret_keys "gtm-server" "gtm-server-secret" "CONTAINER_CONFIG"
  fi

  traefik_ip="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [[ -n "${traefik_ip}" ]] || die "${cluster_name} traefik Service has no LoadBalancer IP"
  log "${cluster_name} traefik LoadBalancer IP: ${traefik_ip}"

  ingress_hosts="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get ingress litomi-internal -o json | jq -r '.spec.rules[].host')"
  grep -qx "${expected_app_host}" <<<"${ingress_hosts}" || die "${cluster_name} internal ingress is missing ${expected_app_host}"
  grep -qx "${expected_api_host}" <<<"${ingress_hosts}" || die "${cluster_name} internal ingress is missing ${expected_api_host}"
  log "${cluster_name} internal ingress hosts look correct"

  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get pdb litomi-backend >/dev/null
  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get pdb litomi-web >/dev/null
  log "${cluster_name} PDBs exist for web/backend"

  backend_min_replicas="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get hpa litomi-backend -o jsonpath='{.spec.minReplicas}')"
  web_min_replicas="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get hpa litomi-web -o jsonpath='{.spec.minReplicas}')"
  [[ "${backend_min_replicas}" -ge 2 ]] || die "${cluster_name} backend minReplicas is below 2"
  [[ "${web_min_replicas}" -ge 2 ]] || die "${cluster_name} web minReplicas is below 2"

  backend_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get deployment litomi-backend -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  web_spread_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get deployment litomi-web -o json | jq '.spec.template.spec.topologySpreadConstraints | length')"
  [[ "${backend_spread_count}" -ge 1 ]] || die "${cluster_name} backend is missing topologySpreadConstraints"
  [[ "${web_spread_count}" -ge 1 ]] || die "${cluster_name} web is missing topologySpreadConstraints"
  log "${cluster_name} spread and HPA checks passed"

  kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get service redis >/dev/null
  redis_pod_count="$(kubectl "${CURRENT_KUBECTL_ARGS[@]}" -n litomi get pods -l app.kubernetes.io/instance=redis-ha -o json | jq '.items | length')"
  [[ "${redis_pod_count}" -ge 3 ]] || die "${cluster_name} redis-ha pod count is below 3"
  log "${cluster_name} redis-ha footprint looks healthy"
done

if [[ "${SKIP_PUBLIC_CHECK}" == "true" ]]; then
  log "Compatibility flag --skip-public-check was provided and ignored."
fi

log "Verification completed."
