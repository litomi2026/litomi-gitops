#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

SKIP_PUBLIC_CHECK=false

usage() {
  cat <<'EOF'
Usage: scripts/verify-platform.sh [common flags] [--skip-public-check]

Checks management-cluster Argo CD health, repo credentials, workload-cluster
registration, ESO/Vault-related readiness, and a small set of platform signals.
EOF
  usage_common_flags
  cat <<'EOF'
Extra flags:
  --skip-public-check   Reserved compatibility flag from the old runbooks.
EOF
}

parse_verify_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-public-check)
        SKIP_PUBLIC_CHECK=true
        shift
        ;;
      *)
        remaining_args+=("$1")
        shift
        ;;
    esac
  done
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
    if (.items | length) == 0 then false
    else all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    end
  ' <<<"${output}" >/dev/null; then
    warn "${description}: not all resources are Ready"
    return 1
  fi

  log "${description}: Ready"
  return 0
}

remaining_args=()
parse_verify_args "$@"

if ! parse_common_args "${remaining_args[@]}"; then
  usage
  exit 0
fi

load_config_file
require_command kubectl jq

management_kubeconfig="${MANAGEMENT_KUBECONFIG:-${KUBECONFIG_PATH}}"
management_context="${MANAGEMENT_CONTEXT:-${KUBE_CONTEXT}}"
workload_kubeconfig="${WORKLOAD_KUBECONFIG:-${management_kubeconfig}}"
workload_context="${WORKLOAD_CONTEXT:-${management_context}}"
argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
cluster_name="${CLUSTER_NAME:-${WORKLOAD_CLUSTER_NAME:-}}"
cluster_secret_name="${CLUSTER_SECRET_NAME:-${cluster_name}}"
repo_secret_name="${BOOTSTRAP_REPO_SECRET_NAME:-github-repo-creds}"

if [[ -n "${management_kubeconfig}" ]]; then
  management_kubeconfig="$(resolve_repo_path "${management_kubeconfig}")"
  require_file "${management_kubeconfig}"
fi

if [[ -n "${workload_kubeconfig}" ]]; then
  workload_kubeconfig="$(resolve_repo_path "${workload_kubeconfig}")"
  require_file "${workload_kubeconfig}"
fi

declare -a management_kubectl_args workload_kubectl_args
setup_kubectl_args management_kubectl_args "${management_kubeconfig}" "${management_context}"
setup_kubectl_args workload_kubectl_args "${workload_kubeconfig}" "${workload_context}"

require_kubectl_connectivity "management" "${management_kubectl_args[@]}"
require_kubectl_connectivity "workload" "${workload_kubectl_args[@]}"

log "Checking Argo CD workloads"
for deployment_name in deployment/argocd-server deployment/argocd-repo-server deployment/argocd-applicationset-controller; do
  kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" rollout status "${deployment_name}" --timeout=60s >/dev/null
done
kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" rollout status statefulset/argocd-application-controller --timeout=60s >/dev/null

root_json="$(kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get application root -o json)"
root_sync="$(jq -r '.status.sync.status // "Unknown"' <<<"${root_json}")"
root_health="$(jq -r '.status.health.status // "Unknown"' <<<"${root_json}")"
log "Root application: sync=${root_sync}, health=${root_health}"

repo_secret_json="$(kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get secret "${repo_secret_name}" -o json)"
repo_secret_type="$(jq -r '.metadata.labels["argocd.argoproj.io/secret-type"] // ""' <<<"${repo_secret_json}")"
[[ "${repo_secret_type}" == "repo-creds" ]] || die "Repo credential secret ${repo_secret_name} is missing the repo-creds label"

owner_kind="$(jq -r '.metadata.ownerReferences[0].kind // empty' <<<"${repo_secret_json}")"
if [[ "${owner_kind}" == "ExternalSecret" ]]; then
  log "Repo credentials are owned by ExternalSecret"
else
  warn "Repo credentials exist but are not yet owned by ExternalSecret"
fi

if [[ -n "${cluster_name}" ]]; then
  cluster_secret_json="$(kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get secret "${cluster_secret_name}" -o json)"
  [[ "$(jq -r '.metadata.labels.role // ""' <<<"${cluster_secret_json}")" == "workload" ]] || die "Cluster secret ${cluster_secret_name} is missing role=workload"
  [[ "$(jq -r '.metadata.labels.tenant // ""' <<<"${cluster_secret_json}")" == "litomi" ]] || die "Cluster secret ${cluster_secret_name} is missing tenant=litomi"

  for generated_app in "platform-${cluster_name}" "litomi-${cluster_name}"; do
    app_json="$(kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get application "${generated_app}" -o json 2>/dev/null || true)"
    if [[ -z "${app_json}" ]]; then
      warn "Generated Application not found yet: ${generated_app}"
      continue
    fi

    log "${generated_app}: sync=$(jq -r '.status.sync.status // "Unknown"' <<<"${app_json}") health=$(jq -r '.status.health.status // "Unknown"' <<<"${app_json}")"
  done
fi

log "Checking workload cluster platform signals"
kubectl "${workload_kubectl_args[@]}" -n external-secrets rollout status deployment/external-secrets --timeout=60s >/dev/null
kubectl "${workload_kubectl_args[@]}" -n vault rollout status statefulset/vault --timeout=60s >/dev/null

check_ready_condition "Platform SecretStores" "argocd" "secretstore" "${workload_kubectl_args[@]}" || true
for ns in cloudflared gtm-server monitoring logging tracing minio velero litomi; do
  if kubectl "${workload_kubectl_args[@]}" get namespace "${ns}" >/dev/null 2>&1; then
    check_ready_condition "SecretStores in ${ns}" "${ns}" "secretstore" "${workload_kubectl_args[@]}" || true
  fi
done

workload_node_count="$(kubectl "${workload_kubectl_args[@]}" get nodes -o name | wc -l | tr -d ' ')"
if [[ "${workload_node_count}" == "1" ]]; then
  warn "Workload cluster has a single node. This is DR-first, not HA."
fi

if [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN_FILE:-}" ]]; then
  require_command vault
  export VAULT_ADDR
  export VAULT_TOKEN
  VAULT_ADDR="${VAULT_ADDR}"
  VAULT_TOKEN="$(load_file_contents "$(resolve_repo_path "${VAULT_TOKEN_FILE}")")"
  vault_auth_mount="${VAULT_AUTH_MOUNT_PATH:-kubernetes}"

  if vault auth list -format=json | jq -e --arg mount "${vault_auth_mount}/" '.[$mount]' >/dev/null; then
    log "Vault Kubernetes auth mount exists"
  else
    warn "Vault Kubernetes auth mount is missing"
  fi
else
  warn "VAULT_ADDR/VAULT_TOKEN_FILE not set; skipping direct Vault API checks"
fi

if [[ "${SKIP_PUBLIC_CHECK}" == "true" ]]; then
  log "Compatibility flag --skip-public-check was provided and ignored."
fi

log "Verification completed."
