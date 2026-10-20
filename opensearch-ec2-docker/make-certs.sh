#!/usr/bin/env bash
# Own CA + node and admin certificates for OpenSearch (HTTP and transport TLS).
# Usage: ./make-certs.sh [extra SAN entries, e.g. IP:1.2.3.4 DNS:search.example.com]
# Re-run with the new address after attaching an Elastic IP or a DNS name.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs && chmod 700 certs && cd certs
PUBLIC_IP=$(TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60") \
  && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || true)
PRIVATE_IP=$(hostname -I | awk '{print $1}')
SAN="DNS:localhost,DNS:opensearch,IP:127.0.0.1,IP:${PRIVATE_IP}${PUBLIC_IP:+,IP:$PUBLIC_IP}"
for extra in "$@"; do SAN="$SAN,$extra"; done

if [[ ! -f root-ca.pem ]]; then
  openssl genrsa -out root-ca-key.pem 4096 2>/dev/null
  openssl req -x509 -new -key root-ca-key.pem -sha256 -days 3650 -subj "/O=OpenCTI search/CN=OpenCTI search root CA" -out root-ca.pem
fi
issue() {  # name subject [san]
  openssl genrsa -out "$1-key-rsa.pem" 2048 2>/dev/null
  openssl pkcs8 -inform PEM -outform PEM -in "$1-key-rsa.pem" -topk8 -nocrypt -v1 PBE-SHA1-3DES -out "$1-key.pem"
  rm -f "$1-key-rsa.pem"
  openssl req -new -key "$1-key.pem" -subj "$2" -out "$1.csr"
  if [[ -n "${3:-}" ]]; then printf 'subjectAltName=%s\n' "$3" > "$1.ext"; else : > "$1.ext"; fi
  openssl x509 -req -in "$1.csr" -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -days 825 -extfile "$1.ext" -out "$1.pem" 2>/dev/null
  rm -f "$1.csr" "$1.ext"
}
issue node  "/O=OpenCTI search/CN=opencti-search" "$SAN"
issue admin "/O=OpenCTI search/CN=admin"
chmod 600 ./*-key.pem && chmod 644 ./*.pem
echo "certificates in $(pwd) - node SAN: $SAN"
