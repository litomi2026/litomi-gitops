#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/preflight-host.sh --management-inventory <path> [common flags]

Checks local tooling, inventory files, secure input files, and Kubernetes access
required for the multi-cluster bootstrap flow. This command validates only; it
never installs packages or changes cluster state.
EOF
  usage_common_flags
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

require_command kubectl jq yq git vault openssl base64
[[ -n "${MANAGEMENT_INVENTORY_FILE}" ]] || die "--management-inventory is required"

management_inventory="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
inventory_validate "${management_inventory}"

remote_inventories=()
for remote_inventory in "${REMOTE_INVENTORY_FILES[@]}"; do
  resolved_inventory="$(resolve_repo_path "${remote_inventory}")"
  inventory_validate "${resolved_inventory}"
  remote_inventories+=("${resolved_inventory}")
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

for permission in \
  "create namespaces" \
  "create clusterrolebindings.rbac.authorization.k8s.io" \
  "create customresourcedefinitions.apiextensions.k8s.io" \
  "create secrets -n argocd"; do
  if ! kubectl "${management_kubectl_args[@]}" auth can-i ${permission} >/dev/null; then
    die "Management cluster permission check failed: kubectl auth can-i ${permission}"
  fi
done

for remote_inventory in "${remote_inventories[@]}"; do
  remote_name="$(inventory_name "${remote_inventory}")"
  remote_kubeconfig="$(resolve_repo_path "$(inventory_kubeconfig "${remote_inventory}")")"
  remote_context="$(inventory_context "${remote_inventory}")"
  require_file "${remote_kubeconfig}"

  remote_kubectl_args=()
  remote_kubectl_args+=(--kubeconfig "${remote_kubeconfig}")
  if [[ -n "${remote_context}" ]]; then
    remote_kubectl_args+=(--context "${remote_context}")
  fi

  require_kubectl_connectivity "${remote_name}" "${remote_kubectl_args[@]}"

  for permission in \
    "create clusterrolebindings.rbac.authorization.k8s.io" \
    "create serviceaccounts -n external-secrets"; do
    if ! kubectl "${remote_kubectl_args[@]}" auth can-i ${permission} >/dev/null; then
      die "Remote cluster permission check failed for ${remote_name}: kubectl auth can-i ${permission}"
    fi
  done
done

vault_secrets_dir="$(resolve_repo_path "${VAULT_SECRETS_DIR}")"
require_dir "${vault_secrets_dir}"

management_cluster_name="$(inventory_name "${management_inventory}")"
repo_creds_file="${REPO_CREDS_FILE:-${vault_secrets_dir}/clusters/${management_cluster_name}/argocd/github-repo-creds.env}"
repo_creds_file="$(resolve_repo_path "${repo_creds_file}")"
require_file "${repo_creds_file}"

repo_creds_url="$(env_file_value "${repo_creds_file}" "url")"
repo_creds_type="$(env_file_value "${repo_creds_file}" "type")"
repo_creds_github_app_id="$(env_file_value "${repo_creds_file}" "githubAppID")"
repo_creds_github_app_installation_id="$(env_file_value "${repo_creds_file}" "githubAppInstallationID")"
repo_creds_github_app_private_key="$(env_file_value "${repo_creds_file}" "githubAppPrivateKey")"

[[ -n "${repo_creds_url}" ]] || die "Repository credential file is missing a non-empty url: ${repo_creds_file}"
[[ "${repo_creds_type}" == "git" ]] || die "Repository credential file must set type=git: ${repo_creds_file}"
[[ -n "${repo_creds_github_app_id}" ]] || die "Repository credential file is missing githubAppID: ${repo_creds_file}"
[[ -n "${repo_creds_github_app_installation_id}" ]] || die "Repository credential file is missing githubAppInstallationID: ${repo_creds_file}"
[[ -n "${repo_creds_github_app_private_key}" ]] || die "Repository credential file is missing githubAppPrivateKey: ${repo_creds_file}"

if [[ -n "${VAULT_TOKEN_FILE}" ]]; then
  require_file "$(resolve_repo_path "${VAULT_TOKEN_FILE}")"
fi

validate_args=(
  --management-inventory "${management_inventory}"
  --vault-secrets-dir "${vault_secrets_dir}"
  --require-secure-files
)

for remote_inventory in "${remote_inventories[@]}"; do
  validate_args+=(--remote-inventory "${remote_inventory}")
done

run "${SCRIPT_DIR}/validate-vault-secrets.sh" "${validate_args[@]}"

log "Tooling, inventories, kubeconfigs, and secure input files look ready."
