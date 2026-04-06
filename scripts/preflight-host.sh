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

workload_inventories=()
for workload_inventory in "${WORKLOAD_INVENTORY_FILES[@]}"; do
  resolved_inventory="$(resolve_repo_path "${workload_inventory}")"
  inventory_validate "${resolved_inventory}"
  workload_inventories+=("${resolved_inventory}")
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

for workload_inventory in "${workload_inventories[@]}"; do
  workload_name="$(inventory_name "${workload_inventory}")"
  workload_kubeconfig="$(resolve_repo_path "$(inventory_kubeconfig "${workload_inventory}")")"
  workload_context="$(inventory_context "${workload_inventory}")"
  require_file "${workload_kubeconfig}"

  workload_kubectl_args=()
  workload_kubectl_args+=(--kubeconfig "${workload_kubeconfig}")
  if [[ -n "${workload_context}" ]]; then
    workload_kubectl_args+=(--context "${workload_context}")
  fi

  require_kubectl_connectivity "${workload_name}" "${workload_kubectl_args[@]}"

  for permission in \
    "create clusterrolebindings.rbac.authorization.k8s.io" \
    "create serviceaccounts -n external-secrets"; do
    if ! kubectl "${workload_kubectl_args[@]}" auth can-i ${permission} >/dev/null; then
      die "Workload cluster permission check failed for ${workload_name}: kubectl auth can-i ${permission}"
    fi
  done
done

vault_secrets_dir="$(resolve_repo_path "${VAULT_SECRETS_DIR}")"
require_dir "${vault_secrets_dir}"

repo_creds_file="${REPO_CREDS_FILE:-${vault_secrets_dir}/clusters/mgmt-01/argocd/github-repo-creds.env}"
repo_creds_file="$(resolve_repo_path "${repo_creds_file}")"
require_file "${repo_creds_file}"

if [[ -n "${VAULT_TOKEN_FILE}" ]]; then
  require_file "$(resolve_repo_path "${VAULT_TOKEN_FILE}")"
fi

templates_root="$(resolve_repo_path "bootstrap/secrets/templates/clusters")"
require_dir "${templates_root}"

cluster_inventories=("${management_inventory}" "${workload_inventories[@]}")

for inventory_file in "${cluster_inventories[@]}"; do
  cluster_name="$(inventory_name "${inventory_file}")"
  public_edge="$(inventory_public_edge "${inventory_file}")"

  while IFS= read -r template_file; do
    secure_file="${vault_secrets_dir}/${template_file#${templates_root}/}"
    secure_file="${secure_file%.template}"

    case "${secure_file}" in
      */cloudflared/*|*/gtm-server/*)
        if [[ "${public_edge}" != "enabled" ]]; then
          continue
        fi
        ;;
    esac

    require_file "${secure_file}"
  done < <(find "${templates_root}/${cluster_name}" -type f -name '*.env.template' | sort)
done

log "Tooling, inventories, kubeconfigs, and secure input files look ready."
