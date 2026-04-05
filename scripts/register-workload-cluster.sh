#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/register-workload-cluster.sh [common flags]

Creates or updates an Argo CD workload-cluster secret declaratively.
--kubeconfig/--context refer to the workload cluster to register.
Management-cluster access comes from MANAGEMENT_KUBECONFIG/MANAGEMENT_CONTEXT in
the config file or environment.
EOF
  usage_common_flags
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

load_config_file
require_command kubectl jq

cluster_name="${CLUSTER_NAME:-${WORKLOAD_CLUSTER_NAME:-}}"
[[ -n "${cluster_name}" ]] || die "--cluster-name or WORKLOAD_CLUSTER_NAME is required"

workload_kubeconfig="${WORKLOAD_KUBECONFIG:-${KUBECONFIG_PATH}}"
workload_context="${WORKLOAD_CONTEXT:-${KUBE_CONTEXT}}"
management_kubeconfig="${MANAGEMENT_KUBECONFIG:-}"
management_context="${MANAGEMENT_CONTEXT:-}"
argocd_namespace="${ARGOCD_NAMESPACE:-argocd}"
cluster_secret_name="${CLUSTER_SECRET_NAME:-${cluster_name}}"

[[ -n "${workload_kubeconfig}" ]] || die "WORKLOAD_KUBECONFIG or --kubeconfig is required"

workload_kubeconfig="$(resolve_repo_path "${workload_kubeconfig}")"
require_file "${workload_kubeconfig}"

if [[ -n "${management_kubeconfig}" ]]; then
  management_kubeconfig="$(resolve_repo_path "${management_kubeconfig}")"
  require_file "${management_kubeconfig}"
fi

declare -a workload_kubectl_args management_kubectl_args
setup_kubectl_args workload_kubectl_args "${workload_kubeconfig}" "${workload_context}"
setup_kubectl_args management_kubectl_args "${management_kubeconfig}" "${management_context}"

require_kubectl_connectivity "workload" "${workload_kubectl_args[@]}"
require_kubectl_connectivity "management" "${management_kubectl_args[@]}"

cluster_config_json="$(kubectl "${workload_kubectl_args[@]}" config view --raw --flatten --minify -o json)"
server="$(jq -r '.clusters[0].cluster.server' <<<"${cluster_config_json}")"
ca_data="$(jq -r '.clusters[0].cluster["certificate-authority-data"] // empty' <<<"${cluster_config_json}")"
insecure_skip_tls="$(jq -r '.clusters[0].cluster["insecure-skip-tls-verify"] // false' <<<"${cluster_config_json}")"
bearer_token="$(jq -r '.users[0].user.token // empty' <<<"${cluster_config_json}")"
client_cert_data="$(jq -r '.users[0].user["client-certificate-data"] // empty' <<<"${cluster_config_json}")"
client_key_data="$(jq -r '.users[0].user["client-key-data"] // empty' <<<"${cluster_config_json}")"
username="$(jq -r '.users[0].user.username // empty' <<<"${cluster_config_json}")"
password="$(jq -r '.users[0].user.password // empty' <<<"${cluster_config_json}")"
exec_command="$(jq -r '.users[0].user.exec.command // empty' <<<"${cluster_config_json}")"

if [[ -n "${exec_command}" ]]; then
  die "Exec-based kubeconfig auth is not supported for declarative cluster registration yet."
fi

cluster_secret_config="$(jq -nc \
  --arg token "${bearer_token}" \
  --arg certData "${client_cert_data}" \
  --arg keyData "${client_key_data}" \
  --arg user "${username}" \
  --arg pass "${password}" \
  --arg caData "${ca_data}" \
  --argjson insecure "${insecure_skip_tls}" \
  '
  (
    {}
    + (if $token != "" then {bearerToken: $token} else {} end)
    + (if $user != "" then {username: $user} else {} end)
    + (if $pass != "" then {password: $pass} else {} end)
    + {
        tlsClientConfig:
          (
            {}
            + (if $caData != "" then {caData: $caData} else {} end)
            + (if $certData != "" then {certData: $certData} else {} end)
            + (if $keyData != "" then {keyData: $keyData} else {} end)
            + (if $insecure then {insecure: true} else {} end)
          )
      }
  )')"

tmp_manifest="$(mktemp)"
trap 'rm -f "${tmp_manifest}"' EXIT

cat >"${tmp_manifest}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster_secret_name}
  namespace: ${argocd_namespace}
  labels:
    argocd.argoproj.io/secret-type: cluster
    tenant: litomi
    role: workload
    bootstrap.litomi.io/managed-by: register-workload-cluster
type: Opaque
stringData:
  name: ${cluster_name}
  server: ${server}
  config: |
$(jq '.' <<<"${cluster_secret_config}" | sed 's/^/    /')
EOF

log "Registering workload cluster ${cluster_name} in Argo CD"
kubectl_apply_file "${tmp_manifest}" "${management_kubectl_args[@]}"

wait_for_jsonpath_value \
  "registered cluster secret label" \
  "workload" \
  120 \
  '{.metadata.labels.role}' \
  kubectl "${management_kubectl_args[@]}" -n "${argocd_namespace}" get secret "${cluster_secret_name}"

log "Cluster ${cluster_name} is registered for ApplicationSet discovery."
