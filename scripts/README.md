# Bootstrap Scripts

이 디렉터리는 Ubuntu 호스트에서 `litomi-gitops`를 클론한 뒤 실행하는 운영 스크립트를 모아둔 곳이에요.

## 권장 순서

```zsh
./scripts/preflight-host.sh --config /secure/bootstrap/management.env
./scripts/bootstrap-management-argocd.sh --config /secure/bootstrap/management.env
./scripts/register-workload-cluster.sh --config /secure/bootstrap/clusters/stg-01.env --cluster-name stg-01 --kubeconfig /secure/kubeconfigs/stg-01.yaml
./scripts/bootstrap-vault-auth.sh --config /secure/bootstrap/secrets.env --kubeconfig /secure/kubeconfigs/stg-01.yaml
./scripts/seed-vault-kv.sh --config /secure/bootstrap/secrets.env --vault-secrets-dir /secure/vault-secrets
./scripts/verify-platform.sh --config /secure/bootstrap/management.env --cluster-name stg-01
```

## 구성 파일 예시

- 관리 클러스터: `bootstrap/config/management.env.example`
- 워크로드 클러스터 등록: `bootstrap/config/clusters/cluster-name.env.example`
- Vault auth / seed: `bootstrap/config/secrets.env.example`

## 설계 원칙

- 가능한 상태는 GitOps 리소스로 두고, 최초 1회 bootstrap만 스크립트로 다뤄요.
- 모든 스크립트는 재실행 가능하게 만들고, `--dry-run`을 지원해요.
- 호스트 패키지 설치와 k3s 설치는 이 레포 밖에서 준비하고, 이 레포는 검증과 Kubernetes/Vault bootstrap만 맡아요.
