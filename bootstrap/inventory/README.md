# Cluster Inventory

이 디렉터리의 템플릿은 `/secure/bootstrap/inventory/*.yaml`로 복사해서 채우는 기준 파일이에요.

각 inventory는 다음 용도로 같이 써요.

- host/bootstrap 레이어: kube-vip API VIP, MetalLB pool, 노드 목록
- GitOps bootstrap 레이어: kubeconfig path, cluster role, environment, cluster class, control-plane mode
- Vault bootstrap 레이어: cluster별 Kubernetes auth mount 이름

스크립트가 실제로 읽는 최소 필드는 아래예요.

- `metadata.name`
- `spec.role`
- `spec.environment`
- `spec.clusterClass`
- `spec.controlPlaneMode`
- `spec.bootstrap.kubeconfig`
- `spec.bootstrap.context`
- `spec.vault.authMount`

나머지 네트워크/노드 항목은 host bootstrap과 운영 문서화를 위해 같이 유지해요.

cluster class별 권장 규칙은 아래예요.

- `management`
  - role: `management`
  - environment: `mgmt`
  - controlPlaneMode: `single-server-elastic-workers`
  - nodes: `server` 1개 + `worker` 0..N
- `environment-runtime`
  - role: `workload`
  - environment: `prod`, `stg`, `dev`
  - controlPlaneMode: `single-server-elastic-workers`
  - nodes: `server` 1개 + `worker` 0..N

모든 cluster는 `server`도 schedulable 상태를 유지하는 것을 기본으로 봐요.
물리 host 수가 늘어나더라도 이 필드들로 GitOps 경로를 바꾸지 않아요.
host/VM 배치와 worker 증감은 외부 IaC/가상화 계층에서 처리하고, 이 inventory는 고정 cluster identity를 표현하는 계약으로 써요.
