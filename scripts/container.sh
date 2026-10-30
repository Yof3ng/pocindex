#!/usr/bin/env bash
# Build, run, test, export and import the PoC Index container.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

COMPOSE_FILE=${POCINDEX_COMPOSE_FILE:-compose.yaml}
BUILD_FILE=${POCINDEX_BUILD_FILE:-compose.build.yaml}
IMAGE=${POCINDEX_IMAGE:-pocindex:local}
CONTAINER_NAME=${POCINDEX_CONTAINER_NAME:-pocindex-web}
BIND_ADDRESS=${POCINDEX_BIND:-127.0.0.1}
PORT=${POCINDEX_PORT:-8765}

usage() {
    cat <<'USAGE'
Usage: scripts/container.sh <command> [args]

Commands:
  up                 Build the image if needed, then start the site
  build              Build the static-site image
  rebuild            Rebuild with pull/no-cache disabled, then recreate the site
  start              Start an already built/imported image
  stop               Stop the running site
  restart            Restart the running site
  down               Stop and remove the site container/network
  status             Show container status and local URL
  logs [args...]     Follow container logs
  smoke              Check the homepage, data and a CVE page over HTTP
  test               Build and run Python and Node test stages
  export [file]      Save the image as a compressed migration archive
  import <file>      Load an image exported by this script
  shell              Open a shell inside the image for debugging

Environment:
  POCINDEX_PORT            Host port (default: 8765)
  POCINDEX_BIND            Bind address (default: 127.0.0.1)
  POCINDEX_IMAGE           Image tag (default: pocindex:local)
  POCINDEX_CONTAINER_NAME  Container name (default: pocindex-web)
USAGE
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is required"
    docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"
}

setup_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "Docker Compose v2 is required (or install docker-compose)"
    fi
}

compose_runtime() {
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"
}

compose_build() {
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" -f "$BUILD_FILE" "$@"
}

image_exists() {
    docker image inspect "$IMAGE" >/dev/null 2>&1
}

check_host() {
    case "$BIND_ADDRESS" in
        0.0.0.0|::|"[::]") printf '127.0.0.1' ;;
        *) printf '%s' "$BIND_ADDRESS" ;;
    esac
}

site_url() {
    printf 'http://%s:%s/' "$(check_host)" "$PORT"
}

wait_ready() {
    command -v curl >/dev/null 2>&1 || return 0
    local url
    url=$(site_url)
    for _ in $(seq 1 30); do
        if curl -fsS --max-time 2 "${url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    die "site did not become ready at ${url}; run: $0 logs"
}

build_site() {
    echo "Building ${IMAGE} (the first build needs network access and can take several minutes)..."
    compose_build build
}

start_site() {
    image_exists || die "image ${IMAGE} is missing; run: $0 build, or import an image first"
    compose_runtime up -d
    wait_ready
    compose_runtime ps
    printf '\nPoC Index: %s\n' "$(site_url)"
}

stop_site() {
    compose_runtime stop
}

restart_site() {
    compose_runtime restart
    wait_ready
    printf 'PoC Index: %s\n' "$(site_url)"
}

smoke_test() {
    command -v curl >/dev/null 2>&1 || die "curl is required for smoke tests"
    local url
    url=$(site_url)
    # grep -q closes the pipe as soon as it matches. Run this in a subshell
    # without pipefail so curl's expected broken-pipe exit is not a failure.
    if ! (set +o pipefail; curl -fsS --max-time 10 "${url}" 2>/dev/null | grep -q "PoC Index"); then
        die "homepage check failed"
    fi
    if ! (set +o pipefail; curl -fsS --max-time 30 "${url}CVE_list.json" 2>/dev/null | grep -q '"cve"'); then
        die "CVE_list.json check failed"
    fi
    if ! (set +o pipefail; curl -fsS --max-time 10 "${url}CVE-2021-44228" 2>/dev/null | grep -q "CVE-2021-44228"); then
        die "extensionless CVE page check failed"
    fi
    printf 'Smoke test passed: %s\n' "$url"
}

run_tests() {
    echo "Building Node test stage..."
    docker build --file Dockerfile --target test-node --tag "${IMAGE}-test-node" .
    echo "Building Python test stage..."
    docker build --file Dockerfile --target test-python --tag "${IMAGE}-test-python" .
}

export_image() {
    image_exists || die "image ${IMAGE} is missing; run: $0 build"
    local output=${1:-"pocindex-image-$(date +%Y%m%d-%H%M%S).tar.gz"}
    mkdir -p "$(dirname -- "$output")"
    echo "Saving ${IMAGE} to ${output}..."
    docker save "$IMAGE" | gzip -1 > "$output"
    echo "Wrote ${output}"
}

import_image() {
    [ $# -eq 1 ] || die "usage: $0 import <image.tar.gz>"
    local input=$1
    [ -f "$input" ] || die "archive not found: ${input}"
    echo "Loading ${input}..."
    gzip -dc "$input" | docker load
    image_exists || die "archive did not load ${IMAGE}; set POCINDEX_IMAGE to the archived tag"
    echo "Loaded ${IMAGE}; start with: $0 up"
}

require_docker

command=${1:-help}
if [ $# -gt 0 ]; then
    shift
fi

setup_compose

case "$command" in
    up)
        image_exists || build_site
        start_site
        ;;
    build)
        build_site
        ;;
    rebuild)
        compose_build build
        compose_runtime up -d --force-recreate
        wait_ready
        compose_runtime ps
        printf '\nPoC Index: %s\n' "$(site_url)"
        ;;
    start)
        start_site
        ;;
    stop)
        stop_site
        ;;
    restart)
        restart_site
        ;;
    down)
        compose_runtime down
        ;;
    status)
        compose_runtime ps
        printf 'URL: %s\n' "$(site_url)"
        docker inspect "$CONTAINER_NAME" --format 'health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null || true
        ;;
    logs)
        compose_runtime logs -f --tail=200 "$@"
        ;;
    smoke)
        smoke_test
        ;;
    test)
        run_tests
        ;;
    export)
        export_image "$@"
        ;;
    import)
        import_image "$@"
        ;;
    shell)
        image_exists || die "image ${IMAGE} is missing"
        docker run --rm -it --network none --read-only \
            --tmpfs /tmp:rw,noexec,nosuid,size=16m \
            --cap-drop ALL --security-opt no-new-privileges \
            --entrypoint /bin/sh "$IMAGE"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
