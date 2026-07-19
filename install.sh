#!/usr/bin/env bash
# Omni Line self-host installer — https://github.com/omni-line/releases
# Usage:
#   curl -fsSL https://github.com/omni-line/releases/releases/latest/download/install.sh | bash
#   ./install.sh --dir ./omni-line --yes
set -euo pipefail

OMNI_INSTALL_VERSION="1.0.0"
RELEASE_BASE="${OMNI_LINE_RELEASE_BASE:-https://github.com/omni-line/releases/releases}"
DOCS_URL="https://github.com/omni-line/releases#install"
DOCKER_INSTALL_URL="https://docs.docker.com/engine/install/"
MIN_DOCKER_MAJOR=25
MIN_DISK_GIB=5
DEFAULT_PORT=8080
DEFAULT_DIR="./omni-line"
DEFAULT_ADMIN_EMAIL="admin@omni-line.local"

# --- colors / logging (respect NO_COLOR and non-TTY) ---
_use_color=0
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  _use_color=1
fi

if (( _use_color )); then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

info()  { printf '%sℹ%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"; }
ok()    { printf '%s✔%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn()  { printf '%s⚠%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
error() { printf '%s✖%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
step()  { printf '\n%s[%s/%s]%s %s%s%s\n' "${C_CYAN}" "$1" "$2" "${C_RESET}" "${C_BOLD}" "$3" "${C_RESET}"; }

die() {
  error "$*"
  error "See ${DOCS_URL}"
  exit 1
}

# Read prompts from /dev/tty so `curl | bash` works.
prompt_read() {
  local reply=""
  if [[ -r /dev/tty ]]; then
    IFS= read -r reply </dev/tty || true
  else
    IFS= read -r reply || true
  fi
  printf '%s' "$reply"
}

ask() {
  # ask "Question" "default" → prints prompt, returns answer (or default)
  local question="$1"
  local default="${2:-}"
  local answer=""
  if [[ -n "$default" ]]; then
    printf '%s?%s %s [%s]: ' "${C_CYAN}" "${C_RESET}" "$question" "$default" >/dev/tty 2>/dev/null || \
      printf '? %s [%s]: ' "$question" "$default"
  else
    printf '%s?%s %s: ' "${C_CYAN}" "${C_RESET}" "$question" >/dev/tty 2>/dev/null || \
      printf '? %s: ' "$question"
  fi
  answer="$(prompt_read)"
  if [[ -z "$answer" ]]; then
    answer="$default"
  fi
  printf '%s' "$answer"
}

ask_yn() {
  local question="$1"
  local default="${2:-n}"
  local hint="y/N"
  [[ "$default" == "y" ]] && hint="Y/n"
  local answer
  answer="$(ask "$question ($hint)" "$default")"
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

usage() {
  cat <<EOF
${C_BOLD}Omni Line installer${C_RESET} (v${OMNI_INSTALL_VERSION})

${C_BOLD}Usage:${C_RESET}
  curl -fsSL ${RELEASE_BASE}/latest/download/install.sh | bash
  bash install.sh [options]

${C_BOLD}Options:${C_RESET}
  --dir <path>         Install directory (default: ${DEFAULT_DIR})
  --version <x.y.z>    Pin release / image tag (default: latest)
  --port <n>           Host port (default: ${DEFAULT_PORT})
  --no-start           Download + write config only
  --yes, -y            Non-interactive (defaults, no prompts)
  --reset-env          Regenerate .env (destructive)
  --check              Run dependency checks only
  --force              Continue despite port/disk warnings
  -h, --help           Show this help

${C_BOLD}Docs:${C_RESET} ${DOCS_URL}
EOF
}

# --- CLI ---
INSTALL_DIR=""
VERSION_ARG=""
PORT_ARG=""
YES=0
NO_START=0
RESET_ENV=0
CHECK_ONLY=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --version) VERSION_ARG="${2:-}"; shift 2 ;;
    --port) PORT_ARG="${2:-}"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --reset-env) RESET_ENV=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
  local url="$1"
  local dest="$2"
  if have_cmd curl; then
    curl -fsSL "$url" -o "$dest"
  elif have_cmd wget; then
    wget -qO "$dest" "$url"
  else
    die "Need curl or wget to download release assets"
  fi
}

