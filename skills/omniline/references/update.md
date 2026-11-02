# Upgrade an existing install

Use this when detection returned `state=installed` and the user wants a newer
version. Docs: https://omniline.app/docs/install/docker.md, and the operator guide
section "Upgrade (Compose)".

The installer is the upgrade tool. Re-running it against the existing directory
detects `.env`, keeps secrets and volumes, refreshes the compose assets, patches
`OMNI_LINE_VERSION` and the digest-pinned `OMNI_LINE_SERVER_IMAGE` /
`OMNI_LINE_CLIENT_IMAGE`, pulls, and restarts. Operator-owned keys (SMTP, URLs,
`BOOTSTRAP_CREATE_ORG`, storage settings) are left as they are.

## 1. Confirm the target

State the current version (from `.env`) and the latest stable (from detection).
If the user named a version, use it. Skip the upgrade if current equals target and
say so.

Do not upgrade a stack whose `/readyz` is failing. Fix it first (troubleshooting).

## 2. Read the release notes

Fetch the notes for every release between current and target and look for
migrations, breaking changes, or new required env keys:

```bash
curl -fsS "https://api.github.com/repos/omni-line/releases/releases/tags/v<target>" \
  | sed -n 's/.*"body":"\(.*\)","draft.*/\1/p' | sed 's/\\r\\n/\n/g' | sed 's/\\n/\n/g'
```

Summarize anything that affects this host before proceeding. If a note requires a
manual step, do it or ask, do not skip it.

New outbound hosts appear under "Breaking / operators" (1.0.6 added `packagist.org`
for Composer registries). On a host with an egress firewall, check them with the
loop in the install reference's preflight before upgrading. The upgrade itself
succeeds without them, but the scans that need them start failing.

## 3. Back up

Backups are cheap and rollback without them is not possible. Always do this before
pulling new images.

```bash
DIR=/opt/omni-line   # the detected install dir
cd "$DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "backups/$STAMP"

# Postgres (bundled service; skip when the external-db overlay is in use and
# back up that database with your own tooling instead)
docker compose --env-file .env exec -T postgres \
  pg_dump -U "${POSTGRES_USER:-omniline}" "${POSTGRES_DB:-omniline}" \
  | gzip > "backups/$STAMP/postgres.sql.gz"

# Artifact storage volume (skip when STORAGE_DRIVER=s3; rely on bucket versioning)
STORAGE_VOL="$(docker volume ls -q | grep -E '_storage_data$' | head -n1)"
docker run --rm -v "$STORAGE_VOL":/data -v "$PWD/backups/$STAMP":/backup alpine \
  tar czf /backup/storage_data.tgz -C /data .

# Config
cp .env "backups/$STAMP/.env"
chmod 600 "backups/$STAMP/.env"
```

Report the backup path and sizes. If the storage volume is large, warn that the
tarball will take a while and offer a volume snapshot instead.

## 4. Upgrade

Same install dir, non-interactive, explicit version. Never add `--reset-env`.

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh \
  | bash -s -- --dir "$DIR" --version <target> -y
```

Do not pass `--url` or `--port` unless the user wants to change them; the installer
reads the existing values from `.env` in upgrade mode.

Migrations run on server boot when `RUN_MIGRATIONS_ON_START=true` (the default).
Watch them:

```bash
cd "$DIR" && docker compose --env-file .env logs -f server 2>&1 | sed -n '1,80p'
```

Manual alternative when the script cannot be used:

```bash
cd "$DIR"
# edit .env: OMNI_LINE_VERSION=<target>, and OMNI_LINE_SERVER_IMAGE / OMNI_LINE_CLIENT_IMAGE
docker compose --env-file .env pull && docker compose --env-file .env up -d
```

## 5. Verify

```bash
PORT="$(grep -E '^OMNI_LINE_PORT=' "$DIR/.env" | cut -d= -f2-)"; PORT="${PORT:-8080}"
curl -fsS "http://127.0.0.1:${PORT}/readyz"
grep -E '^OMNI_LINE_VERSION=' "$DIR/.env"
cd "$DIR" && docker compose --env-file .env ps
```

Then log in with the bootstrap admin (credentials in `.env`) and confirm the license
is still active:

```bash
curl -fsS "http://127.0.0.1:${PORT}/api/license" -H "Authorization: Bearer $ACCESS_TOKEN"
```

If an **external reverse proxy shares a Docker network** with Omni Line, recreate or
reload it after the upgrade so its upstream DNS picks up the new client container
IP. Otherwise the proxy keeps sending traffic to a dead IP and users see 502s. See
overlays reference, `external-network`.

## 6. Rollback

Only if the new version fails and the release notes did not warn about an
irreversible migration.

```bash
# 1. Pin the previous version again (keeps .env, volumes)
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh \
  | bash -s -- --dir "$DIR" --version <previous> -y

# 2. If a migration changed the schema, restore the database from the backup
cd "$DIR"
docker compose --env-file .env stop server
gunzip -c "backups/$STAMP/postgres.sql.gz" | docker compose --env-file .env exec -T postgres \
  psql -U "${POSTGRES_USER:-omniline}" "${POSTGRES_DB:-omniline}"
docker compose --env-file .env up -d
```

Report that a rollback happened, why, and which backup was restored.
