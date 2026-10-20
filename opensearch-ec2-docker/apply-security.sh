#!/usr/bin/env bash
# Re-applies security/{internal_users,roles,roles_mapping}.yml to the running cluster.
# The mounted copies are only read on the very first start, and a single-file bind mount
# keeps showing the old file once it is replaced on the host: so copy the current files
# into the container and push each one with securityadmin.
set -euo pipefail
cd "$(dirname "$0")"
for pair in internal_users:internalusers roles:roles roles_mapping:rolesmapping; do
  file=${pair%%:*}; type=${pair##*:}
  docker compose cp "security/$file.yml" "opensearch:/tmp/$file.yml"
  docker compose exec -T opensearch plugins/opensearch-security/tools/securityadmin.sh \
    -f "/tmp/$file.yml" -t "$type" -icl -nhnv -h localhost \
    -cacert config/certs/root-ca.pem -cert config/certs/admin.pem -key config/certs/admin-key.pem \
    | grep -E "SUCC|FAIL|ERR" | head -2
  docker compose exec -T -u 0 opensearch rm -f "/tmp/$file.yml"
done
