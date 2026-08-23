#!/usr/bin/env bash
# Vendor-managed Cloud overlay — run after install.sh on DigitalOcean droplets.
# Expects OMNI_DIR, OMNI_URL (https://), optional SEED_LICENSE_KEY, BOOTSTRAP_* overrides.
set -euo pipefail

OMNI_DIR="${OMNI_DIR:-/opt/omni-line}"
OMNI_PORT="${OMNI_PORT:-8080}"
ENV_FILE="${OMNI_DIR}/.env"

info() { printf '[omni-managed] %s\n' "$*"; }
die()  { printf '[omni-managed] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE} — run install.sh first"

if [[ "${OMNI_URL:-}" != https://* ]]; then
  die "OMNI_URL must be an https:// origin for managed Cloud (got: ${OMNI_URL:-unset})"
fi

HOSTNAME="$(printf '%s' "${OMNI_URL}" | sed -E 's#^https://([^/]+).*$#\1#')"

info "Applying managed Cloud settings to ${ENV_FILE}"
grep -q '^OMNI_CLOUD_MANAGED=' "${ENV_FILE}" \
  && sed -i 's/^OMNI_CLOUD_MANAGED=.*/OMNI_CLOUD_MANAGED=true/' "${ENV_FILE}" \
  || echo 'OMNI_CLOUD_MANAGED=true' >> "${ENV_FILE}"

for key in SERVER_URL FRONTEND_URL; do
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${OMNI_URL}|" "${ENV_FILE}"
  else
    echo "${key}=${OMNI_URL}" >> "${ENV_FILE}"
  fi
done

if [[ -n "${SEED_LICENSE_KEY:-}" ]]; then
  if grep -q '^SEED_LICENSE_KEY=' "${ENV_FILE}"; then
    sed -i "s|^SEED_LICENSE_KEY=.*|SEED_LICENSE_KEY=${SEED_LICENSE_KEY}|" "${ENV_FILE}"
  else
    echo "SEED_LICENSE_KEY=${SEED_LICENSE_KEY}" >> "${ENV_FILE}"
  fi
fi

if [[ -n "${BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
  sed -i "s|^BOOTSTRAP_ADMIN_PASSWORD=.*|BOOTSTRAP_ADMIN_PASSWORD=${BOOTSTRAP_ADMIN_PASSWORD}|" "${ENV_FILE}" || true
fi
if [[ -n "${BOOTSTRAP_ADMIN_EMAIL:-}" ]]; then
  sed -i "s|^BOOTSTRAP_ADMIN_EMAIL=.*|BOOTSTRAP_ADMIN_EMAIL=${BOOTSTRAP_ADMIN_EMAIL}|" "${ENV_FILE}" || true
fi

TLS_DIR="${OMNI_DIR}/managed-tls"
mkdir -p "${TLS_DIR}"

cat > "${TLS_DIR}/Caddyfile" <<EOF
${HOSTNAME} {
	encode gzip
	reverse_proxy 127.0.0.1:${OMNI_PORT}
}
EOF

cat > "${TLS_DIR}/docker-compose.yml" <<EOF
services:
  caddy-edge:
    image: caddy:2.10-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

volumes:
  caddy_data:
  caddy_config:
EOF

info "Starting TLS edge (Caddy on 80/443 → localhost:${OMNI_PORT})"
docker compose -f "${TLS_DIR}/docker-compose.yml" up -d

info "Restarting Omni Line stack with updated .env"
docker compose -f "${OMNI_DIR}/docker-compose.yml" --env-file "${ENV_FILE}" up -d

info "Managed Cloud overlay complete — ${OMNI_URL}"
