# Bootstrap Scripts

이 디렉터리는 management cluster 1개와 remote cluster 여러 개를 inventory로 받아 동작해요.

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
각 secret은 `.env.template` 옆의 `.env.schema.yaml`로 필수 키, consumer manifest,
placeholder 검출 규칙을 같이 관리해요.

management cluster의 Argo CD repo credential 파일은
`/secure/vault-secrets/clusters/mgmt-01/argocd/github-repo-creds.env` 경로를 기본으로 보고,
GitHub App 기준으로 아래 키를 기대해요.

```dotenv
url=https://github.com/litomi2026/litomi-gitops.git
type=git
githubAppID=123456
githubAppInstallationID=78901234
githubAppPrivateKey=$'-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n'
```

GitHub Enterprise Server면 `githubAppEnterpriseBaseUrl=https://<ghe-host>/api/v3`를 추가할 수 있어요.

## 권장 순서

```zsh
./scripts/preflight-host.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-secrets-dir /secure/vault-secrets \
  --vault-token-file /secure/bootstrap/vault/root-token

./scripts/validate-vault-secrets.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-secrets-dir /secure/vault-secrets \
  --require-secure-files

./scripts/bootstrap-management-argocd.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-secrets-dir /secure/vault-secrets

./scripts/bootstrap-vault-auth.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/prod-01.yaml \
  --vault-token-file /secure/bootstrap/vault/root-token

./scripts/seed-vault-kv.sh \
  --vault-secrets-dir /secure/vault-secrets \
  --vault-token-file /secure/bootstrap/vault/root-token

./scripts/verify-platform.sh \
  --management-inventory /secure/bootstrap/inventory/mgmt-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/stg-01.yaml \
  --remote-inventory /secure/bootstrap/inventory/prod-01.yaml
```

## 설계 원칙

- host/bootstrap 레이어는 inventory YAML을 입력으로 받아 kube-vip / MetalLB / node 배치를 문서화해요.
- GitOps 레이어는 Argo CD가 `management` / `environment-runtime` cluster class별 경로를 소유해요.
- Vault seed는 `/secure/vault-secrets/clusters/<cluster>/<namespace>/<secret>.env`를 `kv/clusters/...`에 그대로 넣어요.
- secret template은 `.env.template`, contract는 `.env.schema.yaml`, 실제 값은 `/secure/vault-secrets`로 나눠서 관리해요.
- workload cluster의 public exposure(`litomi` public ingress, `cloudflared`, `gtm-server`)는 `clusters/<cluster>/litomi/public-edge` 아래에서 같이 관리돼요.
- remote cluster 등록은 `scripts/register-remote-cluster.sh`가 담당하고, 기존 `scripts/register-workload-cluster.sh`는 호환용 래퍼예요.
- `mgmt-01`, `prod-01`, `stg-01`은 cluster 경계를 고정하고, 물리 host 수가 늘어나도 GitOps topology는 바꾸지 않아요.
- 모든 guest cluster는 `single-server-elastic-workers` 표준을 써요.
- `prod-01`, `stg-01`은 env-local Redis를 직접 띄우고, DB는 external endpoint를 사용해요.
- runtime hard dependency는 shared cluster로 두지 않지만, external DB 같은 명시적 외부 의존성은 secret 계약으로 관리해요.
- 중앙 logging/tracing/backup/Vault는 `mgmt-01`에 두되, 이미 동기화된 runtime secret/config 덕분에 `mgmt-01`의 일시 장애가 앱 런타임을 즉시 멈추게 만들지 않는 구성을 기본으로 봐요.
