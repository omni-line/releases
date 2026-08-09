# Omni Line releases

Public install assets for self-hosting Omni Line. Application source stays in the private monorepo; runtime images are on GHCR.

## Install (one-liner)

Always pull **`install.sh` from `main`** (latest installer). Use `--version` only to pin GHCR images / compose assets:

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh | bash
```

Pin images (non-interactive). On a VPS, pass `--url` so CORS and registry clients use your public origin (not localhost):

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh \
  | bash -s -- --version 0.1.3 -y --url http://YOUR_IP_OR_HOSTNAME:8080
```

Fresh Ubuntu/Debian hosts need Docker Engine 25+ with Compose V2 before the installer will pass preflight: https://docs.docker.com/engine/install/ubuntu/

If the install directory already has an Omni Line `.env`, the installer **detects it and upgrades** (compose + images; secrets and volumes kept). It will not silently reinstall. Pass `--version x.y.z` to pin the target release. Use `--reset-env` only for a destructive wipe.

On a fresh cloud VM, prefer the cloud bootstrap (installs Docker, then `install.sh`):

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/cloud/cloud-init.sh | bash
```

## Cloud (AWS / Azure / DigitalOcean)

Single-VM templates that wrap the Compose installer — see [`cloud/README.md`](cloud/README.md) and https://omniline.app/docs/install/cloud

| Cloud | Start here |
|---|---|
| AWS | [Launch Stack](https://console.aws.amazon.com/cloudformation/home#/stacks/CreateStack?stackName=omni-line&templateURL=https://raw.githubusercontent.com/omni-line/releases/main/cloud/aws/cloudformation.yml) · [`cloud/aws/cloudformation.yml`](cloud/aws/cloudformation.yml) |
| Azure | [`cloud/azure/main.bicep`](cloud/azure/main.bicep) + `az deployment group create` |
| DigitalOcean | [`cloud/digitalocean/user-data.yaml`](cloud/digitalocean/user-data.yaml) · [droplet.md](cloud/digitalocean/droplet.md) |

## Ansible

Install the public Galaxy collection from a Release asset, then run the playbook:

```bash
ansible-galaxy collection install \
  https://github.com/omni-line/releases/releases/download/v0.1.3/omni_line-deploy-0.1.3.tar.gz

ansible-playbook omni_line.deploy.install -i inventory.yml \
  -e omni_line_version=0.1.3 \
  -e omni_line_server_url=https://registry.example.com \
  -e omni_line_frontend_url=https://registry.example.com
```

Each Release also attaches `omni_line-deploy.tar.gz` (same build, stable filename). Docs: https://omniline.app/docs/install/ansible

## What this repository contains

| Path / asset | Purpose |
|---|---|
| `install.sh` (on `main`) | Colored installer (preflight, prompts, Compose up) — use from `main` |
| `cloud/` (on `main`) | Cloud-init + AWS CFN / Azure Bicep / DO user-data |
| `compose/docker-compose.yml` | Official stack: Postgres + server + client |
| `compose/compose.env.example` | Env template (`OMNI_LINE_VERSION`, secrets, URLs) |
| Release: `omni_line-deploy-<version>.tar.gz` | Ansible Galaxy collection `omni_line.deploy` |
| Release: `omni_line-deploy.tar.gz` | Same collection under a stable filename |
| Release: `cloud.tgz` | Snapshot of `cloud/` for that version |

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

`install.sh` and `cloud/` on `main` are customer raw-URL sources of truth. The monorepo **Publish images** workflow syncs them to this repo’s `main` and attaches versioned Release assets. Do not commit application source here.
