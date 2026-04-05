#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-vault-auth.sh [common flags]

Configures Vault Kubernetes auth and upserts the ESO policies/roles implied by
the current litomi-gitops SecretStores.
--kubeconfig/--context refer to the workload cluster where Vault runs.
EOF
  usage_common_flags
}

write_policy() {
  local policy_name="$1"
  shift
  local kv_mount="$1"
  shift
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

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

load_config_file
require_command kubectl jq vault base64

workload_kubeconfig="${WORKLOAD_KUBECONFIG:-${KUBECONFIG_PATH}}"
workload_context="${WORKLOAD_CONTEXT:-${KUBE_CONTEXT}}"
vault_addr="${VAULT_ADDR:-}"
vault_token_file="$(resolve_repo_path "${VAULT_TOKEN_FILE:-}")"
vault_auth_mount="${VAULT_AUTH_MOUNT_PATH:-kubernetes}"
vault_kv_mount="${VAULT_KV_MOUNT:-kv}"
vault_namespace="${VAULT_K8S_NAMESPACE:-vault}"
reviewer_serviceaccount="${VAULT_TOKEN_REVIEWER_SERVICE_ACCOUNT:-vault-token-reviewer}"
reviewer_binding="${VAULT_TOKEN_REVIEWER_BINDING_NAME:-vault-token-reviewer}"
role_audience="${VAULT_ROLE_AUDIENCE:-vault}"
role_ttl="${VAULT_ROLE_TTL:-1h}"
role_max_ttl="${VAULT_ROLE_MAX_TTL:-24h}"

[[ -n "${workload_kubeconfig}" ]] || die "WORKLOAD_KUBECONFIG or --kubeconfig is required"
[[ -n "${vault_addr}" ]] || die "VAULT_ADDR must be set"
[[ -n "${vault_token_file}" ]] || die "VAULT_TOKEN_FILE must be set"

workload_kubeconfig="$(resolve_repo_path "${workload_kubeconfig}")"
require_file "${workload_kubeconfig}"
require_file "${vault_token_file}"

declare -a workload_kubectl_args
setup_kubectl_args workload_kubectl_args "${workload_kubeconfig}" "${workload_context}"
require_kubectl_connectivity "workload" "${workload_kubectl_args[@]}"

export VAULT_ADDR="${vault_addr}"
export VAULT_TOKEN
VAULT_TOKEN="$(load_file_contents "${vault_token_file}")"

workload_cluster_json="$(kubectl "${workload_kubectl_args[@]}" config view --raw --flatten --minify -o json)"
cluster_server="$(jq -r '.clusters[0].cluster.server' <<<"${workload_cluster_json}")"
cluster_ca="$(jq -r '.clusters[0].cluster["certificate-authority-data"] // empty' <<<"${workload_cluster_json}")"
[[ -n "${cluster_ca}" ]] || die "Workload kubeconfig must contain certificate-authority-data"
cluster_ca_pem="$(printf '%s' "${cluster_ca}" | base64 --decode)"

token_reviewer_manifest="$(mktemp)"
trap 'rm -f "${token_reviewer_manifest}"' EXIT

cat >"${token_reviewer_manifest}" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${reviewer_serviceaccount}
  namespace: ${vault_namespace}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${reviewer_binding}
subjects:
  - kind: ServiceAccount
    name: ${reviewer_serviceaccount}
    namespace: ${vault_namespace}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
EOF

log "Ensuring Vault token-reviewer service account exists"
kubectl_apply_file "${token_reviewer_manifest}" "${workload_kubectl_args[@]}"

if [[ "${DRY_RUN}" == "true" ]]; then
  reviewer_jwt="<dry-run-token>"
else
  reviewer_jwt="$(kubectl "${workload_kubectl_args[@]}" -n "${vault_namespace}" create token "${reviewer_serviceaccount}")"
fi

if ! vault auth list -format=json | jq -e --arg mount "${vault_auth_mount}/" '.[$mount]' >/dev/null; then
  log "Enabling Vault Kubernetes auth at ${vault_auth_mount}/"
  run vault auth enable -path="${vault_auth_mount}" kubernetes
fi

run vault write "auth/${vault_auth_mount}/config" \
  kubernetes_host="${cluster_server}" \
  kubernetes_ca_cert="${cluster_ca_pem}" \
  token_reviewer_jwt="${reviewer_jwt}"

write_policy "eso-argocd" "${vault_kv_mount}" "argocd/github-repo-creds"
upsert_vault_role "${vault_auth_mount}" "eso-argocd" "argocd" "eso-argocd" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-cloudflared" "${vault_kv_mount}" "cloudflared/cloudflared-token"
upsert_vault_role "${vault_auth_mount}" "eso-cloudflared" "cloudflared" "eso-cloudflared" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-gtm-server" "${vault_kv_mount}" "gtm-server/gtm-server-secret"
upsert_vault_role "${vault_auth_mount}" "eso-gtm-server" "gtm-server" "eso-gtm-server" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-monitoring" "${vault_kv_mount}" \
  "monitoring/grafana-admin" \
  "monitoring/alertmanager-discord-webhook-warning" \
  "monitoring/alertmanager-discord-webhook-critical"
upsert_vault_role "${vault_auth_mount}" "eso-monitoring" "monitoring" "eso-monitoring" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-logging" "${vault_kv_mount}" "minio/minio-root"
upsert_vault_role "${vault_auth_mount}" "eso-logging" "logging" "eso-logging" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-tracing" "${vault_kv_mount}" "minio/minio-root"
upsert_vault_role "${vault_auth_mount}" "eso-tracing" "tracing" "eso-tracing" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-minio" "${vault_kv_mount}" "minio/minio-root"
upsert_vault_role "${vault_auth_mount}" "eso-minio" "minio" "eso-minio" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-velero" "${vault_kv_mount}" "velero/velero-cloud-credentials"
upsert_vault_role "${vault_auth_mount}" "eso-velero" "velero" "eso-velero" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-litomi-stg" "${vault_kv_mount}" "litomi-stg/litomi-backend-secret"
upsert_vault_role "${vault_auth_mount}" "eso-litomi-stg" "litomi" "eso-litomi-stg" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

write_policy "eso-litomi-prod" "${vault_kv_mount}" "litomi-prod/litomi-backend-secret"
upsert_vault_role "${vault_auth_mount}" "eso-litomi-prod" "litomi" "eso-litomi-prod" "${role_audience}" "${role_ttl}" "${role_max_ttl}"

log "Vault Kubernetes auth and ESO roles are configured."
