#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/register-remote-cluster.sh --management-inventory <path> --inventory <path> [common flags]

Creates or updates the Argo CD cluster Secret for a remote cluster using the
metadata carried in the inventory file.
EOF
  usage_common_flags
}

if ! parse_common_args "$@"; then
  usage
  exit 0
fi

require_command kubectl jq yq
[[ -n "${MANAGEMENT_INVENTORY_FILE}" ]] || die "--management-inventory is required"
[[ -n "${INVENTORY_FILE}" ]] || die "--inventory is required"

management_inventory="$(resolve_repo_path "${MANAGEMENT_INVENTORY_FILE}")"
remote_inventory="$(resolve_repo_path "${INVENTORY_FILE}")"
inventory_validate "${management_inventory}"
inventory_validate "${remote_inventory}"

[[ "$(inventory_cluster_class "${remote_inventory}")" != "management" ]] || die "--inventory must point to a remote cluster inventory"

management_kubeconfig="$(resolve_repo_path "$(inventory_kubeconfig "${management_inventory}")")"
management_context="$(inventory_context "${management_inventory}")"
remote_kubeconfig="$(resolve_repo_path "$(inventory_kubeconfig "${remote_inventory}")")"
remote_context="$(inventory_context "${remote_inventory}")"
require_file "${management_kubeconfig}"
require_file "${remote_kubeconfig}"

management_kubectl_args=()
management_kubectl_args+=(--kubeconfig "${management_kubeconfig}")
if [[ -n "${management_context}" ]]; then
  management_kubectl_args+=(--context "${management_context}")
fi

remote_kubectl_args=()
remote_kubectl_args+=(--kubeconfig "${remote_kubeconfig}")
if [[ -n "${remote_context}" ]]; then
  remote_kubectl_args+=(--context "${remote_context}")
fi

require_kubectl_connectivity "management" "${management_kubectl_args[@]}"
require_kubectl_connectivity "remote" "${remote_kubectl_args[@]}"

cluster_name="$(inventory_name "${remote_inventory}")"
cluster_role="$(inventory_role "${remote_inventory}")"
environment_name="$(inventory_environment "${remote_inventory}")"
cluster_class="$(inventory_cluster_class "${remote_inventory}")"
control_plane_mode="$(inventory_control_plane_mode "${remote_inventory}")"

cluster_config_json="$(kubectl "${remote_kubectl_args[@]}" config view --raw --flatten --minify -o json)"
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
  die "Exec-based kubeconfig auth is not supported for declarative Argo CD cluster registration"
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
  name: ${cluster_name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    tenant: litomi
    role: ${cluster_role}
    environment: ${environment_name}
    litomi.io/cluster-class: ${cluster_class}
    litomi.io/control-plane-mode: ${control_plane_mode}
    bootstrap.litomi.io/managed-by: register-remote-cluster
type: Opaque
stringData:
  name: ${cluster_name}
  server: ${server}
  config: |
$(jq '.' <<<"${cluster_secret_config}" | sed 's/^/    /')
EOF

log "Applying Argo CD cluster Secret for ${cluster_name}"
kubectl_apply_file "${tmp_manifest}" "${management_kubectl_args[@]}"

wait_for_jsonpath_value \
  "cluster secret class label for ${cluster_name}" \
  "${cluster_class}" \
  120 \
  '{.metadata.labels["litomi.io/cluster-class"]}' \
  kubectl "${management_kubectl_args[@]}" -n argocd get secret "${cluster_name}"

log "Cluster ${cluster_name} is registered for ApplicationSet discovery."