rand_secret() {
  # URL-safe alphanumeric (safe inside postgresql://user:pass@host URLs)
  openssl rand -hex 32
}

rand_password() {
  openssl rand -hex 12
}

port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
  fi
  if have_cmd lsof; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  # Best-effort: try binding with bash /dev/tcp is not listen check
  return 1
}

free_disk_gib() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1024/1024}'
}

resolve_latest_version() {
  local tag
  if have_cmd curl; then
    tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' "${RELEASE_BASE}/latest" | sed 's#.*/##')"
  else
    tag="$(wget -qSO- "${RELEASE_BASE}/latest" 2>&1 | awk '/Location:|location:/ {print $2}' | tr -d '\r' | sed 's#.*/##' | tail -n1)"
  fi
  tag="${tag#v}"
  if [[ -z "$tag" || "$tag" == "latest" ]]; then
    die "Could not resolve latest release version from ${RELEASE_BASE}/latest"
  fi
  printf '%s' "$tag"
}

# --- preflight ---
TOTAL_STEPS=7
CURRENT=0
next_step() {
  CURRENT=$((CURRENT + 1))
  step "$CURRENT" "$TOTAL_STEPS" "$1"
}

run_preflight() {
  next_step "Checking dependencies"

  local failed=0

  if [[ -z "${BASH_VERSION:-}" ]]; then
    error "This installer requires bash"
    failed=1
  else
    ok "bash ${BASH_VERSION}"
  fi

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64) ok "architecture ${arch}" ;;
    *) error "Unsupported architecture: ${arch} (need amd64 or arm64)"; failed=1 ;;
  esac

  if have_cmd curl || have_cmd wget; then
    ok "downloader available"
  else
    error "curl or wget is required"
    failed=1
  fi

  if have_cmd openssl; then
    ok "openssl available"
  else
    error "openssl is required to generate secrets"
    failed=1
  fi

  if ! have_cmd docker; then
    error "Docker is not installed"
    error "Install Docker Engine: ${DOCKER_INSTALL_URL}"
    failed=1
  else
    ok "docker $(docker --version 2>/dev/null | head -n1)"
    if ! docker info >/dev/null 2>&1; then
      error "Docker daemon is not reachable (is the service running? are you in the docker group?)"
      failed=1
    else
      ok "docker daemon reachable"
    fi

    if ! docker compose version >/dev/null 2>&1; then
      error "Docker Compose V2 is required (docker compose …)"
      error "Install: ${DOCKER_INSTALL_URL}"
      failed=1
    else
      ok "docker compose $(docker compose version --short 2>/dev/null || echo ok)"
    fi

    local docker_ver major
    docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    major="${docker_ver%%.*}"
    if [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -lt $MIN_DOCKER_MAJOR ]]; then
      error "Docker Engine ${docker_ver} is too old (need >= ${MIN_DOCKER_MAJOR})"
      failed=1
    elif [[ -n "$docker_ver" ]]; then
      ok "docker engine ${docker_ver}"
    fi
  fi

  if (( failed )); then
    die "Preflight failed — fix the issues above and re-run"
  fi
}

check_disk_and_port() {
  local dir="$1"
  local port="$2"
  mkdir -p "$dir"
  local free
  free="$(free_disk_gib "$dir" || echo 0)"
  if [[ -n "$free" && "$free" -lt $MIN_DISK_GIB ]]; then
    if (( FORCE )); then
      warn "Low disk space: ~${free} GiB free (recommended >= ${MIN_DISK_GIB} GiB) — continuing due to --force"
    else
      die "Low disk space: ~${free} GiB free (need >= ${MIN_DISK_GIB} GiB). Re-run with --force to ignore."
    fi
  else
    ok "disk space ~${free:-?} GiB free"
  fi

  if port_in_use "$port"; then
    if (( FORCE )); then
      warn "Port ${port} appears in use — continuing due to --force"
    else
      die "Port ${port} is already in use. Choose another with --port or free it. Use --force to ignore."
    fi
  else
    ok "port ${port} looks free"
  fi
}

