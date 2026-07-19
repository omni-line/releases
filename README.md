# Omni Line releases

Public install assets for self-hosting Omni Line. Application source stays in the private monorepo; runtime images are on GHCR.

## Install (one-liner)

Prefer the installer from `main` (includes volume wipe on fresh secrets). Image tags still come from GHCR / `--version`:

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh \
  | bash -s -- --version 0.1.3
```

Pinned release asset (may lag fixes until the next Publish images run):

```bash
curl -fsSL https://github.com/omni-line/releases/releases/latest/download/install.sh | bash
```

Pin a version:

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh \
  | bash -s -- --version 0.1.3 -y
```

## What this repository contains

| Path | Purpose |
|---|---|
| `install.sh` | Colored installer (preflight, prompts, Compose up) |
| `compose/docker-compose.yml` | Official stack: Postgres + server + client |
| `compose/compose.env.example` | Env template (`OMNI_LINE_VERSION`, secrets, URLs) |

Images pulled by Compose:

- `ghcr.io/omni-line/omni-line-server`
- `ghcr.io/omni-line/omni-line-client`

Those packages should be **public** on GHCR so customers do not need `docker login`.

## Manual Compose

```bash
mkdir omni-line && cd omni-line
curl -fsSL -O https://github.com/omni-line/releases/releases/latest/download/docker-compose.yml
curl -fsSL -o .env https://github.com/omni-line/releases/releases/latest/download/compose.env.example
# Edit .env — set OMNI_LINE_VERSION, JWT_SECRET, POSTGRES_PASSWORD
docker compose --env-file .env up -d
```

Open `http://localhost:8080`, sign in with the bootstrap admin, and activate your `OMNI-…` license key.

## After install

- Health: `curl -fsS http://127.0.0.1:8080/readyz`
- Logs: `docker compose logs -f`
- Upgrade: re-run the installer with `--version X.Y.Z`, or bump `OMNI_LINE_VERSION` and `docker compose pull && up -d`

## Maintainer note

Assets are published from the private monorepo via the **Publish images** workflow into **this** repository’s GitHub Releases. Do not commit application source here.
