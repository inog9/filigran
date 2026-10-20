#!/usr/bin/env bash
# Installs/updates OpenSearch for OpenCTI on this host. Idempotent: keeps existing
# certificates and passwords (.secrets, chmod 600).
set -euo pipefail
cd "$(dirname "$0")"
umask 077
[[ -f certs/node.pem ]] || ./make-certs.sh
docker compose build -q
IMAGE=$(docker compose config --images | head -1)

if [[ ! -f .secrets ]]; then
  printf 'ADMIN_PASSWORD=%s\nOPENCTI_PASSWORD=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" > .secrets
fi
set -a; . ./.secrets; set +a
hash() { docker run --rm -e PW="$1" --entrypoint /bin/bash "$IMAGE" \
  -c 'plugins/opensearch-security/tools/hash.sh -env PW 2>/dev/null | tail -1'; }
ADMIN_HASH=$(hash "$ADMIN_PASSWORD"); OPENCTI_HASH=$(hash "$OPENCTI_PASSWORD")
[[ "$ADMIN_HASH" == \$2* && "$OPENCTI_HASH" == \$2* ]] || { echo "password hashing failed" >&2; exit 1; }
sed -e "s|@ADMIN_HASH@|$ADMIN_HASH|" -e "s|@OPENCTI_HASH@|$OPENCTI_HASH|" \
  security/internal_users.yml.template > security/internal_users.yml
chmod 644 security/internal_users.yml   # read by the container user; hashes only

docker compose up -d
# Single node: the ISM plugin's own indices default to 1 replica, which can never be
# assigned here and keeps the cluster yellow. Needs the admin certificate (system indices).
single_node_replicas() {
  local A=(curl -s -o /dev/null --cacert certs/root-ca.pem --cert certs/admin.pem --key certs/admin-key.pem
           -H "Content-Type: application/json")
  "${A[@]}" -X PUT https://localhost:9200/_cluster/settings \
    -d '{"persistent":{"plugins.index_state_management.history.number_of_replicas":0}}'
  "${A[@]}" -X PUT "https://localhost:9200/.opendistro-ism-*/_settings?ignore_unavailable=true" \
    -d '{"index":{"number_of_replicas":0}}'
}
for _ in $(seq 1 60); do
  if curl -s --cacert certs/root-ca.pem -u "admin:$ADMIN_PASSWORD" https://localhost:9200/_cluster/health >/dev/null; then
    single_node_replicas
    curl -s --cacert certs/root-ca.pem -u "admin:$ADMIN_PASSWORD" "https://localhost:9200/_cluster/health?pretty" | grep -E '"(status|number_of_nodes)"'
    exit 0
  fi
  sleep 5
done
echo "OpenSearch did not answer within 5 minutes: docker compose logs" >&2
exit 1
