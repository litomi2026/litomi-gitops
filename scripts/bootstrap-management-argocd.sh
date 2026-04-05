#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-management-argocd.sh [common flags]

Bootstraps Argo CD on the management cluster, creates the bootstrap Git repo
credential secret, and applies the root application.
EOF
  usage_common_flags
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

load_config_file
require_command kubectl jq base64

management_kubeconfig="${MANAGEMENT_KUBECONFIG:-${KUBECONFIG_PATH}}"
management_context="${MANAGEMENT_CONTEXT:-${KUBE_CONTEXT}}"

if [[ -n "${management_kubeconfig}" ]]; then
  management_kubeconfig="$(resolve_repo_path "${management_kubeconfig}")"
  require_file "${management_kubeconfig}"
fi

declare -a management_kubectl_args
setup_kubectl_args management_kubectl_args "${management_kubeconfig}" "${management_context}"
require_kubectl_connectivity "management" "${management_kubectl_args[@]}"

argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
argocd_bootstrap_timeout="${ARGOCD_BOOTSTRAP_TIMEOUT:-300s}"
argocd_bootstrap_kustomize="$(resolve_repo_path "${ARGOCD_BOOTSTRAP_KUSTOMIZE:-bootstrap/argocd}")"
root_app_manifest="$(resolve_repo_path "${ROOT_APP_MANIFEST:-bootstrap/root/root.yaml}")"
bootstrap_repo_secret_name="${BOOTSTRAP_REPO_SECRET_NAME:-github-repo-creds}"
bootstrap_repo_url="${BOOTSTRAP_REPO_URL:-https://github.com/litomi2026/litomi-gitops.git}"
bootstrap_repo_type="${BOOTSTRAP_REPO_TYPE:-git}"
bootstrap_repo_username="${BOOTSTRAP_REPO_USERNAME:-git}"
bootstrap_repo_token_file="$(resolve_repo_path "${BOOTSTRAP_REPO_TOKEN_FILE:-}")"

[[ -n "${bootstrap_repo_token_file}" ]] || die "BOOTSTRAP_REPO_TOKEN_FILE must be set"
require_file "${bootstrap_repo_token_file}"
require_file "${root_app_manifest}"

log "Applying Argo CD bootstrap manifests"
kubectl_apply_kustomize "${argocd_bootstrap_kustomize}" "${management_kubectl_args[@]}"

for deployment_name in \
  deployment/argocd-server \
  deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller \
  statefulset/argocd-application-controller; do
  kubectl_wait_rollout "${argocd_namespace}" "${deployment_name}" "${argocd_bootstrap_timeout}" "${management_kubectl_args[@]}"
done

bootstrap_repo_token="$(load_file_contents "${bootstrap_repo_token_file}")"
bootstrap_repo_url_b64="$(printf '%s' "${bootstrap_repo_url}" | base64 | tr -d '\n')"
bootstrap_repo_type_b64="$(printf '%s' "${bootstrap_repo_type}" | base64 | tr -d '\n')"
bootstrap_repo_username_b64="$(printf '%s' "${bootstrap_repo_username}" | base64 | tr -d '\n')"
bootstrap_repo_token_b64="$(printf '%s' "${bootstrap_repo_token}" | base64 | tr -d '\n')"
tmp_manifest="$(mktemp)"
trap 'rm -f "${tmp_manifest}"' EXIT

cat >"${tmp_manifest}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${bootstrap_repo_secret_name}
  namespace: ${argocd_namespace}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
    bootstrap.litomi.io/managed-by: bootstrap-management-argocd
type: Opaque
data:
  url: ${bootstrap_repo_url_b64}
  type: ${bootstrap_repo_type_b64}
  username: ${bootstrap_repo_username_b64}
  password: ${bootstrap_repo_token_b64}
EOF

log "Creating or updating bootstrap repo credentials"
kubectl_apply_file "${tmp_manifest}" "${management_kubectl_args[@]}"

log "Applying root application"
kubectl_apply_file "${root_app_manifest}" "${management_kubectl_args[@]}"

wait_for_jsonpath_value \
  "root application sync status" \
  "Synced" \
  300 \
  '{.status.sync.status}' \
  kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get application root

log "Management-cluster Argo CD bootstrap completed."
