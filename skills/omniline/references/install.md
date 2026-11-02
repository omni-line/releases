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
| Outbound HTTPS | `github.com`, `raw.githubusercontent.com` and `ghcr.io` (install and upgrades); the upstream of each proxy registry (`registry.npmjs.org`, `repo.packagist.org`, …); `api.osv.dev` (vulnerability scans); `packagist.org` (Composer advisories, 1.0.6 and later); the SMTP server, if mail is configured |

If RAM is low, suggest a swap file before continuing rather than passing `--force`.
If Docker is missing, install it (or tell the user how) and rerun `--check`.

`--check` doesn't test outbound access. On a host with an egress firewall, check it
yourself, adding the upstreams of the registries the user plans to create:

```bash
for host in ghcr.io api.osv.dev packagist.org repo.packagist.org registry.npmjs.org; do
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$host/")"
  [ "$code" = "000" ] && echo "$host unreachable" || echo "$host ok ($code)"
done
```

Any HTTP status means the host is reachable; `000` means it isn't. The stack still
installs without `api.osv.dev` or `packagist.org`, but vulnerability scans fail.

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

This token is for trying things out. Everything that only installs packages (a
laptop, CI, a deploy server) should get its own read-only token, with
`"scopes":["registry:read"]` and that project and environment (`development`,
`ci`, `staging` or `production`). Then one can be revoked without breaking the
others, and vulnerability counts tell the environments apart. Say so in the
hand-off.

## 7. Hand-off

Tell the user what is left that only they can do:

- Open the host firewall for the chosen port, or put the instance behind TLS
  (see overlays reference, `tls-edge`).
- Point DNS at the host if they gave a hostname.
- Configure email if they want invitations, password reset or scan reports
  ([Configure email](#configure-email-smtp) below). Without it, invitations don't
  reach anyone: the invite link is only sent by email.
- Create their first registry in the UI (Registries) or via the API, then follow the
  ecosystem how-to at `https://omniline.app/docs/registries/<kind>.md`.
- For an existing Composer project, the lock file has to be migrated, or
  `composer install` keeps downloading from GitHub and bypasses Omni Line. The
  Composer how-to covers it ("Move an existing project"), along with tokens for CI
  and deploy servers.

## Configure email (SMTP)

Without SMTP nothing that sends email works, and nothing says so: invitations,
password reset and scan reports. The server falls back to `localhost`, where
nothing listens. Each message is retried five times over about 15 minutes, then
moves to the `email.send.dlq` queue with an error in the server log.

The user supplies the SMTP provider's host, port, user and password. Add or
replace these keys in `<dir>/.env` without rewriting the rest of the file (rule 2),
and don't print `SMTP_PASS`:

```bash
SMTP_HOST=smtp.example.com
SMTP_PORT=587        # 465 for implicit TLS
SMTP_SECURE=false    # true with port 465
SMTP_USER=...
SMTP_PASS=...
MAIL_FROM=Omni Line <no-reply@mail.example.com>
```

- `MAIL_FROM` must use a domain verified with the provider (SPF and DKIM). The
  default `no-reply@omni-line.local` is rejected or lands in spam, and a domain
  with a DMARC `p=reject` policy rejects any unverified sender.
- With port 465, `SMTP_SECURE` must be `true`. The installer's SMTP prompt sets it
  from the port since installer 1.1.2 (`install.sh --help` prints the version).
  Older installers always wrote `false`, so check it on existing installs.

Recreate the server, then check the connection and login without sending a
message:

```bash
cd "$DIR" && docker compose --env-file .env up -d server
docker compose --env-file .env exec -T -w /app server node --input-type=module -e '
import nodemailer from "nodemailer";
const t = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: Number(process.env.SMTP_PORT),
  secure: process.env.SMTP_SECURE === "true",
  auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } : undefined,
});
await t.verify();
console.log("SMTP OK");'
```

`SMTP OK` means the server reached the provider and logged in. To confirm
delivery, ask the user to request a password reset for their own account.

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
