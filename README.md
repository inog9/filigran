# filigran

Deployment of the Filigran tools, one folder per tool. Each folder is the official deployment of
that tool, kept as it is upstream, plus the few changes made here, written down in one place.

| Folder | What | Start here |
|---|---|---|
| [`opencti-docker/`](opencti-docker/) | [OpenCTI](https://github.com/OpenCTI-Platform/opencti) with Docker Compose | [`CHANGES.md`](opencti-docker/CHANGES.md) |

Secrets (`.env`, certificates, passwords) are never committed: each folder ships a `*.sample`
file that lists the variables to fill in.
