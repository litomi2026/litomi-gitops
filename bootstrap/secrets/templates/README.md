# Vault Secret Templates

이 디렉터리는 `/secure/vault-secrets` 아래에 둘 실제 입력 파일의 템플릿이에요.

- template path: `bootstrap/secrets/templates/clusters/<cluster>/<namespace>/<secret>.env.template`
- secure input path: `/secure/vault-secrets/clusters/<cluster>/<namespace>/<secret>.env`
- Vault KV path: `kv/clusters/<cluster>/<namespace>/<secret>`

`scripts/seed-vault-kv.sh`는 shell-compatible `KEY=value` 파일을 읽어서 그대로 Vault KV에 넣어요.
키 이름은 consumer가 기대하는 이름을 그대로 사용해요.
인프라용 secret은 `snake_case`를 주로 쓰고, 앱 env secret은 `UPPER_SNAKE_CASE`를 그대로 써도 됩니다.

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
