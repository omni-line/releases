#!/usr/bin/env bash
# Omni Line cloud bootstrap — install Docker Engine, then the official install.sh.
# Used by AWS CloudFormation UserData, Azure CustomScript, and DigitalOcean user-data.
#
# Env (optional):
#   OMNI_URL       Public origin override (e.g. https://registry.example.com)
#   OMNI_PORT      Host port (default 8080)
#   OMNI_VERSION   Pin GHCR / compose assets (passed to install.sh --version)
#   OMNI_DIR       Install directory (default /opt/omni-line)
#   OMNI_FORCE     If 1, re-run even when .env already exists
#   OMNI_CLOUD_INIT_URL  Override URL for this script (unused; for docs)
set -euo pipefail

OMNI_DIR="${OMNI_DIR:-/opt/omni-line}"
OMNI_PORT="${OMNI_PORT:-8080}"
INSTALL_SCRIPT_URL="${OMNI_LINE_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/omni-line/releases/main/install.sh}"
DOCS_URL="https://omniline.app/docs/install/cloud"
LOG_FILE="/var/log/omni-line-cloud-init.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

info() { printf '[omni-cloud] %s\n' "$*"; }
die()  { printf '[omni-cloud] ERROR: %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- idempotency ---
if [[ -f "${OMNI_DIR}/.env" && "${OMNI_FORCE:-0}" != "1" ]]; then
  info "Found ${OMNI_DIR}/.env — skipping bootstrap (set OMNI_FORCE=1 to re-run)"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# --- packages for metadata + installer ---
if have_cmd apt-get; then
  apt-get update -y
  apt-get install -y --no-install-recommends curl ca-certificates openssl
elif have_cmd dnf; then
  dnf install -y curl ca-certificates openssl
elif have_cmd yum; then
  yum install -y curl ca-certificates openssl
fi

have_cmd curl || die "curl is required"
have_cmd openssl || die "openssl is required"

# --- Docker Engine 25+ with Compose V2 ---
install_docker() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    local major
    major="$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1 || true)"
    if [[ -n "${major}" && "${major}" -ge 25 ]]; then
      info "Docker $(docker version --format '{{.Server.Version}}') already present"
      return 0
    fi
  fi
  info "Installing Docker Engine via get.docker.com"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker || true
}

install_docker

# Wait for the daemon after a fresh install (cloud-init runs as root; no newgrp needed).
for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker info >/dev/null 2>&1 || die "Docker daemon is not ready"
docker compose version >/dev/null 2>&1 || die "docker compose (V2) is required"

# --- public origin from env or cloud metadata ---
detect_public_ip() {
  local ip=""

  # AWS IMDS (IMDSv2 then v1)
  local token=""
  token="$(curl -fsS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
  if [[ -n "${token}" ]]; then
    ip="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: ${token}" \
      http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  else
    ip="$(curl -fsS -m 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
  fi
  if [[ -n "${ip}" && "${ip}" != "null" ]]; then
    printf '%s' "${ip}"
    return 0
  fi

  # Azure IMDS
  ip="$(curl -fsS -m 2 -H "Metadata:true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
    2>/dev/null || true)"
  if [[ -n "${ip}" && "${ip}" != "null" ]]; then
    printf '%s' "${ip}"
    return 0
  fi

  # DigitalOcean
  ip="$(curl -fsS -m 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)"
  if [[ -n "${ip}" && "${ip}" != "null" ]]; then
    printf '%s' "${ip}"
    return 0
  fi

  return 1
}

resolve_url() {
  if [[ -n "${OMNI_URL:-}" ]]; then
    printf '%s' "${OMNI_URL}"
    return 0
  fi
  local ip
  if ip="$(detect_public_ip)"; then
    printf 'http://%s:%s' "${ip}" "${OMNI_PORT}"
    return 0
  fi
  die "Could not detect public IP. Set OMNI_URL (e.g. http://YOUR_IP:${OMNI_PORT})"
}

OMNI_URL="$(resolve_url)"
info "Public origin: ${OMNI_URL}"

# --- run official installer ---
INSTALL_ARGS=(-y --dir "${OMNI_DIR}" --port "${OMNI_PORT}" --url "${OMNI_URL}")
if [[ -n "${OMNI_VERSION:-}" ]]; then
  INSTALL_ARGS+=(--version "${OMNI_VERSION}")
fi

info "Running install.sh ${INSTALL_ARGS[*]}"
curl -fsSL "${INSTALL_SCRIPT_URL}" | bash -s -- "${INSTALL_ARGS[@]}"

# --- MOTD for SSH sessions ---
write_motd() {
  local dir="/etc/update-motd.d"
  local file="${dir}/99-omni-line"
  if [[ ! -d "${dir}" ]]; then
    # Non-Ubuntu: plain motd fragment
    mkdir -p /etc/motd.d 2>/dev/null || true
    file="/etc/motd.d/omni-line"
  fi
  cat > "${file}" <<EOF
#!/bin/sh
cat <<'MOTD'

  Omni Line is installed at ${OMNI_DIR}
  UI:  ${OMNI_URL}
  Docs: ${DOCS_URL}
  Logs: docker compose -f ${OMNI_DIR}/docker-compose.yml --env-file ${OMNI_DIR}/.env logs -f
  Bootstrap admin credentials are in ${OMNI_DIR}/.env (BOOTSTRAP_ADMIN_*)

MOTD
EOF
  chmod +x "${file}" 2>/dev/null || true
}

write_motd
info "Bootstrap complete — open ${OMNI_URL}"
