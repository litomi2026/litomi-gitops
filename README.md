# litomi-gitops

이 repo는 k3s self-hosting 기준 Litomi production GitOps 구성을 담아요.
현재 표준 운영 모델은 `mgmt-01 / prod-01 / stg-01` 고정 멀티클러스터예요.

## 운영 모델

- `mgmt-01`
  - `schedulable server 1 + optional workers`
  - Argo CD, Vault, MinIO, 중앙 monitoring/logging/tracing, backup control plane 담당
- `prod-01`
  - `schedulable server 1 + optional workers`
  - prod 전용 앱 런타임, env-local Redis, external DB 계약 담당
- `stg-01`
  - `schedulable server 1 + optional workers`
  - stg 전용 앱 런타임, env-local Redis, external DB 계약 담당
- `dev-01`
  - 지금 기본 배포 대상은 아니고, 나중에 `stg-01` 패턴으로 같은 구조를 추가해요.

핵심 원칙은 간단해요.

- cluster 경계는 물리 호스트 수에 따라 바뀌지 않아요.
- 모든 guest cluster는 `single-server-elastic-workers`만 써요.
- `server`는 고정 control plane이고, `worker`만 선택적으로 늘어나거나 줄어요.
- `1 physical host`에서도 `mgmt-01 / prod-01 / stg-01` server VM이 공존할 수 있어야 해요.
- `2+ physical hosts`가 되면 세 cluster의 server VM을 서로 다른 host로 먼저 분산해요.
- 추가 용량은 `prod` worker 우선, 그다음 `mgmt`, 그다음 `stg`, 마지막 `dev`에 배분해요.
- 앱 런타임의 hard dependency는 env-local cluster 안에만 두고, `mgmt-01`은 ops/control plane으로만 써요.

## 레포 구조

- [argocd](/Users/gwak2837/Documents/GitHub/litomi-gitops/argocd): AppProject, ApplicationSet, management root apps
- [bootstrap/inventory/templates](/Users/gwak2837/Documents/GitHub/litomi-gitops/bootstrap/inventory/templates): cluster inventory 템플릿
- [bootstrap/secrets/templates](/Users/gwak2837/Documents/GitHub/litomi-gitops/bootstrap/secrets/templates): Vault seed 입력 템플릿
- [clusters/mgmt-01](/Users/gwak2837/Documents/GitHub/litomi-gitops/clusters/mgmt-01): management control plane
- [clusters/prod-01](/Users/gwak2837/Documents/GitHub/litomi-gitops/clusters/prod-01): prod runtime cluster
- [clusters/stg-01](/Users/gwak2837/Documents/GitHub/litomi-gitops/clusters/stg-01): stg runtime cluster
- [scripts](/Users/gwak2837/Documents/GitHub/litomi-gitops/scripts): bootstrap, registration, verification 스크립트

## Inventory 계약

모든 cluster inventory는 아래 필드를 가져야 해요.

- `spec.role`
- `spec.environment`
- `spec.clusterClass`
- `spec.controlPlaneMode`

현재 표준 class/mode 조합은 아래예요.

- `management` + `single-server-elastic-workers`
- `environment-runtime` + `single-server-elastic-workers`

자세한 내용은 [bootstrap/inventory/README.md](/Users/gwak2837/Documents/GitHub/litomi-gitops/bootstrap/inventory/README.md)를 보면 돼요.

## Runtime 계약

- `prod-01`, `stg-01`은 각자 env-local Redis를 가져요.
- 앱 런타임 secret은 cross-cluster runtime endpoint를 참조하지 않아요.
- 예를 들어 backend `REDIS_URL`은 각 환경 cluster 안의 `redis:6379`를 가리켜야 해요.
- `DATABASE_URL`과 `DIRECT_URL`은 cluster 바깥의 external DB endpoint를 사용해요.
- `mgmt-01`이 잠깐 불안정해도 이미 동기화된 secret/config로 떠 있는 앱이 즉시 멈추지 않는 구성을 기본으로 봐요.

물리 host 배치와 VM provisioning은 이 repo 밖의 IaC/가상화 레이어 책임이에요.
이 repo는 guest cluster 안의 GitOps 구조와 bootstrap 계약만 관리해요.

## Bootstrap

실행 순서와 인자 예시는 [scripts/README.md](/Users/gwak2837/Documents/GitHub/litomi-gitops/scripts/README.md)에 정리돼 있어요.
