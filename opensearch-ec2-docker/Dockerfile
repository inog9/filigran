# What OpenCTI's own test setup builds (opencti-platform/opencti-dev/opensearch/Dockerfile):
# OpenSearch plus ingest-attachment, which OpenCTI's "attachment" pipeline needs.
# The version is set in docker-compose.yml, the only place it is written.
ARG OPENSEARCH_VERSION
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch ingest-attachment
