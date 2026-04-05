#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/seed-vault-kv.sh [common flags]

Reads trusted shell-style .env files from --vault-secrets-dir and upserts them
into the configured Vault KV mount. Example:
  /secure/vault-secrets/litomi-prod/litomi-backend-secret.env
  -> kv/litomi-prod/litomi-backend-secret
EOF
  usage_common_flags
}

decode_env_value() {
  local raw_value="$1"
  local evaluated_value=""

  eval "evaluated_value=${raw_value}"
  printf '%b' "${evaluated_value}"
}

seed_env_file() {
  local env_file="$1"
  local kv_mount="$2"
  local relative_key="$3"
  local -a kv_pairs=()
  local line key raw_value decoded_value

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+ ]] && line="${line#export }"

    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      die "Unsupported env line in ${env_file}: ${line}"
    fi

    key="${line%%=*}"
    raw_value="${line#*=}"
    decoded_value="$(decode_env_value "${raw_value}")"
    kv_pairs+=("${key}=${decoded_value}")
  done <"${env_file}"

  if (( ${#kv_pairs[@]} == 0 )); then
    warn "Skipping empty env file: ${env_file}"
    return 0
  fi

  run vault kv put "${kv_mount}/${relative_key}" "${kv_pairs[@]}"
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

load_config_file
require_command vault find

vault_addr="${VAULT_ADDR:-}"
vault_token_file="$(resolve_repo_path "${VAULT_TOKEN_FILE:-}")"
vault_kv_mount="${VAULT_KV_MOUNT:-kv}"
vault_secrets_dir="$(resolve_repo_path "${VAULT_SECRETS_DIR}")"

[[ -n "${vault_addr}" ]] || die "VAULT_ADDR must be set"
[[ -n "${vault_token_file}" ]] || die "VAULT_TOKEN_FILE must be set"
[[ -n "${vault_secrets_dir}" ]] || die "--vault-secrets-dir or VAULT_SECRETS_DIR must be set"

require_file "${vault_token_file}"
require_dir "${vault_secrets_dir}"

export VAULT_ADDR="${vault_addr}"
export VAULT_TOKEN
VAULT_TOKEN="$(load_file_contents "${vault_token_file}")"

expected_keys=(
  "argocd/github-repo-creds"
  "cloudflared/cloudflared-token"
  "gtm-server/gtm-server-secret"
  "litomi-stg/litomi-backend-secret"
  "litomi-prod/litomi-backend-secret"
  "minio/minio-root"
  "monitoring/grafana-admin"
  "monitoring/alertmanager-discord-webhook-warning"
  "monitoring/alertmanager-discord-webhook-critical"
  "velero/velero-cloud-credentials"
)

for expected_key in "${expected_keys[@]}"; do
  if [[ ! -f "${vault_secrets_dir}/${expected_key}.env" ]]; then
    warn "Expected Vault seed file missing: ${vault_secrets_dir}/${expected_key}.env"
  fi
done

while IFS= read -r env_file; do
  relative_key="${env_file#${vault_secrets_dir}/}"
  relative_key="${relative_key%.env}"
  log "Seeding ${vault_kv_mount}/${relative_key}"
  seed_env_file "${env_file}" "${vault_kv_mount}" "${relative_key}"
done < <(find "${vault_secrets_dir}" -type f -name '*.env' | sort)

log "Vault KV seed completed."