# --- main ---
printf '\n%s%s Omni Line installer %s%s\n\n' "${C_BOLD}" "${C_CYAN}" "${C_RESET}" "${C_DIM}v${OMNI_INSTALL_VERSION}${C_RESET}"

run_preflight

if (( CHECK_ONLY )); then
  check_disk_and_port "${INSTALL_DIR:-$DEFAULT_DIR}" "${PORT_ARG:-$DEFAULT_PORT}"
  ok "All checks passed"
  exit 0
fi

next_step "Gathering install options"

# Defaults
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
VERSION_ARG="${VERSION_ARG:-latest}"
PORT_ARG="${PORT_ARG:-$DEFAULT_PORT}"
PUBLIC_URL="http://localhost:${PORT_ARG}"
ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"
ADMIN_PASSWORD=""
CONFIGURE_SMTP=0
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
MAIL_FROM="Omni Line <no-reply@omni-line.local>"
START_STACK=1
(( NO_START )) && START_STACK=0

if (( ! YES )); then
  INSTALL_DIR="$(ask "Install directory" "$INSTALL_DIR")"
  VERSION_ARG="$(ask "Version to install (semver or latest)" "$VERSION_ARG")"
  PORT_ARG="$(ask "Host port" "$PORT_ARG")"
  PUBLIC_URL="$(ask "Public URL (browser)" "http://localhost:${PORT_ARG}")"
  ADMIN_EMAIL="$(ask "Bootstrap admin email" "$ADMIN_EMAIL")"
  if ask_yn "Set a custom bootstrap admin password?" "n"; then
    ADMIN_PASSWORD="$(ask "Bootstrap admin password" "")"
    [[ -n "$ADMIN_PASSWORD" ]] || die "Password cannot be empty"
  fi
  if ask_yn "Configure SMTP now? (invites / password reset)" "n"; then
    CONFIGURE_SMTP=1
    SMTP_HOST="$(ask "SMTP host" "")"
    SMTP_PORT="$(ask "SMTP port" "587")"
    SMTP_USER="$(ask "SMTP user (optional)" "")"
    SMTP_PASS="$(ask "SMTP password (optional)" "")"
    MAIL_FROM="$(ask "Mail from" "$MAIL_FROM")"
    [[ -n "$SMTP_HOST" ]] || die "SMTP host is required when configuring SMTP"
  fi
  if (( ! NO_START )); then
    if ask_yn "Start the stack now?" "y"; then
      START_STACK=1
    else
      START_STACK=0
    fi
  fi
fi

