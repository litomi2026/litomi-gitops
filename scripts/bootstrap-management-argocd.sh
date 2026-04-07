#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-management-argocd.sh --management-inventory <path> [common flags]

Bootstraps Argo CD on the management cluster, creates the temporary Git repo
credential secret from /secure input, applies the root Application, and
optionally registers remote clusters declared via --remote-inventory.
EOF
  usage_common_flags
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

require_command kubectl jq yq base64
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

argocd_namespace="argocd"
bootstrap_timeout="600s"
argocd_bootstrap_kustomize="$(resolve_repo_path "bootstrap/argocd")"
root_app_manifest="$(resolve_repo_path "bootstrap/root/root.yaml")"
vault_secrets_dir="$(resolve_repo_path "${VAULT_SECRETS_DIR}")"
management_cluster_name="$(inventory_name "${management_inventory}")"
repo_creds_file="${REPO_CREDS_FILE:-${vault_secrets_dir}/clusters/${management_cluster_name}/argocd/github-repo-creds.env}"
repo_creds_file="$(resolve_repo_path "${repo_creds_file}")"

require_file "${root_app_manifest}"
require_file "${repo_creds_file}"

bootstrap_repo_url="$(env_file_value "${repo_creds_file}" "url")"
bootstrap_repo_type="$(env_file_value "${repo_creds_file}" "type")"
bootstrap_repo_github_app_id="$(env_file_value "${repo_creds_file}" "githubAppID")"
bootstrap_repo_github_app_installation_id="$(env_file_value "${repo_creds_file}" "githubAppInstallationID")"
bootstrap_repo_github_app_private_key="$(env_file_value "${repo_creds_file}" "githubAppPrivateKey")"
bootstrap_repo_github_app_enterprise_base_url="$(env_file_optional_value "${repo_creds_file}" "githubAppEnterpriseBaseUrl" || true)"

[[ -n "${bootstrap_repo_url}" ]] || die "Repository credential file is missing a non-empty url: ${repo_creds_file}"
[[ "${bootstrap_repo_type}" == "git" ]] || die "Repository credential file must set type=git: ${repo_creds_file}"
[[ -n "${bootstrap_repo_github_app_id}" ]] || die "Repository credential file is missing githubAppID: ${repo_creds_file}"
[[ -n "${bootstrap_repo_github_app_installation_id}" ]] || die "Repository credential file is missing githubAppInstallationID: ${repo_creds_file}"
[[ -n "${bootstrap_repo_github_app_private_key}" ]] || die "Repository credential file is missing githubAppPrivateKey: ${repo_creds_file}"

log "Applying Argo CD bootstrap manifests on $(inventory_name "${management_inventory}")"
kubectl_apply_kustomize "${argocd_bootstrap_kustomize}" "${management_kubectl_args[@]}"

for resource_name in \
  deployment/argocd-server \
  deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller \
  statefulset/argocd-application-controller \
  deployment/argocd-redis; do
  kubectl_wait_rollout_if_exists "${argocd_namespace}" "${resource_name}" "${bootstrap_timeout}" "${management_kubectl_args[@]}"
done

tmp_manifest="$(mktemp)"
trap 'rm -f "${tmp_manifest}"' EXIT

github_app_enterprise_base_url_block=""
if [[ -n "${bootstrap_repo_github_app_enterprise_base_url}" ]]; then
  github_app_enterprise_base_url_block="  githubAppEnterpriseBaseUrl: \"${bootstrap_repo_github_app_enterprise_base_url}\""
fi

cat >"${tmp_manifest}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-repo-creds
  namespace: ${argocd_namespace}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
    bootstrap.litomi.io/managed-by: bootstrap-management-argocd
type: Opaque
stringData:
  url: "${bootstrap_repo_url}"
  type: "${bootstrap_repo_type}"
  githubAppID: "${bootstrap_repo_github_app_id}"
  githubAppInstallationID: "${bootstrap_repo_github_app_installation_id}"
${github_app_enterprise_base_url_block}
  githubAppPrivateKey: |
$(printf '%s\n' "${bootstrap_repo_github_app_private_key}" | sed 's/^/    /')
EOF

log "Creating temporary bootstrap repo credentials"
kubectl_apply_file "${tmp_manifest}" "${management_kubectl_args[@]}"

log "Applying root Application"
kubectl_apply_file "${root_app_manifest}" "${management_kubectl_args[@]}"

wait_for_jsonpath_value \
  "root application sync status" \
  "Synced" \
  600 \
  '{.status.sync.status}' \
  kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get application root

for remote_inventory in "${remote_inventories[@]}"; do
  cluster_name="$(inventory_name "${remote_inventory}")"
  cluster_class="$(inventory_cluster_class "${remote_inventory}")"

  log "Registering remote cluster ${cluster_name}"
  register_cmd=(
    "${SCRIPT_DIR}/register-remote-cluster.sh"
    --management-inventory "${management_inventory}"
    --inventory "${remote_inventory}"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    register_cmd+=(--dry-run)
  fi

  run "${register_cmd[@]}"

  wait_for_jsonpath_value \
    "platform parent application ${cluster_name}" \
    "platform-${cluster_name}" \
    300 \
    '{.metadata.name}' \
    kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get application "platform-${cluster_name}"

  case "${cluster_class}" in
    environment-runtime)
      wait_for_jsonpath_value \
        "litomi parent application ${cluster_name}" \
        "litomi-${cluster_name}" \
        300 \
        '{.metadata.name}' \
        kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get application "litomi-${cluster_name}"
      ;;
  esac
done

log "Management cluster bootstrap completed."
