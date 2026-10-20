#!/usr/bin/env bash
# Creates OpenCTI's index structure in this OpenSearch, empty, by running the platform
# once with ELASTICSEARCH__INTERNAL_INIT_MAPPING_MIGRATION=standard (see migration/init/).
# Only needed before copying an existing platform's data (see ../README.md): a new platform
# fills an empty OpenSearch itself. Refuses to run when opencti* indices already exist.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"      # .../migration
ROOT="$(dirname "$HERE")"                  # the OpenSearch folder: .secrets and certs/ are there
set -a; . "$ROOT/.secrets"; set +a
C=(curl -s --cacert "$ROOT/certs/root-ca.pem" -u "admin:$ADMIN_PASSWORD")
existing=$("${C[@]}" "https://localhost:9200/_cat/indices/opencti*?h=index" | wc -l)
if [[ "$existing" -gt 0 ]]; then
  echo "opencti* indices already exist ($existing): delete them first to re-initialise" >&2; exit 1
fi
# Deleting the indices leaves OpenCTI's ISM policy behind, and the platform refuses to
# create it over an existing one (version_conflict_engine_exception): drop the orphan.
"${C[@]}" -o /dev/null -X DELETE https://localhost:9200/_plugins/_ism/policies/opencti-ism-policy
export INIT_SECRET=$(openssl rand -hex 16) INIT_TOKEN=$(cat /proc/sys/kernel/random/uuid) \
       INIT_ENCRYPTION_KEY=$(openssl rand -base64 32)
cd "$HERE/init"
docker compose up -d --wait redis rabbitmq minio
set +e
docker compose run --rm --no-deps opencti > "$HERE/init-schema.log" 2>&1
rc=$?
set -e
docker compose down -v --remove-orphans >/dev/null 2>&1
if grep -q "Templates and indices created" "$HERE/init-schema.log"; then
  echo "schema created (platform exited with $rc, as designed)"
else
  echo "schema creation FAILED (exit $rc), see $HERE/init-schema.log" >&2
  tail -20 "$HERE/init-schema.log" >&2; exit 1
fi
"${C[@]}" "https://localhost:9200/_cat/indices/opencti*?v&s=index&h=index,docs.count"
"${C[@]}" "https://localhost:9200/_cat/aliases/opencti*?h=alias,index,is_write_index" | sort | head -3
echo "index templates: $("${C[@]}" 'https://localhost:9200/_index_template/opencti*' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["index_templates"]))')"
echo "ISM policy: $("${C[@]}" -o /dev/null -w '%{http_code}' https://localhost:9200/_plugins/_ism/policies/opencti-ism-policy)"
echo "attachment pipeline: $("${C[@]}" -o /dev/null -w '%{http_code}' https://localhost:9200/_ingest/pipeline/attachment)"