[[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="$(rand_password)"
GENERATED_ADMIN_PASSWORD=1
if (( YES )) || [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  :
fi

# Resolve version
if [[ "$VERSION_ARG" == "latest" ]]; then
  info "Resolving latest release…"
  VERSION_ARG="$(resolve_latest_version)"
fi
ok "version ${VERSION_ARG}"

check_disk_and_port "$INSTALL_DIR" "$PORT_ARG"

next_step "Preparing install directory"
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
ok "install dir ${INSTALL_DIR}"

next_step "Downloading release assets"
ASSET_TAG="v${VERSION_ARG}"
# Prefer release assets; fall back to raw repo paths for unreleased / local testing.
COMPOSER_URL="${RELEASE_BASE}/download/${ASSET_TAG}/docker-compose.yml"
ENV_URL="${RELEASE_BASE}/download/${ASSET_TAG}/compose.env.example"

download_or_fallback() {
  local url="$1"
  local dest="$2"
  local fallback="$3"
  if download "$url" "$dest" 2>/dev/null; then
    return 0
  fi
  if [[ -n "$fallback" && -f "$fallback" ]]; then
    warn "Release asset unavailable; using local ${fallback}"
    cp "$fallback" "$dest"
    return 0
  fi
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
LOCAL_COMPOSE="${SCRIPT_DIR:+$SCRIPT_DIR/compose/docker-compose.yml}"
LOCAL_ENV="${SCRIPT_DIR:+$SCRIPT_DIR/compose/compose.env.example}"

if ! download_or_fallback "$COMPOSER_URL" "${INSTALL_DIR}/docker-compose.yml" "${LOCAL_COMPOSE:-}"; then
  die "Could not download docker-compose.yml from ${COMPOSER_URL}"
fi
ok "docker-compose.yml"

ENV_PATH="${INSTALL_DIR}/.env"
if [[ -f "$ENV_PATH" && $RESET_ENV -eq 0 ]]; then
  ok "keeping existing .env (use --reset-env to regenerate)"
else
  if [[ -f "$ENV_PATH" && $RESET_ENV -eq 1 ]]; then
    if (( ! YES )); then
      ask_yn "Overwrite existing .env? This regenerates secrets" "n" || die "Aborted (.env left unchanged)"
    fi
    warn "regenerating .env"
  fi

  next_step "Writing .env with generated secrets"
  JWT_SECRET="$(rand_secret)"
  POSTGRES_PASSWORD="$(rand_secret)"

  cat >"$ENV_PATH" <<EOF
# Generated by Omni Line install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
OMNI_LINE_VERSION=${VERSION_ARG}
OMNI_LINE_PORT=${PORT_ARG}
SERVER_URL=${PUBLIC_URL}
FRONTEND_URL=${PUBLIC_URL}
JWT_SECRET=${JWT_SECRET}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_USER=omniline
POSTGRES_DB=omniline
BOOTSTRAP_ADMIN_EMAIL=${ADMIN_EMAIL}
BOOTSTRAP_ADMIN_PASSWORD=${ADMIN_PASSWORD}
BOOTSTRAP_ADMIN_NAME=Admin
BOOTSTRAP_ORG_NAME=Default Organization
BOOTSTRAP_ORG_SLUG=default
RUN_MIGRATIONS_ON_START=${RUN_MIGRATIONS_ON_START:-true}
RUN_BOOTSTRAP_ON_START=${RUN_BOOTSTRAP_ON_START:-true}
STORAGE_DRIVER=fs
MAIL_FROM=${MAIL_FROM}
EOF

  if (( CONFIGURE_SMTP )); then
    {
      echo "SMTP_HOST=${SMTP_HOST}"
      echo "SMTP_PORT=${SMTP_PORT}"
      echo "SMTP_SECURE=false"
      [[ -n "$SMTP_USER" ]] && echo "SMTP_USER=${SMTP_USER}"
      [[ -n "$SMTP_PASS" ]] && echo "SMTP_PASS=${SMTP_PASS}"
    } >>"$ENV_PATH"
  fi

  chmod 600 "$ENV_PATH"
  ok "wrote .env (JWT_SECRET and POSTGRES_PASSWORD generated)"
fi

# Ensure OMNI_LINE_VERSION is current when upgrading without --reset-env
if grep -q '^OMNI_LINE_VERSION=' "$ENV_PATH"; then
  # portable in-place-ish update
  tmp="$(mktemp)"
  sed "s/^OMNI_LINE_VERSION=.*/OMNI_LINE_VERSION=${VERSION_ARG}/" "$ENV_PATH" >"$tmp"
  mv "$tmp" "$ENV_PATH"
  chmod 600 "$ENV_PATH"
fi

if (( START_STACK )); then
  next_step "Pulling images and starting stack"
  (
    cd "$INSTALL_DIR"
    docker compose --env-file .env pull
    docker compose --env-file .env up -d
  )
  ok "containers started"

  next_step "Waiting for /readyz"
  READY_URL="${PUBLIC_URL%/}/readyz"
  # Prefer localhost port if PUBLIC_URL is not yet reachable
  LOCAL_READY="http://127.0.0.1:${PORT_ARG}/readyz"
  deadline=$((SECONDS + 180))
  ready=0
  while (( SECONDS < deadline )); do
    if curl -fsS "$LOCAL_READY" >/dev/null 2>&1 || curl -fsS "$READY_URL" >/dev/null 2>&1; then
      ready=1
      break
    fi
    printf '.'
    sleep 2
  done
  printf '\n'
  if (( ready )); then
    ok "stack is ready"
  else
    warn "Timed out waiting for /readyz — check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
  fi
else
  CURRENT=$((TOTAL_STEPS - 1))
  next_step "Skipping start (--no-start or declined)"
  info "Start later with: cd ${INSTALL_DIR} && docker compose --env-file .env up -d"
fi

# Load password from env if we kept existing .env
if [[ -f "$ENV_PATH" ]]; then
  # shellcheck disable=SC1090
  set -a
  # Only extract a few keys without sourcing whole file (may have special chars)
  ADMIN_EMAIL="$(grep -E '^BOOTSTRAP_ADMIN_EMAIL=' "$ENV_PATH" | head -n1 | cut -d= -f2- || true)"
  ADMIN_PASSWORD="$(grep -E '^BOOTSTRAP_ADMIN_PASSWORD=' "$ENV_PATH" | head -n1 | cut -d= -f2- || true)"
  PUBLIC_URL="$(grep -E '^FRONTEND_URL=' "$ENV_PATH" | head -n1 | cut -d= -f2- || true)"
  set +a
fi

printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_GREEN}" "${C_RESET}"
printf '%s✔ Omni Line is installed%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "${C_GREEN}" "${C_RESET}"

printf '%sReady now%s\n' "${C_BOLD}" "${C_RESET}"
printf '  UI:           %s\n' "${PUBLIC_URL:-http://localhost:${PORT_ARG}}"
printf '  Admin email:  %s\n' "${ADMIN_EMAIL}"
printf '  Admin pass:   %s\n' "${ADMIN_PASSWORD}"
printf '  Install dir:  %s\n' "${INSTALL_DIR}"
printf '  Version:      %s\n' "${VERSION_ARG}"
printf '\n'
printf '  1. Open the UI and sign in\n'
printf '  2. Activate your vendor-issued %sOMNI-…%s license key\n' "${C_BOLD}" "${C_RESET}"
printf '\n'

printf '%sAdjust if needed%s (edit %s/.env then: docker compose up -d)\n' "${C_BOLD}" "${C_RESET}" "${INSTALL_DIR}"
printf '  • Public URL / TLS behind a reverse proxy → SERVER_URL, FRONTEND_URL\n'
if (( ! CONFIGURE_SMTP )); then
  printf '  • %sSMTP%s for invites / password reset → SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, MAIL_FROM\n' "${C_YELLOW}" "${C_RESET}"
fi
printf '  • Rotate secrets → JWT_SECRET, POSTGRES_PASSWORD (DB password needs care with existing volume)\n'
printf '  • Production storage → STORAGE_DRIVER=s3 and S3_* (see docs)\n'
printf '  • External Postgres → set DATABASE_URL pattern via compose overlay (see docs)\n'
printf '  • SSO / OIDC → configure in Settings or env (see docs/sso.md)\n'
printf '  • Upgrade → re-run this installer with --version x.y.z\n'
printf '  • Logs / health → cd %s && docker compose logs -f ; curl -fsS http://127.0.0.1:%s/readyz\n' "${INSTALL_DIR}" "${PORT_ARG}"
printf '\n'
printf '%sDocs:%s %s\n\n' "${C_DIM}" "${C_RESET}" "${DOCS_URL}"
