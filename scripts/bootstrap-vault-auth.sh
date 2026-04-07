#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-vault-auth.sh [common flags]

Configures the central Vault Kubernetes auth mounts for the requested
inventories, then writes cluster-scoped ESO policies and roles that map to the
GitOps SecretStores in this repository.
EOF
  usage_common_flags
}

write_policy() {
  local policy_name="$1"
  local kv_mount="$2"
  shift 2
  local key_paths=("$@")
  local policy_body=""
  local key_path

  for key_path in "${key_paths[@]}"; do
    policy_body+="path \"${kv_mount}/data/${key_path}\" {\n"
    policy_body+="  capabilities = [\"read\"]\n"
    policy_body+="}\n\n"
    policy_body+="path \"${kv_mount}/metadata/${key_path}\" {\n"
    policy_body+="  capabilities = [\"read\"]\n"
    policy_body+="}\n\n"
  done

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_command vault policy write "${policy_name}" "<generated-policy>"
    return 0
  fi

  printf '%b' "${policy_body}" | vault policy write "${policy_name}" -
}

upsert_vault_role() {
  local auth_mount="$1"
  local role_name="$2"
  local namespace_name="$3"
  local policy_name="$4"
  local audience="$5"
  local ttl="$6"
  local max_ttl="$7"

  run vault write "auth/${auth_mount}/role/${role_name}" \
    bound_service_account_names="eso-vault" \
    bound_service_account_namespaces="${namespace_name}" \
    policies="${policy_name}" \
    audience="${audience}" \
    ttl="${ttl}" \
    max_ttl="${max_ttl}"
}

