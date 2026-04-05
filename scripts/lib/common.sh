#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DRY_RUN=false
CONFIG_FILE=""
KUBECONFIG_PATH="${KUBECONFIG:-}"
KUBE_CONTEXT=""
CLUSTER_NAME=""
VAULT_SECRETS_DIR=""

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

bool_from_env() {
  local value="${1:-}"

  case "${value,,}" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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

load_config_file() {
  if [[ -z "${CONFIG_FILE}" ]]; then
    return 0
  fi

  local resolved_config
  resolved_config="$(resolve_repo_path "${CONFIG_FILE}")"
  require_file "${resolved_config}"

  # shellcheck disable=SC1090
  set -a && . "${resolved_config}" && set +a
  CONFIG_FILE="${resolved_config}"
}

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || die "--config requires a value"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --kubeconfig)
        [[ $# -ge 2 ]] || die "--kubeconfig requires a value"
        KUBECONFIG_PATH="$2"
        shift 2
        ;;
      --context)
        [[ $# -ge 2 ]] || die "--context requires a value"
        KUBE_CONTEXT="$2"
        shift 2
        ;;
      --cluster-name)
        [[ $# -ge 2 ]] || die "--cluster-name requires a value"
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --vault-secrets-dir)
        [[ $# -ge 2 ]] || die "--vault-secrets-dir requires a value"
        VAULT_SECRETS_DIR="$2"
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

setup_kubectl_args() {
  local -n out_args="$1"
  local kubeconfig_value="${2:-}"
  local context_value="${3:-}"

  out_args=()

  if [[ -n "${kubeconfig_value}" ]]; then
    out_args+=(--kubeconfig "${kubeconfig_value}")
  fi

  if [[ -n "${context_value}" ]]; then
    out_args+=(--context "${context_value}")
  fi
}

kubectl_wait_rollout() {
  local namespace="$1"
  local resource_name="$2"
  local timeout="${3:-300s}"
  shift 3
  local kubectl_args=("$@")

  if [[ "${DRY_RUN}" == "true" ]]; then
    print_command kubectl "${kubectl_args[@]}" -n "${namespace}" rollout status "${resource_name}" --timeout="${timeout}"
    return 0
  fi

  kubectl "${kubectl_args[@]}" -n "${namespace}" rollout status "${resource_name}" --timeout="${timeout}"
}

kubectl_apply_file() {
  local manifest_file="$1"
  shift
  local kubectl_args=("$@")

  run kubectl "${kubectl_args[@]}" apply -f "${manifest_file}"
}

kubectl_apply_kustomize() {
  local kustomize_path="$1"
  shift
  local kubectl_args=("$@")

  run kubectl "${kubectl_args[@]}" apply -k "${kustomize_path}"
}

kubectl_get_json() {
  local resource_name="$1"
  shift
  local kubectl_args=("$@")

  kubectl "${kubectl_args[@]}" get "${resource_name}" -o json
}

require_kubectl_connectivity() {
  local cluster_label="$1"
  shift
  local kubectl_args=("$@")

  if ! kubectl "${kubectl_args[@]}" cluster-info >/dev/null 2>&1; then
    die "Unable to connect to ${cluster_label} cluster with kubectl"
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

load_file_contents() {
  local file_path="$1"
  require_file "${file_path}"
  <"${file_path}" tr -d '\r'
}

usage_common_flags() {
  cat <<'EOF'
Common flags:
  --config <env-file>
  --kubeconfig <path>
  --context <name>
  --cluster-name <name>
  --vault-secrets-dir <path>
  --dry-run
EOF
}
