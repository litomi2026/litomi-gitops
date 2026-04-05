# PKI Notes

이 디렉터리는 GitOps에 포함해도 되는 **공개 인증서 자료**만 두는 자리예요.

- Vault server private key와 `vault-tls` Secret 원본은 절대 커밋하지 않아요.
- Vault 공개 CA PEM을 GitOps로 관리하려면 실제 PEM 파일을 준비한 뒤, 관련 `vault-ca` ConfigMap 리소스에 넣어 주세요.
- 현재 레포에는 실제 Vault CA PEM이 없어서, 해당 값 자체를 추측해서 커밋하지는 않았어요.
