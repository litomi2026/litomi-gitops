#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/validate-vault-secrets.sh [common flags] [--require-secure-files]

Validates Vault secret templates, their schema metadata, and any matching
secure input files under /secure/vault-secrets.

Schema convention:
  bootstrap/secrets/templates/clusters/<cluster>/<namespace>/<secret>.env.template
  bootstrap/secrets/templates/clusters/<cluster>/<namespace>/<secret>.env.schema.yaml
EOF
  usage_common_flags
  cat <<'EOF'
Additional flags:
  --require-secure-files
EOF
}

array_contains() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

append_unique() {
  local needle="$1"
  shift
  local -a current_items=("$@")

  if ! array_contains "${needle}" "${current_items[@]}"; then
    printf '%s\n' "${needle}"
  fi
}

env_file_keys() {
  local env_file="$1"
  local line key

  require_file "${env_file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+ ]] && line="${line#export }"

    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      die "Unsupported env line in ${env_file}: ${line}"
    fi

    key="${line%%=*}"
    printf '%s\n' "${key}"
  done <"${env_file}"
}

validate_schema_key_name() {
  local schema_file="$1"
  local key_name="$2"

  if [[ ! "${key_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    die "Secret schema contains an invalid key name in ${schema_file}: ${key_name}"
  fi
}

validate_secret_schema() {
  local templates_root="$1"
  local template_file="$2"
  local schema_file expected_vault_path actual_vault_path owner allow_additional
  local consumer_file consumer_path
  local required_key optional_key
  local -a seen_keys=()

  schema_file="${template_file%.template}.schema.yaml"
  require_file "${schema_file}"

  expected_vault_path="${template_file#${templates_root}/}"
  expected_vault_path="${expected_vault_path%.env.template}"

  actual_vault_path="$(yq -r '.spec.vaultPath // ""' "${schema_file}")"
  [[ -n "${actual_vault_path}" ]] || die "Secret schema is missing spec.vaultPath: ${schema_file}"
  [[ "${actual_vault_path}" == "${expected_vault_path}" ]] || die "Secret schema vaultPath mismatch in ${schema_file}: expected ${expected_vault_path}, got ${actual_vault_path}"

  owner="$(yq -r '.spec.owner // ""' "${schema_file}")"
  [[ -n "${owner}" ]] || die "Secret schema is missing spec.owner: ${schema_file}"

  allow_additional="$(yq -r '.spec.allowAdditionalKeys // false' "${schema_file}")"
  if [[ "${allow_additional}" != "true" && "${allow_additional}" != "false" ]]; then
    die "Secret schema must set spec.allowAdditionalKeys to true or false: ${schema_file}"
  fi

  while IFS= read -r consumer_file; do
    [[ -n "${consumer_file}" ]] || continue
    consumer_path="$(resolve_repo_path "${consumer_file}")"
    require_file "${consumer_path}"
    if ! rg -F -q "key: ${expected_vault_path}" "${consumer_path}"; then
      die "Consumer file does not reference ${expected_vault_path}: ${consumer_file}"
    fi
  done < <(yq -r '.spec.consumerFiles[]? // empty' "${schema_file}")

  if [[ "$(yq -r '.spec.consumerFiles // [] | length' "${schema_file}")" -lt 1 ]]; then
    die "Secret schema must list at least one consumer file: ${schema_file}"
  fi

  while IFS= read -r required_key; do
    [[ -n "${required_key}" ]] || continue
    validate_schema_key_name "${schema_file}" "${required_key}"
    if array_contains "${required_key}" "${seen_keys[@]}"; then
      die "Secret schema repeats the same key more than once in ${schema_file}: ${required_key}"
    fi
    seen_keys+=("${required_key}")
  done < <(yq -r '.spec.requiredKeys[]? // empty' "${schema_file}")

  while IFS= read -r optional_key; do
    [[ -n "${optional_key}" ]] || continue
    validate_schema_key_name "${schema_file}" "${optional_key}"
    if array_contains "${optional_key}" "${seen_keys[@]}"; then
      die "Secret schema repeats the same key more than once in ${schema_file}: ${optional_key}"
    fi
    seen_keys+=("${optional_key}")
  done < <(yq -r '.spec.optionalKeys[]? // empty' "${schema_file}")
}

validate_secret_env_file() {
  local templates_root="$1"
  local template_file="$2"
  local secure_file="$3"
  local schema_file allow_additional required_key actual_key actual_value
  local validator_count validator_key must_contain must_not_contain
  local expected_vault_path
  local -a allowed_keys=()
  local -a seen_keys=()
  local placeholder_pattern
  local validator_index

  schema_file="${template_file%.template}.schema.yaml"
  expected_vault_path="${template_file#${templates_root}/}"
  expected_vault_path="${expected_vault_path%.env.template}"
  allow_additional="$(yq -r '.spec.allowAdditionalKeys // false' "${schema_file}")"

  while IFS= read -r required_key; do
    [[ -n "${required_key}" ]] || continue
    allowed_keys+=("${required_key}")
    if ! actual_value="$(env_file_optional_value "${secure_file}" "${required_key}")"; then
      die "Secure input is missing required key ${required_key}: ${secure_file}"
    fi
    [[ -n "${actual_value}" ]] || die "Secure input contains an empty required key ${required_key}: ${secure_file}"
  done < <(yq -r '.spec.requiredKeys[]? // empty' "${schema_file}")

  while IFS= read -r required_key; do
    [[ -n "${required_key}" ]] || continue
    allowed_keys+=("${required_key}")
  done < <(yq -r '.spec.optionalKeys[]? // empty' "${schema_file}")

  while IFS= read -r actual_key; do
    [[ -n "${actual_key}" ]] || continue

    if array_contains "${actual_key}" "${seen_keys[@]}"; then
      die "Secure input contains the same key more than once in ${secure_file}: ${actual_key}"
    fi
    seen_keys+=("${actual_key}")

    if [[ "${allow_additional}" != "true" ]] && ! array_contains "${actual_key}" "${allowed_keys[@]}"; then
      die "Secure input contains an unexpected key for ${expected_vault_path}: ${actual_key}"
    fi

    actual_value="$(env_file_value "${secure_file}" "${actual_key}")"
    while IFS= read -r placeholder_pattern; do
      [[ -n "${placeholder_pattern}" ]] || continue
      if [[ "${actual_value}" =~ ${placeholder_pattern} ]]; then
        die "Secure input still contains a placeholder-like value for ${actual_key} in ${secure_file}"
      fi
    done < <(yq -r '.spec.placeholderPatterns[]? // empty' "${schema_file}")
  done < <(env_file_keys "${secure_file}")

  validator_count="$(yq -r '.spec.valueValidators // [] | length' "${schema_file}")"
  validator_index=0
  while (( validator_index < validator_count )); do
    validator_key="$(yq -r ".spec.valueValidators[${validator_index}].key // \"\"" "${schema_file}")"
    [[ -n "${validator_key}" ]] || die "Secret schema contains a validator without a key: ${schema_file}"

    if ! actual_value="$(env_file_optional_value "${secure_file}" "${validator_key}")"; then
      die "Secure input is missing a key required by valueValidators in ${schema_file}: ${validator_key}"
    fi

    while IFS= read -r must_contain; do
      [[ -n "${must_contain}" ]] || continue
      if [[ "${actual_value}" != *"${must_contain}"* ]]; then
        die "Secure input value for ${validator_key} must contain '${must_contain}' in ${secure_file}"
      fi
    done < <(yq -r ".spec.valueValidators[${validator_index}].mustContain[]? // empty" "${schema_file}")

    while IFS= read -r must_not_contain; do
      [[ -n "${must_not_contain}" ]] || continue
      if [[ "${actual_value}" == *"${must_not_contain}"* ]]; then
        die "Secure input value for ${validator_key} must not contain '${must_not_contain}' in ${secure_file}"
      fi
    done < <(yq -r ".spec.valueValidators[${validator_index}].mustNotContain[]? // empty" "${schema_file}")

    validator_index=$((validator_index + 1))
  done
}

REQUIRE_SECURE_FILES=false
COMMON_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-secure-files)
      REQUIRE_SECURE_FILES=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      COMMON_ARGS+=("$1")
      shift
      ;;
  esac
done

if ! parse_common_args "${COMMON_ARGS[@]}"; then
  usage
  exit 0
fi

require_command find rg yq

templates_root="$(resolve_repo_path "bootstrap/secrets/templates")"
templates_clusters_root="${templates_root}/clusters"
vault_secrets_dir="$(resolve_repo_path "${VAULT_SECRETS_DIR}")"

require_dir "${templates_root}"
require_dir "${templates_clusters_root}"
require_dir "${vault_secrets_dir}"

target_clusters=()

if [[ -n "${MANAGEMENT_INVENTORY_FILE}" ]]; then
  resolved_management_inventory="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
  target_cluster="$(inventory_name "${resolved_management_inventory}")"
  if ! array_contains "${target_cluster}" "${target_clusters[@]}"; then
    target_clusters+=("${target_cluster}")
  fi
fi

for remote_inventory in "${REMOTE_INVENTORY_FILES[@]}"; do
  resolved_remote_inventory="$(resolve_repo_path "${remote_inventory}")"
  target_cluster="$(inventory_name "${resolved_remote_inventory}")"
  if ! array_contains "${target_cluster}" "${target_clusters[@]}"; then
    target_clusters+=("${target_cluster}")
  fi
done

if (( ${#target_clusters[@]} == 0 )); then
  while IFS= read -r cluster_dir; do
    target_cluster="${cluster_dir##*/}"
    if ! array_contains "${target_cluster}" "${target_clusters[@]}"; then
      target_clusters+=("${target_cluster}")
    fi
  done < <(find "${templates_clusters_root}" -mindepth 1 -maxdepth 1 -type d | sort)
fi

validated_template_count=0
validated_secure_file_count=0

for target_cluster in "${target_clusters[@]}"; do
  cluster_templates_dir="${templates_clusters_root}/${target_cluster}"
  require_dir "${cluster_templates_dir}"

  while IFS= read -r template_file; do
    secure_file="${vault_secrets_dir}/${template_file#${templates_root}/}"
    secure_file="${secure_file%.template}"

    validate_secret_schema "${templates_root}" "${template_file}"

    if [[ -f "${secure_file}" ]]; then
      validate_secret_env_file "${templates_root}" "${template_file}" "${secure_file}"
      validated_secure_file_count=$((validated_secure_file_count + 1))
    elif [[ "${REQUIRE_SECURE_FILES}" == "true" ]]; then
      die "Missing secure input for template: ${secure_file}"
    else
      warn "Missing secure input for template: ${secure_file}"
    fi

    validated_template_count=$((validated_template_count + 1))
  done < <(find "${cluster_templates_dir}" -type f -name '*.env.template' | sort)
done

(( validated_template_count > 0 )) || die "No secret templates found under ${templates_clusters_root}"

while IFS= read -r secure_file; do
  relative_path="${secure_file#${vault_secrets_dir}/}"
  [[ "${relative_path}" == clusters/* ]] || die "Secure input must live under ${vault_secrets_dir}/clusters: ${secure_file}"

  secure_cluster="${relative_path#clusters/}"
  secure_cluster="${secure_cluster%%/*}"

  if ! array_contains "${secure_cluster}" "${target_clusters[@]}"; then
    continue
  fi

  template_file="${templates_root}/${relative_path}.template"
  if [[ ! -f "${template_file}" ]]; then
    die "Secure input has no matching template: ${secure_file}"
  fi
done < <(find "${vault_secrets_dir}" -type f -name '*.env' | sort)

log "Validated ${validated_template_count} secret templates and ${validated_secure_file_count} secure input files."
