# Bootstrap Scripts

이 디렉터리는 `mgmt-01` / `stg-01` / `prod-01` 3개 고정 inventory를 기준으로 동작해요.

## 준비물

- `kubectl`
- `jq`
- `yq`
- `vault`
- Git clone 된 현재 repo
- `/secure/kubeconfigs/*.yaml`
- `/secure/bootstrap/inventory/*.yaml`
- `/secure/vault-secrets/clusters/**`

inventory 템플릿은 `bootstrap/inventory/templates/*.yaml`을 기준으로 만들고,
secret 입력 템플릿은 `bootstrap/secrets/templates/**`를 기준으로 채워요.

## 권장 순서

```zsh
./scripts/preflight-host.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-secrets-dir /secure/vault-secrets \
  --vault-token-file /secure/bootstrap/vault/root-token

./scripts/bootstrap-management-argocd.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-secrets-dir /secure/vault-secrets

./scripts/bootstrap-vault-auth.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-token-file /secure/bootstrap/vault/root-token

./scripts/seed-vault-kv.sh \
  --vault-secrets-dir /secure/vault-secrets \
  --vault-token-file /secure/bootstrap/vault/root-token

./scripts/verify-platform.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --workload-inventory /secure/bootstrap/inventory/prod-01.yaml
```

## 설계 원칙

- host/bootstrap 레이어는 inventory YAML을 입력으로 받아 kube-vip / MetalLB / node 배치를 문서화해요.
- GitOps 레이어는 Argo CD가 `clusters/mgmt-01`, `clusters/stg-01`, `clusters/prod-01`를 소유해요.
- Vault seed는 `/secure/vault-secrets/clusters/<cluster>/<namespace>/<secret>.env`를 `kv/clusters/...`에 그대로 넣어요.
- workload cluster의 public exposure(`litomi` public ingress, `cloudflared`, `gtm-server`, public probes)는 `clusters/<cluster>/litomi/public-edge` 아래에서 같이 관리돼요.
