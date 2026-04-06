# Cluster Inventory

이 디렉터리의 템플릿은 `/secure/bootstrap/inventory/*.yaml`로 복사해서 채우는 기준 파일이에요.

각 inventory는 다음 용도로 같이 써요.

- host/bootstrap 레이어: kube-vip API VIP, MetalLB pool, 노드 목록
- GitOps bootstrap 레이어: kubeconfig path, cluster role, environment, size profile, addon label
- Vault bootstrap 레이어: cluster별 Kubernetes auth mount 이름

스크립트가 실제로 읽는 최소 필드는 아래예요.

- `metadata.name`
- `spec.role`
- `spec.environment`
- `spec.sizeProfile`
- `spec.addons.publicEdge`
- `spec.bootstrap.kubeconfig`
- `spec.bootstrap.context`
- `spec.vault.authMount`

나머지 네트워크/노드 항목은 host bootstrap과 운영 문서화를 위해 같이 유지해요.
