# Troubleshooting

Work top-down: stack up, then ready, then licensed, then reachable from the browser.
Docs: https://omniline.app/docs/concepts.md (License troubleshooting section),
https://omniline.app/docs/install/docker.md

Always start by collecting state:

```bash
cd "$DIR"
docker compose --env-file .env ps
docker compose --env-file .env logs --tail=100 server
docker compose --env-file .env logs --tail=50 postgres client
grep -E '^(OMNI_LINE_VERSION|OMNI_LINE_PORT|SERVER_URL|FRONTEND_URL|STORAGE_DRIVER|RUN_MIGRATIONS_ON_START)=' .env
```

Never print `JWT_SECRET`, `POSTGRES_PASSWORD`, `BOOTSTRAP_ADMIN_PASSWORD` or
`SMTP_PASS` while collecting state.

## Preflight failures (installer `--check` or first run)

| Symptom | Fix |
| --- | --- |
| Docker not found / Compose V1 | Install Docker Engine 25+ with the Compose plugin: https://docs.docker.com/engine/install/ . `docker compose version` must work (with a space). |
| `Port 8080 is already in use` | `ss -ltnp \| grep :8080` to see who owns it. Either free it or install with `--port <n>` and pass the matching `--url`. Do not use `--force`. |
| Low RAM warning | Add swap (`fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`, then persist in `/etc/fstab`) and rerun. |
| Low disk warning | Artifacts are grow-only. Free space or mount a larger volume before continuing. |
| `Could not resolve a valid latest version` | GitHub API rate limit or no network. Pass `--version x.y.z` explicitly (find it at https://github.com/omni-line/releases/releases). |
| Checksum mismatch | Partial download or tampered asset. Rerun; if it repeats, stop and report it. |

## `/readyz` times out after install or upgrade

1. `docker compose --env-file .env ps`: is `postgres` healthy and `server` running?
2. `server` restarting: read its logs. Common causes:
   - Postgres auth failure after a `--reset-env` on an old volume: the installer
     should have wiped volumes; if not, `docker compose --env-file .env down -v` will
     destroy data, so confirm with the user first.
   - Migration error: the log names the migration. Do not retry blindly; report the
     error and check the release notes.
   - `DATABASE_URL` unreachable when the external-db overlay is in use.
3. `server` up but `/readyz` returns 503 `{"status":"not ready"}`: the server cannot
   run `SELECT 1` against Postgres. Check `postgres` health, `POSTGRES_PASSWORD`, or
   `DATABASE_URL` with the external-db overlay.
4. `/readyz` is fine but uploads fail: storage misconfigured (S3 credentials, bucket,
   endpoint, `S3_FORCE_PATH_STYLE=true` for MinIO). Readiness does not cover storage.

## License

| Code / symptom | Meaning and fix |
| --- | --- |
| `LICENSE_INVALID` | Signature check failed. The key was not issued for the vendor public key baked into this server image, or the string is truncated. Re-copy the full `OMNI-...` key from https://omniline.app/licenses. Never set `LICENSE_PUBLIC_KEY` in `.env`; if it is set, remove it and recreate the server. |
| `License key has expired` | `expiresAt` is in the past. Renew or request a new key in the portal. |
| `LICENSE_REQUIRED` on other routes | No active license yet. Log in, `POST /api/license`, then retry. |
| Product still gated after activation | `GET /api/license` should show `active: true`. If it does, the browser session is the problem: check `SERVER_URL` / `FRONTEND_URL` match the origin opened in the browser, then hard-refresh. |
| `403` on `POST /api/license` | The token lacks `org:write`. Use the bootstrap admin from `.env`. |

## Cannot log in / CORS errors / session drops in the browser

`SERVER_URL` and `FRONTEND_URL` in `.env` must equal the origin the browser opens,
scheme, host, and port included. `http://localhost:8080` works only on the machine
itself. On a VPS set both to `http://<ip-or-hostname>:<port>` (or `https://...`
behind TLS), then:

```bash
cd "$DIR" && docker compose --env-file .env up -d --force-recreate server client
```

Bootstrap admin credentials are `BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD`
in `.env`. The password there is only applied on first bootstrap; changing it in
`.env` later does not change the account. Use the UI or `POST /api/auth/me/password`.

## 502 from a reverse proxy after an upgrade

The proxy cached the old client container IP. Recreate or reload the proxy, or use
the external-network overlay with a resolver of `127.0.0.11`. Confirm the proxy
targets `omni-line:8080` (container port), not `OMNI_LINE_PORT`.

## Package clients get 401 / 403

- The PAT scopes are intersected with the user's org role. A `registry:write` PAT on
  a read-only member still cannot publish.
- The registry URL in the client config must use the org slug from
  `GET /api/organizations`, not a guess.
- Composer keeps one credential per host. A token in the global `auth.json`
  (`~/.composer/auth.json` or `$COMPOSER_HOME/auth.json`) belongs to whichever
  project saved it last, and other projects on the same machine send it too. Keep
  each project's token in its own `auth.json`, or in `COMPOSER_AUTH` in CI and on
  deploy servers: both take precedence over the global file.
- On a deploy server where each deploy gets a new release directory (zero-downtime
  deploys on Laravel Forge, Envoyer, Deployer), an `auth.json` inside the release is
  gone at the next deploy. Keep the credentials in a file outside the releases and
  export `COMPOSER_AUTH` in the deploy script.
- Per-ecosystem client setup is at `https://omniline.app/docs/registries/<kind>.md`
  (npm, composer, docker, pypi, go, cargo, maven, ruby, conan, multipurpose).

## Packages don't show up as cached or in use

The client isn't downloading through Omni Line. Token usage only records what goes
through the registry.

- **Composer, existing project:** `composer install` downloads from the dist URLs in
  `composer.lock`, usually GitHub, whatever `repositories` says, and never calls
  Omni Line. Migrate the lock file ("Move an existing project" in
  `https://omniline.app/docs/registries/composer.md`); `composer update --lock`
  doesn't rewrite the URLs. `composer install -vvv` shows where each package comes
  from.
- **npm:** `package-lock.json` URLs on `registry.npmjs.org` are redirected to the
  configured registry automatically. Locks resolved from another host need
  `replace-registry-host=always` in `.npmrc`.

## Emails don't arrive

1. `grep -E '^(SMTP_HOST|SMTP_PORT|SMTP_SECURE|SMTP_USER|MAIL_FROM)=' .env`. Without
   `SMTP_HOST`, the server sends to `localhost`, where nothing listens. Port 465
   needs `SMTP_SECURE=true`.
2. Run the connection check under "Configure email" in the install reference.
3. `docker compose --env-file .env logs server | grep 'email.send permanently failed'`.
   The error appears about 15 minutes after the send, once the retries run out.
4. The check passes but the email never arrives: `MAIL_FROM` is probably not on a
   domain verified with the provider. Check the provider's logs.

Invitations only reach people by email, and so does password reset; there's no link
to copy from the UI.

## Vulnerability scans fail

The registry's Vulnerabilities tab lists the scan as failed; the server log has the
cause.

| Log message | Fix |
| --- | --- |
| `OSV querybatch failed` or a fetch error to `api.osv.dev` | Open outbound HTTPS to `api.osv.dev`. |
| `Packagist security advisories failed` or a fetch error to `packagist.org` | Composer registries check Packagist's advisories since 1.0.6, hosted ones included. Open outbound HTTPS to `packagist.org`. |

A failed scan keeps the previous results; it doesn't mark findings fixed.

## Creating registries

`Registry slug already in use` can come from another organization: registry slugs
are unique across the instance, not per organization, even though registry URLs
include the organization. Pick another slug, such as `packagist` instead of
`composer`. Tracked in https://github.com/omni-line/monorepo/issues/99.

## Reporting a failure

Include: the command that failed, its last 30 lines of output, `docker compose ps`,
the `.env` keys listed at the top of this file (values redacted for secrets), and
`OMNI_LINE_VERSION`. Point the user to https://omniline.app/docs and the release
notes at https://github.com/omni-line/releases/releases.