configure_inventory() {
  local inventory_file="$1"
  local cluster_name cluster_class auth_mount
  local kubeconfig_path kube_context
  local cluster_config_json cluster_server cluster_ca cluster_ca_pem
  local reviewer_serviceaccount reviewer_binding reviewer_manifest reviewer_jwt

  cluster_name="$(inventory_name "${inventory_file}")"
  cluster_class="$(inventory_cluster_class "${inventory_file}")"
  auth_mount="$(inventory_vault_auth_mount "${inventory_file}")"
  kubeconfig_path="$(resolve_repo_path "$(inventory_kubeconfig "${inventory_file}")")"
  kube_context="$(inventory_context "${inventory_file}")"

  require_file "${kubeconfig_path}"

  cluster_kubectl_args=()
  cluster_kubectl_args+=(--kubeconfig "${kubeconfig_path}")
  if [[ -n "${kube_context}" ]]; then
    cluster_kubectl_args+=(--context "${kube_context}")
  fi

  require_kubectl_connectivity "${cluster_name}" "${cluster_kubectl_args[@]}"

  cluster_config_json="$(kubectl "${cluster_kubectl_args[@]}" config view --raw --flatten --minify -o json)"
  cluster_server="$(jq -r '.clusters[0].cluster.server' <<<"${cluster_config_json}")"
  cluster_ca="$(jq -r '.clusters[0].cluster["certificate-authority-data"] // empty' <<<"${cluster_config_json}")"
  [[ -n "${cluster_ca}" ]] || die "Kubeconfig for ${cluster_name} must contain certificate-authority-data"
  cluster_ca_pem="$(printf '%s' "${cluster_ca}" | base64_decode)"

  reviewer_serviceaccount="vault-token-reviewer"
  reviewer_binding="vault-token-reviewer-${cluster_name}"
  reviewer_manifest="$(mktemp)"

  cat >"${reviewer_manifest}" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${reviewer_serviceaccount}
  namespace: external-secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${reviewer_binding}
subjects:
  - kind: ServiceAccount
    name: ${reviewer_serviceaccount}
    namespace: external-secrets
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
EOF

  log "Ensuring token reviewer identity exists on ${cluster_name}"
  kubectl_apply_file "${reviewer_manifest}" "${cluster_kubectl_args[@]}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    reviewer_jwt="<dry-run-token>"
  else
    reviewer_jwt="$(kubectl "${cluster_kubectl_args[@]}" -n external-secrets create token "${reviewer_serviceaccount}")"
  fi

  if ! vault auth list -format=json | jq -e --arg mount "${auth_mount}/" '.[$mount]' >/dev/null; then
    log "Enabling Vault auth mount ${auth_mount}/"
    run vault auth enable -path="${auth_mount}" kubernetes
  fi

  run vault write "auth/${auth_mount}/config" \
    kubernetes_host="${cluster_server}" \
    kubernetes_ca_cert="${cluster_ca_pem}" \
    token_reviewer_jwt="${reviewer_jwt}"

  if [[ "${cluster_class}" == "management" ]]; then
    write_policy "eso-${cluster_name}-argocd" "kv" \
      "clusters/${cluster_name}/argocd/github-repo-creds"
    upsert_vault_role "${auth_mount}" "eso-argocd" "argocd" "eso-${cluster_name}-argocd" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-minio" "kv" \
      "clusters/${cluster_name}/minio/minio-root"
    upsert_vault_role "${auth_mount}" "eso-minio" "minio" "eso-${cluster_name}-minio" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-monitoring" "kv" \
      "clusters/${cluster_name}/monitoring/grafana-admin" \
      "clusters/${cluster_name}/monitoring/alertmanager-webhook-warning" \
      "clusters/${cluster_name}/monitoring/alertmanager-webhook-critical"
    upsert_vault_role "${auth_mount}" "eso-monitoring" "monitoring" "eso-${cluster_name}-monitoring" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-logging" "kv" \
      "clusters/${cluster_name}/logging/loki-s3"
    upsert_vault_role "${auth_mount}" "eso-logging" "logging" "eso-${cluster_name}-logging" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-tracing" "kv" \
      "clusters/${cluster_name}/tracing/tempo-s3"
    upsert_vault_role "${auth_mount}" "eso-tracing" "tracing" "eso-${cluster_name}-tracing" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-velero" "kv" \
      "clusters/${cluster_name}/velero/velero-cloud-credentials"
    upsert_vault_role "${auth_mount}" "eso-velero" "velero" "eso-${cluster_name}-velero" "vault" "1h" "24h"
  elif [[ "${cluster_class}" == "environment-runtime" ]]; then
    write_policy "eso-${cluster_name}-velero" "kv" \
      "clusters/${cluster_name}/velero/velero-cloud-credentials"
    upsert_vault_role "${auth_mount}" "eso-velero" "velero" "eso-${cluster_name}-velero" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-litomi" "kv" \
      "clusters/${cluster_name}/litomi/litomi-backend-secret"
    upsert_vault_role "${auth_mount}" "eso-litomi" "litomi" "eso-${cluster_name}-litomi" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-cloudflared" "kv" \
      "clusters/${cluster_name}/cloudflared/cloudflared-token"
    upsert_vault_role "${auth_mount}" "eso-cloudflared" "cloudflared" "eso-${cluster_name}-cloudflared" "vault" "1h" "24h"

    write_policy "eso-${cluster_name}-gtm-server" "kv" \
      "clusters/${cluster_name}/gtm-server/gtm-server-secret"
    upsert_vault_role "${auth_mount}" "eso-gtm-server" "gtm-server" "eso-${cluster_name}-gtm-server" "vault" "1h" "24h"
  else
    die "Unsupported cluster class for ${cluster_name}: ${cluster_class}"
  fi

  rm -f "${reviewer_manifest}"
  log "Vault Kubernetes auth is configured for ${cluster_name}"
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

require_command kubectl jq vault yq base64

target_inventories=()
if [[ -n "${MANAGEMENT_INVENTORY_FILE}" ]]; then
  target_inventories+=("$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")")
fi

if [[ -n "${INVENTORY_FILE}" ]]; then
  target_inventories+=("$(resolve_repo_path "${INVENTORY_FILE}")")
fi

for remote_inventory in "${REMOTE_INVENTORY_FILES[@]}"; do
  target_inventories+=("$(resolve_repo_path "${remote_inventory}")")
done

(( ${#target_inventories[@]} > 0 )) || die "Provide at least one inventory via --management-inventory, --inventory, or --remote-inventory"

for inventory_file in "${target_inventories[@]}"; do
  inventory_validate "${inventory_file}"
done

if [[ -n "${MANAGEMENT_INVENTORY_FILE}" ]]; then
  management_inventory_resolved="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
  vault_addr_default="https://vault.$(inventory_internal_domain "${management_inventory_resolved}")"
else
  vault_addr_default="https://vault.mgmt.litomi.internal"
fi

vault_addr="${VAULT_ADDR_OVERRIDE:-${vault_addr_default}}"
vault_token_file="$(resolve_repo_path "${VAULT_TOKEN_FILE}")"
[[ -n "${vault_token_file}" ]] || die "--vault-token-file is required"
require_file "${vault_token_file}"

export VAULT_ADDR="${vault_addr}"
export VAULT_TOKEN
VAULT_TOKEN="$(load_file_contents "${vault_token_file}")"

for inventory_file in "${target_inventories[@]}"; do
  configure_inventory "${inventory_file}"
done

log "All requested Vault auth mounts, policies, and ESO roles are configured."
