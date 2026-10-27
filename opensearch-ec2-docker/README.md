# opensearch-ec2-docker

OpenSearch for an [OpenCTI](../opencti-docker/) platform that runs on **another server**.
It is the image OpenCTI itself tests with (OpenSearch plus the `ingest-attachment` plugin), with
login and TLS switched on because the platform connects over the network.

```
OpenCTI server ──HTTPS :9200, user "opencti", CA certificate──▶ this server: OpenSearch
```

## What you need

- Docker with the Compose plugin, and about 5 GB of free RAM (the heap is 4 GB, `OPENSEARCH_HEAP`).
- `vm.max_map_count` of at least 262144 (check with `sysctl vm.max_map_count`; the Ubuntu 26.04 image on AWS used here has 1048576).
- TCP 9200 open **only to the OpenCTI server**, in the cloud firewall (on AWS: the Security Group).
  The host's own firewall is not used here, so that rule is the only filter.

## Install

```bash
./setup.sh
```

It creates a private certificate authority and the server certificate, generates two random
passwords (`.secrets`), builds the image, starts OpenSearch and shows its status once it
answers. It can be run again at any time: it keeps the certificates and passwords it already made.

## Connect OpenCTI

Take two things from this server and put them on the OpenCTI server, never in git:

| From here | On the OpenCTI server |
|---|---|
| `certs/root-ca.pem` | `opencti-docker/certs/opensearch-ca.pem` |
| `OPENCTI_PASSWORD` in `.secrets` | `OPENSEARCH_OPENCTI_PASSWORD` in `opencti-docker/.env` |

and set `OPENSEARCH_URL=https://<this server>:9200` there. The rest is described in
[`../opencti-docker/CHANGES.md`](../opencti-docker/CHANGES.md), section 7.

A **new** OpenCTI needs nothing else: on its first start it creates its indices, templates and
pipelines in the empty OpenSearch by itself.

## Files

| File | What |
|---|---|
| `Dockerfile` | the official OpenSearch image plus the `ingest-attachment` plugin (OpenCTI uses it to read the text of uploaded files) |
| `docker-compose.yml` | the service, and the only place the OpenSearch version is written; the project name is fixed to `opencti-search` so the data volume `opencti-search_osdata` never depends on the folder name |
| `config/opensearch.yml` | TLS, and the search queue size OpenCTI asks for |
| `security/` | the two users (`admin` for emergencies, `opencti` for the platform) and the role of `opencti`: the permissions listed in OpenCTI's documentation, plus `indices:data/write/reindex`, which the list omits and without which deleting anything in OpenCTI fails |
| `make-certs.sh` | creates the certificates (own authority, valid for the server's addresses) |
| `setup.sh` | installs or updates everything above |
| `apply-security.sh` | pushes `security/*.yml` to the running OpenSearch |
| `migration/` | only for moving the data of an existing OpenCTI, see below |

Never in git: `certs/`, `.secrets`, `security/internal_users.yml` (generated from the template).

## Everyday

```bash
docker compose ps
docker compose logs -f --tail 50
set -a; . ./.secrets; set +a
curl -s --cacert certs/root-ca.pem -u "admin:$ADMIN_PASSWORD" "https://localhost:9200/_cluster/health?pretty"
```

- **The server's address changed** (Elastic IP, new name): `./make-certs.sh IP:<new address>`
  (or `DNS:<name>`), then `docker compose restart`, and update `OPENSEARCH_URL` on the OpenCTI
  server. Without this the platform rejects the certificate.
- **Changed a file in `security/`**: `./apply-security.sh`.
- **Upgrade OpenSearch**: change the version in `docker-compose.yml`, then `./setup.sh`. Use the
  version OpenCTI's own test setup uses for the OpenCTI release you run.
- **Go back to an older version** (e.g. 3.x to 2.19): OpenSearch cannot open data written by a
  newer version, and a snapshot cannot be restored into an older one. Copy the volume as a
  backup, start the old data as a second project on port 9201, create the new version on an
  empty volume, then `migration/init-schema.sh` and `migration/copy-indices.py --source-auth`
  from 9201 to 9200 (3.6 million documents: about 10 minutes).

There are no backups here. To back up, stop the service (`docker compose stop`) and copy the
volume `opencti-search_osdata`, or take a snapshot of the server's disk.

## Moving an existing OpenCTI

Needed only when the platform already holds data in Elasticsearch (a snapshot of Elasticsearch
cannot be restored into OpenSearch, so the documents are copied):

1. `migration/init-schema.sh`: lets OpenCTI create its empty indices here.
2. Stop everything that writes to OpenCTI (platform, worker, connectors).
3. On the OpenCTI server: `migration/copy-indices.py` (usage in its header) copies the documents
   and compares the counts.
4. Point the platform at OpenSearch and start it: its log must say `Existing platform detected`.

For 3.5 million documents this took about 22 minutes, with 270 ms between the two servers.
