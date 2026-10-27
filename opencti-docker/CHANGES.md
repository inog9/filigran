# What differs from upstream

`docker-compose.yml`, `rabbitmq.conf`, `.env.sample` and `README.md` in this folder are the
unmodified files of [OpenCTI-Platform/docker](https://github.com/OpenCTI-Platform/docker)
(commit `10b23d4`, 2026-09-29). Nothing is edited in them. Every local change is in
`docker-compose.override.yml`, which Docker Compose merges automatically, and in the variables of
`.env.local.sample`.

## Run it

```bash
cd opencti-docker
cat .env.sample .env.local.sample > .env     # then fill in every value; chmod 600 .env
mkdir certs && cp <OpenSearch CA certificate> certs/opensearch-ca.pem
docker-compose up -d
```

`.env` is never committed. A variable defined twice takes the last value, which is why the
local file is appended: it replaces the sample's `COMPOSE_PROJECT_NAME=xtm`.

## Changes

### 1. Versions

| Upstream | Here | Why |
|---|---|---|
| `opencti/*:latest` | `opencti/*:${OPENCTI_VERSION}` for the platform, the worker and every connector | They must always run the same release, and an upgrade should be one edit |
| `pgsty/silo:latest` | `pgsty/silo:RELEASE.2026-09-16T00-00-00Z` | A fixed S3 storage release |

### 2. Platform (`opencti`)

| Setting | Upstream | Here | Why |
|---|---|---|---|
| `APP__BASE_URL` | `scheme://host:port` | `scheme://host` | OpenCTI is published by a reverse proxy on 443, without the port |
| `NODE_OPTIONS` | `--max-old-space-size=8096` | `3072` | Sized for a 7-8 GB host |
| `XTM__XTM_ONE_URL`, `XTM__XTM_ONE_TOKEN` | XTM One | empty | XTM One is not used (section 4) |
| `REDIS__TRIMMING` | 2,000,000 (OpenCTI default) | `500000` | The live stream in Redis had grown past 1.3 GB on this host |
| `ELASTICSEARCH__*` | the bundled Elasticsearch | OpenSearch on another host (section 7) | Frees memory and disk on this host |
| published port | `8080` on all interfaces | `127.0.0.1:${OPENCTI_PORT}` | Only the reverse proxy reaches OpenCTI |

### 3. Worker and S3 storage

| Service | Upstream | Here | Why |
|---|---|---|---|
| `worker` | 3 replicas | 3 | Same as upstream (was 1 for memory; the import backlog needed more) |
| `minio` (Silo) | port 9000 on all interfaces | `127.0.0.1:9000` | Not reachable from outside |

### 4. Switched off: Elasticsearch and the XTM One stack

`elasticsearch` is replaced by OpenSearch on another host (section 7).

`xtm-one`, `xtm-one-worker`, `xtm-composer`, `pgsql-xtm-one` and `rsa-key-generator` are in the
profile `disabled`, so they never start. To use XTM One, remove their `profiles` lines and the two
`XTM__*` lines of the platform.

### 5. Stopped on purpose

None at the moment: every connector in the override starts. To keep one off without deleting
it, give it `profiles: [optional]`; start it later with
`docker-compose --profile optional up -d <service>`.

### 6. Added connectors

Not in upstream. They all use `OPENCTI_ADMIN_TOKEN` and wait for the platform to be healthy.

| Service | Source | Starts |
|---|---|---|
| `connector-cisa-known-exploited-vulnerabilities` | CISA catalog of exploited vulnerabilities | yes |
| `connector-dnstwist` | lookalike domains of a domain (run on demand) | yes |
| `connector-dshield` | attacking networks from SANS ISC DShield | yes |
| `connector-hygiene` | labels observables found in MISP warning lists (fewer false positives) | yes |
| `connector-ipsum` | malicious IP addresses (IPsum, level 5) | yes |
| `connector-red-flag-domains` | newly registered suspicious domains (red.flag.domains) | yes |
| `connector-shodan-internetdb` | enrichment of IPv4 addresses (Shodan InternetDB) | yes |
| `connector-threatfox` | indicators from abuse.ch ThreatFox | yes |
| `connector-urlhaus` | malicious URLs from abuse.ch URLhaus | yes |
| `connector-first-epss-bulk` | exploit prediction scores (FIRST EPSS) | yes |
| `connector-ransomfeed` | ransomware victims (RansomFeed) | yes |
| `connector-ransomwarelive` | ransomware victims (ransomware.live, free API without a key) | yes |
| `connector-abuse-ssl` | botnet C2 IP addresses from abuse.ch SSLBL | yes |
| `connector-disarm-framework` | DISARM disinformation framework | yes |
| `connector-mitre-atlas` | MITRE ATLAS (attacks on AI/ML systems) | yes |
| `connector-tweetfeed` | IOCs shared on X/Twitter (TweetFeed) | yes |
| `connector-malpedia` | malware families (Malpedia, public data without a key) | yes |

Each one needs its own connector id in `.env` (`CONNECTOR_*_ID`, a new UUIDv4 that never changes
afterwards).

### 7. Search backend: OpenSearch on another host

The platform talks to an OpenSearch (not the bundled Elasticsearch) over HTTPS, as the user
`opencti`, and trusts the CA in `certs/opensearch-ca.pem`:

| Variable | Value |
|---|---|
| `OPENSEARCH_URL` | `https://<opensearch host>:9200` |
| `OPENSEARCH_OPENCTI_PASSWORD` | password of the `opencti` user |

Upstream also ships `docker-compose.opensearch.yml`, a replacement for `docker-compose.yml` that
runs OpenSearch inside the same stack with its security plugin off, from the stock image (without
the `ingest-attachment` plugin that OpenCTI's own test setup installs). It is not used here
because OpenSearch runs on another host, with security on, TLS and that plugin: the base stays
`docker-compose.yml` and only the five `ELASTICSEARCH__*` lines point to the other host.

Setting up that OpenSearch server: [`../opensearch-ec2-docker/`](../opensearch-ec2-docker/).

The bundled `elasticsearch` service is in the profile `disabled` (it used about 2 GB of memory
while idle), and the platform's `depends_on` is overridden without it: the upstream platform
waits for a healthy `elasticsearch`, and disabling the service alone makes Compose refuse the
project. Its volume `esdata` is kept, with the data as it was on 2026-10-20. To go back to it,
delete those two blocks, the five `ELASTICSEARCH__*` lines and the `volumes` entry of the platform.

## Upgrade OpenCTI

1. Read the release notes. Stop the stack and back up the volumes (`docker-compose down` keeps them).
2. Change `OPENCTI_VERSION` in `.env`.
3. `docker-compose pull && docker-compose up -d`; the platform migrates its data when it starts.
   Going back to the old images does not undo a migration: restore the backup instead.

## Take a newer upstream

1. In a checkout of `OpenCTI-Platform/docker`, copy `docker-compose.yml`, `rabbitmq.conf`,
   `.env.sample` and `README.md` over the ones here. `git diff` shows what upstream changed.
2. A service that is new upstream starts by default: decide whether it should (section 4 and 5).
3. `docker-compose config --quiet` must still pass. Update the commit number at the top of this file.
