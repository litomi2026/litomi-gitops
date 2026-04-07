#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/seed-vault-kv.sh [common flags]

Reads /secure/vault-secrets/**/*.env files and upserts them into the central
Vault KV mount using the path convention:
  /secure/vault-secrets/clusters/<cluster>/<namespace>/<secret>.env
  -> kv/clusters/<cluster>/<namespace>/<secret>
EOF
  usage_common_flags
}

seed_env_file() {
  local env_file="$1"
  local kv_mount="$2"
  local relative_key="$3"
  local line key raw_value decoded_value
  local kv_pairs=()

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

require_command vault find

if [[ -n "${MANAGEMENT_INVENTORY_FILE}" ]]; then
  management_inventory_resolved="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
  vault_addr_default="https://vault.$(inventory_internal_domain "${management_inventory_resolved}")"
else
  vault_addr_default="https://vault.mgmt.litomi.internal"
fi

vault_addr="${VAULT_ADDR_OVERRIDE:-${vault_addr_default}}"
vault_token_file="$(resolve_repo_path "${VAULT_TOKEN_FILE}")"
vault_secrets_dir="$(resolve_repo_path "${VAULT_SECRETS_DIR}")"
kv_mount="kv"

[[ -n "${vault_token_file}" ]] || die "--vault-token-file is required"
require_file "${vault_token_file}"
require_dir "${vault_secrets_dir}"

export VAULT_ADDR="${vault_addr}"
export VAULT_TOKEN
VAULT_TOKEN="$(load_file_contents "${vault_token_file}")"

validate_args=(
  --vault-secrets-dir "${vault_secrets_dir}"
)

if [[ -n "${MANAGEMENT_INVENTORY_FILE}" ]]; then
  validate_args+=(--management-inventory "${MANAGEMENT_INVENTORY_FILE}")
fi

for remote_inventory in "${REMOTE_INVENTORY_FILES[@]}"; do
  validate_args+=(--remote-inventory "${remote_inventory}")
done

run "${SCRIPT_DIR}/validate-vault-secrets.sh" "${validate_args[@]}"

seed_count=0

while IFS= read -r env_file; do
  relative_key="${env_file#${vault_secrets_dir}/}"
  relative_key="${relative_key%.env}"
  log "Seeding ${kv_mount}/${relative_key}"
  seed_env_file "${env_file}" "${kv_mount}" "${relative_key}"
  seed_count=$((seed_count + 1))
done < <(find "${vault_secrets_dir}" -type f -name '*.env' | sort)

(( seed_count > 0 )) || die "No .env files found under ${vault_secrets_dir}"

log "Vault KV seed completed."
