# Vault TLS Inputs

Vault server certificate와 private key는 Git 밖에 두고 host/bootstrap 레이어에서 주입해요.

- certificate: `/secure/bootstrap/pki/vault.mgmt.litomi.internal.crt`
- private key: `/secure/bootstrap/pki/vault.mgmt.litomi.internal.key`
- full chain / CA bundle source: 내부 PKI 기준 경로 사용

공개 CA만 Git에 두고, 그 복사본은 `bootstrap/pki/vault-ca.pem`에 유지해요.
