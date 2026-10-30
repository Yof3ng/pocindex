# Container deployment

The repository is a static site generator. The container performs a two-stage
deployment:

1. `build` generates the JSON index, homepage, CVE pages and sitemap.
2. `runtime` contains only `docs/` and a small Python static server.

The runtime image does not need the source repository, Python packages, Node, a
database, or network access. It is intended for local browsing or a private
single-host deployment.

## Requirements

- Docker Engine or Docker Desktop
- Docker Compose v2 (`docker compose`)
- Network access during the first image build for EPSS and the published
  page-state manifest

The build context is large because `cves/` and `index/` contain the source data.
The first build can take several minutes. Later builds reuse Docker layers.

## Quick start

```bash
cd /Users/youchai/Documents/Security/Toolkit/PocIndex
chmod +x scripts/container.sh
./scripts/container.sh up
```

Open <http://127.0.0.1:8765/>.

`up` builds the image if it is missing, starts the service, waits for it to
become ready, and prints the URL.

## Common commands

| Command | Purpose |
| --- | --- |
| `./scripts/container.sh up` | Build if needed and start |
| `./scripts/container.sh rebuild` | Rebuild and recreate after source changes |
| `./scripts/container.sh status` | Show container and health status |
| `./scripts/container.sh logs` | Follow logs |
| `./scripts/container.sh smoke` | Check homepage, data and an extensionless CVE page |
| `./scripts/container.sh stop` | Stop the site |
| `./scripts/container.sh restart` | Restart the site |
| `./scripts/container.sh down` | Remove the container and Compose network |
| `./scripts/container.sh test` | Build and run Python and Node test stages |
| `./scripts/container.sh shell` | Open a read-only debug shell in the image |

The site listens only on `127.0.0.1` by default. To use another local port:

```bash
POCINDEX_PORT=9000 ./scripts/container.sh up
```

Do not set `POCINDEX_BIND=0.0.0.0` unless you intentionally want to expose the
site to your LAN.

## Migrate to another machine

### Image export and import

On the source machine:

```bash
./scripts/container.sh export ./pocindex-image.tar.gz
```

Copy the archive to the target machine together with these two files, preserving
the `scripts/` directory:

```text
pocindex-image.tar.gz
compose.yaml
scripts/container.sh
```

Then run:

```bash
./scripts/container.sh import ./pocindex-image.tar.gz
./scripts/container.sh up
```

The target machine does not need the Git repository, Python, Node, or network
access after the image has been loaded.

### Image-only export

```bash
./scripts/container.sh export ./pocindex-image.tar.gz
```

On the target machine, place `compose.yaml`, `scripts/container.sh` and the
archive in the same layout, then:

```bash
./scripts/container.sh import ./pocindex-image.tar.gz
./scripts/container.sh up
```

## Build manually

```bash
docker compose -f compose.yaml -f compose.build.yaml build
docker compose up -d
```

The runtime-only Compose file intentionally has no `build:` section. That is
what lets an imported image start on a machine without the source tree.

## Runtime security

- Runs as UID/GID `10001`, not root.
- Root filesystem is read-only; only a small `/tmp` tmpfs is writable.
- All Linux capabilities are dropped.
- `no-new-privileges` is enabled.
- PID and memory limits are set.
- Only the static site is copied into the runtime image.
- The HTTP server disables directory listings and dotfile access.
- The host port binds to loopback by default.

The site links to third-party PoC repositories. Do not download or execute PoC
code on a sensitive workstation. The page also requests Google Fonts; this does
not affect querying, and the page falls back to system fonts if the request is
blocked.
