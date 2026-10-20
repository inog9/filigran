# filigran

Deployment of the Filigran tools and of what they need, one folder per piece. `opencti-docker/`
is the official deployment kept as it is upstream, plus the few changes made here, written down in
one place. `opensearch-ec2-docker/` is made here, for the server that holds the search engine.

| Folder | What | Start here |
|---|---|---|
| [`opencti-docker/`](opencti-docker/) | [OpenCTI](https://github.com/OpenCTI-Platform/opencti) with Docker Compose | [`CHANGES.md`](opencti-docker/CHANGES.md) |
| [`opensearch-ec2-docker/`](opensearch-ec2-docker/) | OpenSearch for OpenCTI, on its own server (the search backend of the folder above) | [`README.md`](opensearch-ec2-docker/README.md) |

Secrets (`.env`, certificates, passwords) are never committed: each folder's README says what
to create on the server.
