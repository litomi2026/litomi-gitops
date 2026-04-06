# PKI Notes

이 디렉터리는 GitOps에 포함해도 되는 공개 인증서 자료만 둡니다.

- `vault-ca.pem`은 Vault ingress를 검증할 공개 CA 자리입니다.
- 현재 들어 있는 내용은 placeholder라서 실제 bootstrap 전에 운영용 CA PEM으로 교체해야 합니다.
- Vault server private key와 `vault-tls` Secret 원본은 절대 Git에 커밋하지 않습니다.
- 실제 TLS key/cert는 Git 밖 `/secure`에 두고, bootstrap/secret template에서 지정한 경로로 주입합니다.
