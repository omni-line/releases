# Fresh install

Use this when detection returned `state=fresh`. Docs: https://omniline.app/docs/install/docker.md

## 1. Preflight

Run the dependency check first. It exits non-zero with a reason when something is missing.

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh | bash -s -- --check
```

What the installer requires:

| Requirement | Detail |
| --- | --- |
| OS | Linux or macOS, amd64 or arm64 |
| Docker | Engine 25+ with Compose V2. On a fresh VPS install Docker first: https://docs.docker.com/engine/install/ |
| Tools | bash, curl or wget, openssl |
| RAM | 4 GiB recommended. Installer warns below ~1.8 GiB; 2 GiB works with swap |
| Disk | 5 GiB minimum, 20+ GiB recommended. Artifacts grow without bound |
| Port | Default 8080 must be free on the host (`--port` to change) |

If RAM is low, suggest a swap file before continuing rather than passing `--force`.
If Docker is missing, install it (or tell the user how) and rerun `--check`.

## 2. Gather the two inputs

- **Public URL.** If the host is not the user's own machine, clients will open
  `http://<ip-or-hostname>:<port>` (or `https://...` behind TLS). `SERVER_URL` and
  `FRONTEND_URL` must match that origin exactly (scheme, host, port), otherwise CORS
  and sessions break. Ask for it. On localhost, skip and let the default apply.
- **License key.** Issued at https://omniline.app/licenses (the user signs in or
  creates an account, opens Licenses, copies the `OMNI-...` key). Ask for it now so
  the run can finish end to end, but do not block the install on it: the stack can
  be installed and licensed later.

## 3. Install

Non-interactive, pinned to the latest stable version resolved in detection:

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh \
  | bash -s -- -y --dir ./omni-line --url http://YOUR_IP_OR_HOSTNAME:8080
```

Flags:

| Flag | Purpose |
| --- | --- |
| `--dir <path>` | Install directory (default `./omni-line`). Use `/opt/omni-line` on servers. |
| `--version <x.y.z>` | Pin image and release assets. Default resolves latest stable. |
| `--port <n>` | Host publish port (default 8080). Container port stays 8080. |
| `--url <origin>` | Public origin for `SERVER_URL` / `FRONTEND_URL`. Required with `-y` on any non-localhost host. |
| `--yes` / `-y` | Non-interactive defaults. On an existing install this means upgrade and keep `.env`. |
| `--no-start` | Write config only, do not start containers. |
| `--check` | Dependency checks only. |
| `--force` | Continue despite port, disk, or RAM warnings. Prefer fixing the warning. |
| `--reset-env` | Destructive. Regenerates secrets and wipes volumes. Never for upgrades. |

The installer downloads `docker-compose.yml`, `compose.env.example`, `image-digests.env`
and `SHA256SUMS` for the release, verifies checksums, writes `.env` with generated
`JWT_SECRET`, `POSTGRES_PASSWORD` and a bootstrap admin password, pulls the images,
starts the stack, and waits up to 180 seconds for `/readyz`.

With `-y` the bootstrap admin is `admin@omni-line.local` with a random password. Both
are printed at the end and stored in `<dir>/.env` as `BOOTSTRAP_ADMIN_EMAIL` and
`BOOTSTRAP_ADMIN_PASSWORD`.

## 4. Verify the stack

```bash
DIR=./omni-line
PORT="$(grep -E '^OMNI_LINE_PORT=' "$DIR/.env" | cut -d= -f2-)"; PORT="${PORT:-8080}"
curl -fsS "http://127.0.0.1:${PORT}/readyz"
cd "$DIR" && docker compose --env-file .env ps
```

If `/readyz` does not answer, go to troubleshooting before doing anything else.

## 5. Sign in and activate the license

Until a license is active, everything except `/healthz`, `/readyz`, `/api/auth/*`
and `/api/license*` is gated. Do this with the API so the run finishes without a
browser. Base URL is `http://127.0.0.1:${PORT}` from the host (or the public URL).

```bash
BASE="http://127.0.0.1:${PORT}"
ADMIN_EMAIL="$(grep -E '^BOOTSTRAP_ADMIN_EMAIL=' "$DIR/.env" | cut -d= -f2-)"
ADMIN_PASSWORD="$(grep -E '^BOOTSTRAP_ADMIN_PASSWORD=' "$DIR/.env" | cut -d= -f2-)"

# Login: response is {"data":{"accessToken":"...","refreshToken":"..."}}
ACCESS_TOKEN="$(curl -fsS -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')"

# Activate. Requires org:write, which the bootstrap admin has.
curl -fsS -X POST "$BASE/api/license" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"licenseKey\":\"$LICENSE_KEY\"}"

# Confirm
curl -fsS "$BASE/api/license" -H "Authorization: Bearer $ACCESS_TOKEN"
# {"data":{"active":true,"issuedTo":"...","expiresAt":"...","features":[...]}}
```

Use `jq` for the token extraction when it is available. If activation returns
`LICENSE_INVALID`, see troubleshooting; do not touch `LICENSE_PUBLIC_KEY`.

If the user has no key yet, stop here, report the admin credentials and the portal
URL, and tell them the UI path: Settings, License, paste key.

## 6. First organization and PAT

Registries belong to an organization. The installer writes `BOOTSTRAP_CREATE_ORG=false`,
so a scripted install has none until you create one. Check first anyway:

```bash
curl -fsS "$BASE/api/organizations" -H "Authorization: Bearer $ACCESS_TOKEN"
```

If the list is empty, create one from what the user told you (fall back to their
company or project name). The slug is what package clients use in registry URLs,
so keep it short and lowercase:

```bash
curl -fsS -X POST "$BASE/api/organizations" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Acme","slug":"acme"}'
```

Create a personal access token for publishing and installing packages. The token
value is returned once; put it in the final report and nowhere else.

```bash
curl -fsS -X POST "$BASE/api/pats" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"bootstrap","project":"bootstrap","environment":"development","scopes":["registry:read","registry:write"],"expiresAt":null}'
# {"data":{"id":"...","name":"bootstrap","token":"omni_...","scopes":[...],...}}
```

## 7. Hand-off

Tell the user what is left that only they can do:

- Open the host firewall for the chosen port, or put the instance behind TLS
  (see overlays reference, `tls-edge`).
- Point DNS at the host if they gave a hostname.
- Configure SMTP in `.env` (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`,
  `MAIL_FROM`) if they want invites and password reset, then
  `docker compose --env-file .env up -d`.
- Create their first registry in the UI (Registries) or via the API, then follow the
  ecosystem how-to at `https://omniline.app/docs/registries/<kind>.md`.

## Manual Compose install

Only when the user refuses the script. Same assets, no checksum verification or
digest pinning unless done by hand.

```bash
mkdir omni-line && cd omni-line
curl -fsSL -O https://github.com/omni-line/releases/releases/latest/download/docker-compose.yml
curl -fsSL -o .env https://github.com/omni-line/releases/releases/latest/download/compose.env.example
# Edit .env: JWT_SECRET, POSTGRES_PASSWORD, SERVER_URL, FRONTEND_URL, BOOTSTRAP_ADMIN_*
docker compose --env-file .env up -d
```
