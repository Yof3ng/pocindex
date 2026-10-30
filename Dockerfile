# syntax=docker/dockerfile:1.7

ARG PYTHON_IMAGE=python:3.13-slim
ARG NODE_IMAGE=node:20-slim

FROM ${PYTHON_IMAGE} AS test-python
ARG DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN python3 -m unittest discover -s tests

FROM ${NODE_IMAGE} AS test-node
WORKDIR /src
COPY docs/logic.js docs/logic.js
COPY tests/test_search.js tests/test_search.js
RUN node --test tests/test_search.js

FROM ${PYTHON_IMAGE} AS build
ARG BUILD_RETRIES=3
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app
COPY scripts ./scripts
COPY templates ./templates
COPY docs ./docs
COPY cves ./cves
COPY index ./index
# EPSS and the published page-state manifest are fetched here. The runtime image
# only contains the generated static files and does not fetch data itself.
# Retry the two network-dependent stages because upstream TLS/HTTP can be
# transiently unavailable; a real data failure still stops the image build.
RUN set -eu; \
    retry() { \
        attempt=1; \
        while ! "$@"; do \
            if [ "$attempt" -ge "$BUILD_RETRIES" ]; then \
                echo "build step failed after $attempt attempts: $*" >&2; \
                return 1; \
            fi; \
            delay=$((attempt * 5)); \
            echo "build step failed; retrying in ${delay}s: $*" >&2; \
            sleep "$delay"; \
            attempt=$((attempt + 1)); \
        done; \
    }; \
    retry python3 scripts/build_site.py; \
    retry python3 scripts/build_pages.py; \
    python3 scripts/build_seo.py

FROM ${PYTHON_IMAGE} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp
RUN groupadd --gid 10001 pocindex \
    && useradd --uid 10001 --gid 10001 --no-create-home \
       --home-dir /nonexistent --shell /usr/sbin/nologin pocindex
WORKDIR /app
COPY --from=build --chown=10001:10001 /app/docs /app/site
COPY --chown=10001:10001 scripts/serve_local.py /app/serve_local.py
COPY --chown=10001:10001 LICENSE /app/LICENSE
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/', timeout=3).read(1)"]
ENTRYPOINT ["python3", "/app/serve_local.py"]
CMD ["--host", "0.0.0.0", "--port", "8000", "--directory", "/app/site"]
