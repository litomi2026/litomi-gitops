# Vault Secret Templates

이 디렉터리는 `/secure/vault-secrets` 아래에 둘 실제 입력 파일의 템플릿이에요.

- template path: `bootstrap/secrets/templates/clusters/<cluster>/<namespace>/<secret>.env.template`
- secure input path: `/secure/vault-secrets/clusters/<cluster>/<namespace>/<secret>.env`
- Vault KV path: `kv/clusters/<cluster>/<namespace>/<secret>`

`scripts/seed-vault-kv.sh`는 shell-compatible `KEY=value` 파일을 읽어서 그대로 Vault KV에 넣어요.
그래서 property 이름은 env 파일에서 안전한 `snake_case`를 사용해요.

예:

- `access_key`
- `secret_key`
- `bucket_chunks`
- `bucket_traces`
- `root_user`
- `root_password`

멀티라인 값은 `$'...\n...'` 형태로 넣으면 그대로 복원돼요.
