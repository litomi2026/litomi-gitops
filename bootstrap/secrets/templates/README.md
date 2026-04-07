# Vault Secret Templates

이 디렉터리는 `/secure/vault-secrets` 아래에 둘 실제 입력 파일의 템플릿과 계약 정의를 담아요.

- template path: `bootstrap/secrets/templates/clusters/<cluster>/<namespace>/<secret>.env.template`
- schema path: `bootstrap/secrets/templates/clusters/<cluster>/<namespace>/<secret>.env.schema.yaml`
- secure input path: `/secure/vault-secrets/clusters/<cluster>/<namespace>/<secret>.env`
- Vault KV path: `kv/clusters/<cluster>/<namespace>/<secret>`

`scripts/seed-vault-kv.sh`는 shell-compatible `KEY=value` 파일을 읽어서 그대로 Vault KV에 넣어요.
키 이름은 consumer가 기대하는 이름을 그대로 사용해요.
인프라용 secret은 `snake_case`를 주로 쓰고, 앱 env secret은 `UPPER_SNAKE_CASE`를 그대로 써도 됩니다.

각 secret은 `.env.schema.yaml`에서 아래 정보를 같이 관리해요.

- `spec.vaultPath`: Vault KV 경로와 템플릿 경로의 단일 기준
- `spec.owner`: 운영 소유 경계
- `spec.consumerFiles`: 이 secret을 읽는 `ExternalSecret` manifest
- `spec.requiredKeys` / `spec.optionalKeys`: 필수/선택 키 계약
- `spec.allowAdditionalKeys`: 추가 키 허용 여부
- `spec.placeholderPatterns`: placeholder 값 검출 규칙
- `spec.valueValidators`: 값 수준 제약 조건

`scripts/validate-vault-secrets.sh`는 template, schema, secure input, consumer manifest가 서로 drift 나지 않는지 검증해요.
`scripts/preflight-host.sh`와 `scripts/seed-vault-kv.sh`도 이 검증을 자동으로 실행해요.

`prod-01`, `stg-01`, `dev-01` 같은 runtime cluster 앱 secret은 runtime dependency 위치를 명확히 드러내야 해요.
예를 들어 `REDIS_URL`은 각 cluster 안의 `redis:6379`를 가리키는 것을 기본으로 봐요.
반대로 `DATABASE_URL`과 `DIRECT_URL`은 cluster 바깥의 external DB endpoint를 가리키도록 채워요.

예:

- `access_key`
- `secret_key`
- `REDIS_PASSWORD`
- `REDIS_URL`
- `bucket_chunks`
- `bucket_traces`
- `root_user`
- `root_password`

멀티라인 값은 `$'...\n...'` 형태로 넣으면 그대로 복원돼요.

권장 워크플로는 아래예요.

1. `.env.template`에 예시 값을 유지해요.
2. `.env.schema.yaml`에 필수 키, consumer, placeholder 규칙을 정의해요.
3. 실제 값은 `/secure/vault-secrets/...`에만 넣어요.
4. `scripts/validate-vault-secrets.sh`로 seed 전에 계약을 확인해요.

Argo CD가 private GitHub repo를 GitHub App으로 읽을 때는
`clusters/<cluster>/argocd/github-repo-creds.env`에 아래 키를 넣어요.

```dotenv
url=https://github.com/litomi2026/litomi-gitops.git
type=git
githubAppID=123456
githubAppInstallationID=78901234
githubAppPrivateKey=$'-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n'
# Optional for GitHub Enterprise Server:
# githubAppEnterpriseBaseUrl=https://ghe.example.com/api/v3
```
