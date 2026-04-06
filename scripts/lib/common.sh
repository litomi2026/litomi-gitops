#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DRY_RUN=false
INVENTORY_FILE=""
MANAGEMENT_INVENTORY_FILE=""
WORKLOAD_INVENTORY_FILES=()
VAULT_SECRETS_DIR="/secure/vault-secrets"
VAULT_TOKEN_FILE=""
VAULT_ADDR_OVERRIDE=""
REPO_CREDS_FILE=""

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

print_command() {
  local quoted=()
  local part

  for part in "$@"; do
    quoted+=("$(printf '%q' "${part}")")
  done

  printf '+ %s\n' "${quoted[*]}"
}

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    print_command "$@"
    return 0
  fi

  "$@"
}

resolve_repo_path() {
  local input_path="$1"

  if [[ -z "${input_path}" ]]; then
    printf '%s' ""
    return 0
  fi

  if [[ "${input_path}" = /* ]]; then
    printf '%s' "${input_path}"
    return 0
  fi

  printf '%s/%s' "${REPO_ROOT}" "${input_path}"
}

require_command() {
  local command_name

  for command_name in "$@"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      die "Required command not found: ${command_name}"
    fi
  done
}

require_file() {
  local file_path="$1"

  [[ -f "${file_path}" ]] || die "Required file not found: ${file_path}"
}

require_dir() {
  local dir_path="$1"

  [[ -d "${dir_path}" ]] || die "Required directory not found: ${dir_path}"
}

load_file_contents() {
  local file_path="$1"
  require_file "${file_path}"
  <"${file_path}" tr -d '\r'
}

base64_decode() {
  if base64 --decode </dev/null >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

decode_env_value() {
  local raw_value="$1"
  local evaluated_value=""

  # shellcheck disable=SC2086
  eval "evaluated_value=${raw_value}"
  printf '%b' "${evaluated_value}"
}

env_file_value() {
  local env_file="$1"
  local expected_key="$2"
  local line key raw_value

  require_file "${env_file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*export[[:space:]]+ ]] && line="${line#export }"

    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      die "Unsupported env line in ${env_file}: ${line}"
    fi

    key="${line%%=*}"
    raw_value="${line#*=}"

    if [[ "${key}" == "${expected_key}" ]]; then
      decode_env_value "${raw_value}"
      return 0
    fi
  done <"${env_file}"

  die "Key '${expected_key}' not found in ${env_file}"
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --inventory)
        [[ $# -ge 2 ]] || die "--inventory requires a value"
        INVENTORY_FILE="$2"
        shift 2
        ;;
      --management-inventory)
        [[ $# -ge 2 ]] || die "--management-inventory requires a value"
        MANAGEMENT_INVENTORY_FILE="$2"
        shift 2
        ;;
      --workload-inventory)
        [[ $# -ge 2 ]] || die "--workload-inventory requires a value"
        WORKLOAD_INVENTORY_FILES+=("$2")
        shift 2
        ;;
      --vault-secrets-dir)
        [[ $# -ge 2 ]] || die "--vault-secrets-dir requires a value"
        VAULT_SECRETS_DIR="$2"
        shift 2
        ;;
      --vault-token-file)
        [[ $# -ge 2 ]] || die "--vault-token-file requires a value"
        VAULT_TOKEN_FILE="$2"
        shift 2
        ;;
      --vault-addr)
        [[ $# -ge 2 ]] || die "--vault-addr requires a value"
        VAULT_ADDR_OVERRIDE="$2"
        shift 2
        ;;
      --repo-creds-file)
        [[ $# -ge 2 ]] || die "--repo-creds-file requires a value"
        REPO_CREDS_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        return 1
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

usage_common_flags() {
  cat <<'EOF'
Common flags:
  --inventory <path>
  --management-inventory <path>
  --workload-inventory <path>   (repeatable)
  --vault-secrets-dir <path>
  --vault-token-file <path>
  --vault-addr <url>
  --repo-creds-file <path>
  --dry-run
EOF
}

inventory_value() {
  local inventory_file="$1"
  local expression="$2"

  require_file "${inventory_file}"
  yq e -r "${expression} // \"\"" "${inventory_file}"
}

inventory_name() {
  inventory_value "$1" '.metadata.name'
}

inventory_role() {
  inventory_value "$1" '.spec.role'
}

inventory_environment() {
  inventory_value "$1" '.spec.environment'
}

inventory_size_profile() {
  inventory_value "$1" '.spec.sizeProfile'
}

inventory_public_edge() {
  local raw_value

  raw_value="$(inventory_value "$1" '.spec.addons.publicEdge')"

  case "${raw_value,,}" in
    enabled|true|yes|1)
      printf 'enabled'
      ;;
    disabled|false|no|0|"")
      printf 'disabled'
      ;;
    *)
      die "Unsupported publicEdge value in $(inventory_name "$1"): ${raw_value}"
      ;;
  esac
}

inventory_internal_domain() {
  inventory_value "$1" '.spec.network.internalDomain'
}

inventory_kubeconfig() {
  inventory_value "$1" '.spec.bootstrap.kubeconfig'
}

inventory_context() {
  inventory_value "$1" '.spec.bootstrap.context'
}

inventory_k3s_token_file() {
  inventory_value "$1" '.spec.bootstrap.k3sTokenFile'
}

inventory_vault_auth_mount() {
  local auth_mount

  auth_mount="$(inventory_value "$1" '.spec.vault.authMount')"

  if [[ -n "${auth_mount}" ]]; then
    printf '%s' "${auth_mount}"
    return 0
  fi

  printf 'k8s-%s' "$(inventory_name "$1")"
}

inventory_validate() {
  local inventory_file
  local cluster_name

  inventory_file="$(resolve_repo_path "$1")"
  require_file "${inventory_file}"

  cluster_name="$(inventory_name "${inventory_file}")"
  [[ -n "${cluster_name}" ]] || die "Inventory ${inventory_file} is missing metadata.name"
  [[ -n "$(inventory_role "${inventory_file}")" ]] || die "Inventory ${inventory_file} is missing spec.role"
  [[ -n "$(inventory_environment "${inventory_file}")" ]] || die "Inventory ${inventory_file} is missing spec.environment"
  [[ -n "$(inventory_size_profile "${inventory_file}")" ]] || die "Inventory ${inventory_file} is missing spec.sizeProfile"
  [[ -n "$(inventory_kubeconfig "${inventory_file}")" ]] || die "Inventory ${inventory_file} is missing spec.bootstrap.kubeconfig"
}

require_kubectl_connectivity() {
  local cluster_label="$1"
  shift

  if ! kubectl "$@" cluster-info >/dev/null 2>&1; then
    die "Unable to connect to ${cluster_label} cluster with kubectl"
  fi
}

kubectl_apply_file() {
  local manifest_file="$1"
  shift

  run kubectl "$@" apply -f "${manifest_file}"
}

kubectl_apply_kustomize() {
  local kustomize_path="$1"
  shift

  run kubectl "$@" apply -k "${kustomize_path}"
}

kubectl_wait_rollout() {
  local namespace="$1"
  local resource_name="$2"
  local timeout="$3"
  shift 3

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_command kubectl "$@" -n "${namespace}" rollout status "${resource_name}" --timeout="${timeout}"
    return 0
  fi

  kubectl "$@" -n "${namespace}" rollout status "${resource_name}" --timeout="${timeout}"
}

kubectl_wait_rollout_if_exists() {
  local namespace="$1"
  local resource_name="$2"
  local timeout="$3"
  shift 3

  if kubectl "$@" -n "${namespace}" get "${resource_name}" >/dev/null 2>&1; then
    kubectl_wait_rollout "${namespace}" "${resource_name}" "${timeout}" "$@"
  fi
}

wait_for_jsonpath_value() {
  local description="$1"
  local expected_value="$2"
  local timeout_seconds="$3"
  local jsonpath_expression="$4"
  shift 4
  local kubectl_cmd=("$@")
  local started_at
  local current_value=""

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_command "${kubectl_cmd[@]}" -o "jsonpath=${jsonpath_expression}"
    return 0
  fi

  started_at="$(date +%s)"

  while true; do
    if current_value="$("${kubectl_cmd[@]}" -o "jsonpath=${jsonpath_expression}" 2>/dev/null)"; then
      if [[ "${current_value}" == "${expected_value}" ]]; then
        return 0
      fi
    fi

    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      die "Timed out waiting for ${description}; expected '${expected_value}', got '${current_value}'"
    fi

    sleep 5
  done
}
