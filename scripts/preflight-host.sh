#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/preflight-host.sh [common flags]

Checks host tooling, Kubernetes access, and configured input files needed for the
bootstrap scripts. This command prints guidance only and never installs packages.
EOF
  usage_common_flags
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

load_config_file

missing_commands=()
for command_name in kubectl jq openssl base64 vault git; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    missing_commands+=("${command_name}")
  fi
done

if (( ${#missing_commands[@]} > 0 )); then
  warn "Missing commands: ${missing_commands[*]}"
  warn "Install them manually before retrying."
  warn "Ubuntu hint: apt install -y jq openssl git coreutils"
  warn "Install kubectl and Vault CLI from their official repositories."
  exit 1
fi

management_kubeconfig="${MANAGEMENT_KUBECONFIG:-${KUBECONFIG_PATH}}"
management_context="${MANAGEMENT_CONTEXT:-${KUBE_CONTEXT}}"

if [[ -n "${management_kubeconfig}" ]]; then
  management_kubeconfig="$(resolve_repo_path "${management_kubeconfig}")"
  require_file "${management_kubeconfig}"
fi

declare -a management_kubectl_args
setup_kubectl_args management_kubectl_args "${management_kubeconfig}" "${management_context}"
require_kubectl_connectivity "management" "${management_kubectl_args[@]}"

permission_checks=(
  "create namespaces"
  "create clusterrolebindings.rbac.authorization.k8s.io"
  "create customresourcedefinitions.apiextensions.k8s.io"
  "create secrets -n argocd"
  "create serviceaccounts -n vault"
)

for permission in "${permission_checks[@]}"; do
  if ! kubectl "${management_kubectl_args[@]}" auth can-i ${permission} >/dev/null; then
    die "Management cluster permission check failed: kubectl auth can-i ${permission}"
  fi
done

for maybe_file in \
  "${BOOTSTRAP_REPO_TOKEN_FILE:-}" \
  "${VAULT_TOKEN_FILE:-}" \
  "${WORKLOAD_KUBECONFIG:-}" \
  "${VAULT_CA_CERT_FILE:-}"; do
  if [[ -n "${maybe_file}" ]]; then
    require_file "$(resolve_repo_path "${maybe_file}")"
  fi
done

if [[ -n "${VAULT_SECRETS_DIR}" ]]; then
  require_dir "$(resolve_repo_path "${VAULT_SECRETS_DIR}")"
fi

log "Host tooling, management-cluster access, and configured file paths look good."
