# Compose overlays

The published `docker-compose.yml` is meant to stay untouched. Release assets include
an `overlays/` directory (also shipped as `overlays.tgz`) with small Compose
fragments layered on top with `-f`. Compose merges left to right: base first, then
each overlay. Several can be stacked. Docs: https://omniline.app/docs/install/docker.md

Get the overlays for the installed version:

```bash
cd "$DIR"
VERSION="$(grep -E '^OMNI_LINE_VERSION=' .env | cut -d= -f2-)"
curl -fsSL "https://github.com/omni-line/releases/releases/download/v${VERSION}/overlays.tgz" | tar xz
ls overlays/
```

Once an overlay is in use, every `docker compose` call for that install must
include the same `-f` list. Write the full command into the final report so the user
keeps using it. Consider a `compose.sh` wrapper in the install dir.

## external-db.yml: external Postgres

Disables the bundled `postgres` service (via a Compose profile) and points the
server at your own PostgreSQL 16+.

```bash
# .env
DATABASE_URL=postgresql://omniline:secret@db.example.com:5432/omniline

docker compose -f docker-compose.yml -f overlays/external-db.yml --env-file .env up -d
```

Migrations still run on boot. Moving an existing instance to an external database
means dumping the bundled one and restoring it into the new server first (see the
backup step in the update reference).

## s3.yml: S3-compatible artifact storage

Switches artifacts (tarballs, Docker layers) from the local `storage_data` volume to
object storage and drops the local mount. Any S3 API works: AWS S3, MinIO,
Cloudflare R2. `S3_BUCKET` is required; the others have defaults.

```bash
# .env
STORAGE_DRIVER=s3
S3_BUCKET=omni-line-artifacts
S3_REGION=us-east-1
S3_ACCESS_KEY_ID=...
S3_SECRET_ACCESS_KEY=...
# S3_ENDPOINT=https://minio.example.com   # MinIO, R2, etc.
# S3_FORCE_PATH_STYLE=true                 # usually needed for MinIO
# S3_PREFIX=                               # optional key prefix

docker compose -f docker-compose.yml -f overlays/s3.yml --env-file .env up -d
```

Existing artifacts on the volume are not migrated automatically. Copy them to the
bucket before switching, or accept starting from empty. After the switch, back up
from the bucket, not the old volume.

## tls-edge.compose.yml + Caddyfile.tls: HTTPS at the edge

This one is **not** a merge overlay. It is a standalone Compose project running a
Caddy container that terminates TLS with automatic certificates and proxies to the
Omni Line host port through `host.docker.internal`. Run it from its own directory,
separate from the Omni Line stack.

```bash
mkdir -p /opt/omni-line-edge && cd /opt/omni-line-edge
cp "$DIR/overlays/tls-edge.compose.yml" docker-compose.yml
cp "$DIR/overlays/Caddyfile.tls" Caddyfile.tls
sed -i 's/example.com/registry.example.com/' Caddyfile.tls   # the real hostname
# If OMNI_LINE_PORT is not 8080, change the reverse_proxy target too.
docker compose up -d
```

Then set `SERVER_URL` and `FRONTEND_URL` to `https://registry.example.com` in Omni
Line's `.env` and recreate its stack. Requires DNS pointing at the host and ports 80
and 443 open. Prefer this over exposing port 8080 on any internet-facing host.

## external-network.yml: shared network with your own reverse proxy

Use when Traefik, nginx, or Caddy already run on the host in Docker and should reach
Omni Line over a shared network. The client container joins that network with the
DNS alias `omni-line`; the proxy talks to `http://omni-line:8080` (container port,
not `OMNI_LINE_PORT`).

```bash
# .env
OMNI_LINE_EXTERNAL_NETWORK=proxy    # the existing network name (docker network ls)

docker compose -f docker-compose.yml -f overlays/external-network.yml --env-file .env up -d
```

After every upgrade, reload or recreate the proxy so upstream DNS picks up the new
container IP, or configure the proxy to re-resolve via Docker DNS (`127.0.0.11`).
