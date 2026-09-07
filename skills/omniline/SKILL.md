---
name: omniline
description: Install, upgrade, repair, or bootstrap a self-hosted Omni Line package registry on a Linux/macOS host with Docker Compose. Use whenever the user mentions Omni Line, omniline, install.sh, a private registry for npm/Composer/Docker/PyPI/Go/Cargo/Maven/RubyGems/Conan, activating an Omni Line license, or upgrading an existing Omni Line instance. Detects an existing install before acting.
---

# Omni Line

Omni Line is a self-hosted package registry (npm, Composer, Docker, PyPI, Go, Cargo,
Maven, RubyGems, Conan, multipurpose). It ships as a Docker Compose stack driven by a
public `install.sh`. This skill gets an instance to a working, licensed state, or
brings an existing one to a target version, without ever reinstalling over data.

Docs: https://omniline.app/docs (LLM index: https://omniline.app/llms.txt).
Every docs page has a Markdown mirror at `https://omniline.app/docs/<path>.md`.

The `references/` links below are relative to this file. If you are reading this
skill from a URL instead of an installed copy, fetch them from the same base:
`https://raw.githubusercontent.com/omni-line/releases/main/skills/omniline/references/<name>.md`.

## Rules that never bend

1. **Never run `--reset-env` unless the user explicitly asks to wipe the instance.**
   It regenerates secrets and deletes the Postgres and artifact volumes.
2. **Never overwrite `<dir>/.env`, never rsync files over an install directory.**
   `.env` holds `JWT_SECRET`, `POSTGRES_PASSWORD`, and the admin password.
3. **Detect before you act.** Run the detection step below before any install or
   upgrade command, even when the user says "install".
4. **Confirm intent, not operations.** Ask "this host already runs 0.1.3, upgrade to
   0.1.5?" rather than "run upgrade?". On a fresh host, do not ask, install.
5. **Ask only for what you cannot derive:** the public URL when the host is not
   localhost, and the license key. Everything else has a safe default.
6. **Print secrets once, in the final summary, and tell the user where they live**
   (`<dir>/.env`). Do not echo them repeatedly or write them anywhere else.

## Step 1: Detect

Default install dir is `./omni-line` relative to the cwd; common production dirs are
`/opt/omni-line` and `~/omni-line`. If the user named a dir, use it. Otherwise check
those three, then ask.

```bash
DIR="${DIR:-./omni-line}"
if [ -f "$DIR/.env" ] && grep -qE '^(OMNI_LINE_VERSION|JWT_SECRET|POSTGRES_PASSWORD)=' "$DIR/.env"; then
  echo "state=installed"
  grep -E '^(OMNI_LINE_VERSION|OMNI_LINE_PORT|FRONTEND_URL|SERVER_URL|STORAGE_DRIVER)=' "$DIR/.env"
  PORT="$(grep -E '^OMNI_LINE_PORT=' "$DIR/.env" | cut -d= -f2-)"; PORT="${PORT:-8080}"
  curl -fsS "http://127.0.0.1:${PORT}/readyz" >/dev/null && echo "ready=yes" || echo "ready=no"
  (cd "$DIR" && docker compose --env-file .env ps 2>/dev/null)
elif [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
  echo "state=broken"   # dir exists but no valid .env
else
  echo "state=fresh"
fi
```

Latest stable release (excludes prereleases):

```bash
curl -fsS https://api.github.com/repos/omni-line/releases/releases/latest | grep -m1 '"tag_name"'
```

Route on the result:

| State | Go to |
| --- | --- |
| `fresh` | [references/install.md](references/install.md) |
| `installed`, `ready=yes` | Report current vs latest version. If the user wants a newer version or asked to upgrade, [references/update.md](references/update.md). If they only asked to "install", say it is already installed and stop. |
| `installed`, `ready=no` | [references/troubleshooting.md](references/troubleshooting.md) first. Never upgrade a stack that is not healthy unless the user accepts the risk. |
| `broken` | Ask whether the dir is a leftover. Offer to install into a different `--dir`, or to remove the leftover dir yourself only after the user confirms it holds nothing valuable. |

## Step 2: Act

Follow the routed reference. All of them use the same installer:

```bash
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/install.sh | bash -s -- <flags>
```

Always fetch `install.sh` from `main`. Use `--version x.y.z` only to pin images and
release assets. Full flag table and prerequisites are in
[references/install.md](references/install.md).

## Step 3: Verify and report

After install or upgrade, prove the outcome before reporting it:

```bash
curl -fsS "http://127.0.0.1:${PORT}/readyz"                      # stack ready
curl -fsS "http://127.0.0.1:${PORT}/api/license" \
  -H "Authorization: Bearer $ACCESS_TOKEN"                        # {"data":{"active":true,...}}
```

Final report, in this order: state before (fresh / version), state after (version),
UI URL, admin email and password (fresh installs only), install dir, license status,
PAT created (name and scopes, token shown once), and anything the user still has to
do by hand (open a firewall port, point DNS, set up TLS). If a step failed, say which
one and what the last command printed.

## Other install paths

This skill drives the Compose installer. For Kubernetes (Helm chart at
`oci://ghcr.io/omni-line/charts/omni-line`), Ansible, or cloud-init images, read the
matching docs page and follow it instead:

- https://omniline.app/docs/install/helm.md
- https://omniline.app/docs/install/ansible.md
- https://omniline.app/docs/install/cloud.md

## References

- [references/install.md](references/install.md): fresh install, flags, preflight, license activation, first PAT.
- [references/update.md](references/update.md): backup, release notes, upgrade, post-upgrade checks, rollback.
- [references/overlays.md](references/overlays.md): external Postgres, S3 storage, TLS edge, shared Docker network.
- [references/troubleshooting.md](references/troubleshooting.md): readyz timeouts, LICENSE_INVALID, CORS and public URL, port and RAM checks.
