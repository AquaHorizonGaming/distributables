#!/usr/bin/env bash
set -euo pipefail

############################################
# CONSTANTS (DEFAULTS; MAY AUTO-ADJUST)
############################################
INSTALL_DIR="/opt/riven"

# Default Linux paths (non-WSL)
BACKEND_PATH="/mnt/riven/backend"
MOUNT_PATH="/mnt/riven/mount"

LOG_DIR="/tmp/logs/riven"

MEDIA_COMPOSE_URL="https://raw.githubusercontent.com/AquaHorizonGaming/distributables/main/ubuntu/docker-compose.media.yml"
RIVEN_COMPOSE_URL="https://raw.githubusercontent.com/AquaHorizonGaming/distributables/main/ubuntu/docker-compose.yml"

DEFAULT_ORIGIN="http://localhost:3000"
INSTALL_VERSION="v0.5.8"

############################################
# HELPERS
############################################
banner(){ echo -e "\n========================================\n $1\n========================================"; }
ok()   { printf "✔  %s\n" "$1"; }
warn() { printf "⚠  %s\n" "$1"; }
fail() { printf "✖  %s\n" "$1"; exit 1; }

############################################
# REQUIRED NON-EMPTY (SILENT)
############################################
require_non_empty() {
  local prompt="$1" val
  while true; do
    IFS= read -r -p "$prompt: " val
    val="$(printf '%s' "$val" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
    warn "Value required"
  done
}

############################################
# REQUIRED NON-EMPTY (MASKED ****)
############################################
read_masked_non_empty() {
  local prompt="$1"
  local val="" char

  while true; do
    val=""
    printf "%s: " "$prompt"
    while IFS= read -r -s -n1 char; do
      [[ $char == $'\n' ]] && break
      if [[ $char == $'\177' ]]; then
        if [[ -n "$val" ]]; then
          val="${val%?}"
          printf '\b \b'
        fi
        continue
      fi
      val+="$char"
      printf '*'
    done
    echo
    val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
    warn "Value required"
  done
}

############################################
# URL VALIDATION
############################################
require_url() {
  local prompt="$1" val
  while true; do
    IFS= read -r -p "$prompt: " val
    val="$(printf '%s' "$val" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$val" =~ ^https?:// ]] && { printf '%s' "$val"; return; }
    warn "Must include http:// or https://"
  done
}

############################################
# OS CHECK (Ubuntu + WSL Support)
############################################
banner "OS Check"

IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  IS_WSL=true
  warn "WSL detected"
fi

[[ "$(uname -s)" == "Linux" ]] || fail "Linux required"
[[ -f /etc/os-release ]] || fail "Cannot determine OS (missing /etc/os-release)"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "Ubuntu required (detected: ${PRETTY_NAME:-unknown})"
ok "Ubuntu detected (${PRETTY_NAME})"

############################################
# ROOT CHECK
############################################
[[ "$(id -u)" -eq 0 ]] || fail "Run with sudo"

############################################
# INSTALLER VERSION
############################################
banner "Version"
ok "Installer version: ${INSTALL_VERSION:-unknown}"

############################################
# LOGGING MODULE
############################################
banner "Logging"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'echo "[ERROR] Installer exited unexpectedly at line $LINENO"' ERR
ok "Logging initialized"
ok "Log file: $LOG_FILE"

############################################
# WSL PATH AUTO-ADJUSTMENT
# - Prefer Windows drive paths for persistence
# - Use safe fallback if /mnt/c not present
############################################
banner "WSL Path Handling"

WSL_ROOT=""
WSL_IS_DRVFS=false

if [[ "$IS_WSL" == true ]]; then
  if [[ -d /mnt/c ]]; then
    # Default persistent root on Windows drive
    WSL_ROOT="/mnt/c/riven"
    WSL_IS_DRVFS=true
    ok "WSL: Using Windows drive root: $WSL_ROOT"
  else
    # Fallback inside WSL filesystem
    WSL_ROOT="/mnt/riven"
    WSL_IS_DRVFS=false
    warn "WSL: /mnt/c not found; using WSL filesystem root: $WSL_ROOT"
  fi

  BACKEND_PATH="$WSL_ROOT/backend"
  MOUNT_PATH="$WSL_ROOT/mount"
  ok "WSL: BACKEND_PATH=$BACKEND_PATH"
  ok "WSL: MOUNT_PATH=$MOUNT_PATH"
else
  ok "Non-WSL: Using default Linux paths"
fi

############################################
# TIMEZONE
############################################
banner "Timezone"

if [[ "$IS_WSL" == true ]]; then
  warn "WSL detected — skipping system timezone configuration"
  TZ_SELECTED="$(date +%Z 2>/dev/null || echo UTC)"
else
  detect_timezone() {
    timedatectl show --property=Timezone --value 2>/dev/null \
      || cat /etc/timezone 2>/dev/null \
      || echo UTC
  }

  TZ_DETECTED="$(detect_timezone)"
  read -rp "Timezone [$TZ_DETECTED]: " TZ_INPUT
  TZ_SELECTED="${TZ_INPUT:-$TZ_DETECTED}"

  [[ -f "/usr/share/zoneinfo/$TZ_SELECTED" ]] || fail "Invalid timezone: $TZ_SELECTED"
  ln -sf "/usr/share/zoneinfo/$TZ_SELECTED" /etc/localtime
  echo "$TZ_SELECTED" > /etc/timezone
fi
ok "Timezone: $TZ_SELECTED"

############################################
# SYSTEM DEPS
############################################
banner "System Dependencies"

dpkg -s ca-certificates curl gnupg lsb-release openssl fuse3 >/dev/null 2>&1 \
  && ok "System dependencies already installed" \
  || {
    apt-get update || fail "apt update failed"
    apt-get install -y ca-certificates curl gnupg lsb-release openssl fuse3 \
      || fail "dependency install failed"
    ok "System dependencies installed"
  }

############################################
# USER / UID / GID DETECTION
############################################
banner "UserDetect"

TARGET_UID=1000
TARGET_GID=1000

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  TARGET_UID="$(id -u "$SUDO_USER")"
  TARGET_GID="$(id -g "$SUDO_USER")"
else
  user="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
  if [[ -n "${user:-}" ]]; then
    TARGET_UID="$(id -u "$user")"
    TARGET_GID="$(id -g "$user")"
  fi
fi

ok "Detected user ownership: UID=$TARGET_UID GID=$TARGET_GID"

############################################
# DOCKER DESKTOP DETECTION (WSL)
############################################
banner "Docker Desktop Detection"

docker_desktop_detected=false

docker_desktop_probe() {
  # Must have docker CLI
  command -v docker >/dev/null 2>&1 || return 1

  # Must have a reachable daemon
  docker info >/dev/null 2>&1 || return 2

  # Typical Docker Desktop indicators in WSL:
  # - OperatingSystem contains "Docker Desktop"
  # - Filesystem marker /mnt/wsl/docker-desktop exists
  local os=""
  os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"

  if echo "$os" | grep -qi "Docker Desktop"; then
    return 0
  fi

  if [[ -d /mnt/wsl/docker-desktop ]] || [[ -d /mnt/wslg ]]; then
    # Not definitive alone, but a strong hint in WSL environments
    return 0
  fi

  return 3
}

############################################
# DOCKER
############################################
banner "Docker"

if command -v docker >/dev/null 2>&1; then
  ok "Docker CLI detected"
else
  if [[ "$IS_WSL" == true ]]; then
    fail "Docker not found. In WSL, install Docker Desktop and enable WSL integration."
  else
    echo "[*] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installed"
  fi
fi

if ! docker info >/dev/null 2>&1; then
  if [[ "$IS_WSL" == true ]]; then
    fail "Docker daemon not reachable. Ensure Docker Desktop is running and WSL integration is enabled."
  else
    fail "Docker daemon not running"
  fi
fi

if [[ "$IS_WSL" == true ]]; then
  if docker_desktop_probe; then
    docker_desktop_detected=true
    ok "Docker Desktop detected (WSL integration OK)"
  else
    warn "Docker Desktop not confidently detected, but Docker daemon is reachable."
    warn "If you hit networking/volume issues, confirm Docker Desktop → Settings → Resources → WSL Integration."
  fi
fi

############################################
# DOCKER GROUP / USER PERMISSIONS
############################################
banner "DockerGroup"

setup_docker_group() {
  if ! getent group docker >/dev/null 2>&1; then
    groupadd docker || fail "Failed to create docker group"
    ok "Docker group created"
  else
    ok "Docker group already exists"
  fi

  local user=""
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    user="$SUDO_USER"
  else
    user="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
  fi

  if [[ -z "$user" ]]; then
    warn "No non-root user found to add to docker group"
    return
  fi

  if id -nG "$user" | grep -qw docker; then
    ok "User '$user' already in docker group"
  else
    usermod -aG docker "$user" || fail "Failed to add $user to docker group"
    ok "User '$user' added to docker group"
    warn "Log out and back in for Docker permissions to apply"
  fi
}

if [[ "$IS_WSL" == true ]]; then
  warn "WSL detected — skipping docker group modification (typically unnecessary with Docker Desktop)"
else
  setup_docker_group
fi

############################################
# FILESYSTEM
############################################
banner "Filesystem"

mkdir -p "$BACKEND_PATH" "$MOUNT_PATH" "$INSTALL_DIR"

if [[ "$IS_WSL" == true && "$WSL_IS_DRVFS" == true ]]; then
  warn "WSL + /mnt/c detected — skipping chown (Windows/DrvFS does not honor Linux ownership reliably)"
else
  chown "$TARGET_UID:$TARGET_GID" "$BACKEND_PATH" "$MOUNT_PATH" || fail "Failed to chown backend or mount path"
  chown "$TARGET_UID:$TARGET_GID" "$INSTALL_DIR" || fail "Failed to chown install dir"
fi

ok "Filesystem ready"
ok "Install Dir:  $INSTALL_DIR"
ok "Backend Path: $BACKEND_PATH"
ok "Mount Path:   $MOUNT_PATH"

############################################
# RIVEN MOUNT HANDLING
# - WSL cannot do rshared correctly
############################################
ensure_riven_rshared_mount() {
  local SERVICE_NAME="riven-bind-shared.service"

  banner "Ensuring rshared mount for Riven"
  mkdir -p "$MOUNT_PATH"

  if findmnt -no PROPAGATION "$MOUNT_PATH" 2>/dev/null | grep -q shared; then
    ok "Mount already rshared"
    return
  fi

  warn "Mount is not rshared — installing systemd unit"
  cat >/etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=Make Riven mount bind shared
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mount --bind $MOUNT_PATH $MOUNT_PATH
ExecStart=/usr/bin/mount --make-rshared $MOUNT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  if findmnt -no PROPAGATION "$MOUNT_PATH" 2>/dev/null | grep -q shared; then
    ok "rshared mount enforced"
  else
    fail "Failed to enforce rshared mount on $MOUNT_PATH"
  fi
}

banner "Mount Configuration"
if [[ "$IS_WSL" == true ]]; then
  warn "WSL detected — skipping rshared mount enforcement (not supported)"
else
  ensure_riven_rshared_mount
fi

############################################
# DOWNLOAD COMPOSE FILES
############################################
banner "Docker Compose Files"
cd "$INSTALL_DIR"
curl -fsSL "$MEDIA_COMPOSE_URL" -o docker-compose.media.yml
curl -fsSL "$RIVEN_COMPOSE_URL" -o docker-compose.yml
ok "Compose files downloaded"

############################################
# WSL-SPECIFIC COMPOSE OVERRIDE (AUTO-GENERATED)
# - Detect services that mount /mnt/riven/backend or /mnt/riven/mount
# - Override those mounts to use $BACKEND_PATH and $MOUNT_PATH on WSL
############################################
banner "WSL Compose Override"

WSL_OVERRIDE_FILE="$INSTALL_DIR/docker-compose.wsl.override.yml"
USE_WSL_OVERRIDE=false

generate_wsl_override() {
  local base_compose="$1"
  local out_file="$2"
  local backend="$3"
  local mount="$4"

  # Discover services that reference the default Linux paths
  # and generate an override that remaps them to WSL paths
  local services=""
  services="$(awk '
    BEGIN { in_services=0; svc=""; hit=0; }
    /^services:[[:space:]]*$/ { in_services=1; next }
    in_services==1 {
      # Service key is 2 spaces then name then colon
      if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/) {
        svc=$0
        sub(/^[[:space:]]{2}/, "", svc)
        sub(/:[[:space:]]*$/, "", svc)
        hit=0
      }

      # Look for default hardcoded paths
      if (index($0, "/mnt/riven/backend") > 0 || index($0, "/mnt/riven/mount") > 0) {
        hit=1
      }

      # When leaving a service block (next service or end),
      # print svc if hit was seen.
      if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/ && svc != "" && hit == 1) {
        # handled at start of next service; keep simple
      }
    }
    END { }
  ' "$base_compose" >/dev/null 2>&1; true)"

  # Better: do a second pass that actually collects names
  services="$(awk '
    BEGIN { in_services=0; svc=""; hit=0; }
    /^services:[[:space:]]*$/ { in_services=1; next }
    in_services==1 {
      if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/) {
        # On new service, emit previous if hit
        if (svc != "" && hit == 1) print svc
        svc=$0
        sub(/^[[:space:]]{2}/, "", svc)
        sub(/:[[:space:]]*$/, "", svc)
        hit=0
      }
      if (index($0, "/mnt/riven/backend") > 0 || index($0, "/mnt/riven/mount") > 0) hit=1
    }
    END {
      if (svc != "" && hit == 1) print svc
    }
  ' "$base_compose" | sort -u)"

  if [[ -z "${services:-}" ]]; then
    warn "No services found with hardcoded /mnt/riven paths — not generating WSL override"
    return 1
  fi

  {
    echo "services:"
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      echo "  $svc:"
      echo "    volumes:"
      echo "      - \"${backend}:/mnt/riven/backend\""
      echo "      - \"${mount}:/mnt/riven/mount\""
    done <<< "$services"
  } > "$out_file"

  ok "WSL override generated: $out_file"
  ok "Services patched:"
  echo "$services" | sed 's/^/  • /'
  return 0
}

if [[ "$IS_WSL" == true ]]; then
  if generate_wsl_override "$INSTALL_DIR/docker-compose.yml" "$WSL_OVERRIDE_FILE" "$BACKEND_PATH" "$MOUNT_PATH"; then
    USE_WSL_OVERRIDE=true
  else
    warn "WSL override not created. If your compose already uses env vars for mounts, you're fine."
  fi
else
  ok "Non-WSL: No override needed"
fi

############################################
# MEDIA SERVER SELECTION (REQUIRED)
############################################
banner "Media Server Selection (REQUIRED)"
echo "1) Jellyfin"
echo "2) Plex"
echo "3) Emby"
read -rp "Select ONE media server: " MEDIA_SEL

case "$MEDIA_SEL" in
  1) MEDIA_PROFILE="jellyfin"; MEDIA_PORT=8096 ;;
  2) MEDIA_PROFILE="plex";     MEDIA_PORT=32400 ;;
  3) MEDIA_PROFILE="emby";     MEDIA_PORT=8097 ;;
  *) fail "Media server REQUIRED" ;;
esac

############################################
# START MEDIA SERVER
############################################
banner "Starting Media Server"

MEDIA_COMPOSE_ARGS=(-f docker-compose.media.yml)

# (Optional) You can add a separate media override here later if needed:
# if [[ "$IS_WSL" == true ]]; then MEDIA_COMPOSE_ARGS+=(-f docker-compose.media.wsl.override.yml); fi

docker compose "${MEDIA_COMPOSE_ARGS[@]}" --profile "$MEDIA_PROFILE" up -d
ok "Media server started"

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "➡️  Open your media server in a browser:"
echo "👉  http://$SERVER_IP:$MEDIA_PORT"
echo
echo "• Complete setup"
echo "• Create admin user"
echo "• Generate API key / token"
echo
read -rp "Press ENTER once media server setup is complete..."

############################################
# MEDIA AUTH TOKEN / API KEY
############################################
banner "Media Server Authentication"
echo "⚠️  Note: Paste tokens normally and press ENTER."
echo

case "$MEDIA_PROFILE" in
  jellyfin)
    MEDIA_API_KEY="$(require_non_empty "Enter Jellyfin API Key")"
    ;;
  plex)
    MEDIA_API_KEY="$(require_non_empty "Enter Plex X-Plex-Token")"
    ;;
  emby)
    MEDIA_API_KEY="$(require_non_empty "Enter Emby API Key")"
    ;;
esac

############################################
# FRONTEND ORIGIN
############################################
banner "Frontend Origin"
ORIGIN="$DEFAULT_ORIGIN"
read -rp "Using reverse proxy? (y/N): " USE_PROXY
[[ "${USE_PROXY,,}" == "y" ]] && ORIGIN="$(require_url "Public frontend URL")"
ok "ORIGIN=$ORIGIN"

############################################
# DOWNLOADER SELECTION (REQUIRED)
############################################
banner "Downloader Selection (REQUIRED)"
echo "Choose ONE downloader service:"
echo "1) Real-Debrid"
echo "2) All-Debrid"
echo "3) Debrid-Link"
read -rp "Select ONE: " DL_SEL

RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED=false
RIVEN_DOWNLOADERS_ALL_DEBRID_ENABLED=false
RIVEN_DOWNLOADERS_DEBRID_LINK_ENABLED=false
RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY=""
RIVEN_DOWNLOADERS_ALL_DEBRID_API_KEY=""
RIVEN_DOWNLOADERS_DEBRID_LINK_API_KEY=""

case "$DL_SEL" in
  1) RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED=true
     RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY="$(require_non_empty "Enter Real-Debrid API Token")" ;;
  2) RIVEN_DOWNLOADERS_ALL_DEBRID_ENABLED=true
     RIVEN_DOWNLOADERS_ALL_DEBRID_API_KEY="$(require_non_empty "Enter All-Debrid API Key")" ;;
  3) RIVEN_DOWNLOADERS_DEBRID_LINK_ENABLED=true
     RIVEN_DOWNLOADERS_DEBRID_LINK_API_KEY="$(require_non_empty "Enter Debrid-Link API Key")" ;;
  *) fail "Downloader selection REQUIRED" ;;
esac

############################################
# SCRAPER SELECTION (REQUIRED)
############################################
banner "Scraper Selection (REQUIRED)"
echo "Choose ONE scraping backend:"
echo "1) Torrentio   (No config required)"
echo "2) Prowlarr    (Local instance only)"
echo "3) Comet       (Public or self-hosted)"
echo "4) Jackett     (Local instance only)"
echo "5) Zilean      (Public or self-hosted)"
read -rp "Select ONE: " SCR_SEL

RIVEN_SCRAPING_TORRENTIO_ENABLED=false
RIVEN_SCRAPING_PROWLARR_ENABLED=false
RIVEN_SCRAPING_COMET_ENABLED=false
RIVEN_SCRAPING_JACKETT_ENABLED=false
RIVEN_SCRAPING_ZILEAN_ENABLED=false

RIVEN_SCRAPING_PROWLARR_URL=""
RIVEN_SCRAPING_PROWLARR_API_KEY=""
RIVEN_SCRAPING_COMET_URL=""
RIVEN_SCRAPING_JACKETT_URL=""
RIVEN_SCRAPING_JACKETT_API_KEY=""
RIVEN_SCRAPING_ZILEAN_URL=""

case "$SCR_SEL" in
  1) RIVEN_SCRAPING_TORRENTIO_ENABLED=true ;;
  2) RIVEN_SCRAPING_PROWLARR_ENABLED=true
     RIVEN_SCRAPING_PROWLARR_URL="$(require_url "Enter Prowlarr URL")"
     RIVEN_SCRAPING_PROWLARR_API_KEY="$(read_masked_non_empty "Enter Prowlarr API Key")" ;;
  3) RIVEN_SCRAPING_COMET_ENABLED=true
     RIVEN_SCRAPING_COMET_URL="$(require_url "Enter Comet base URL")" ;;
  4) RIVEN_SCRAPING_JACKETT_ENABLED=true
     RIVEN_SCRAPING_JACKETT_URL="$(require_url "Enter Jackett URL")"
     RIVEN_SCRAPING_JACKETT_API_KEY="$(read_masked_non_empty "Enter Jackett API Key")" ;;
  5) RIVEN_SCRAPING_ZILEAN_ENABLED=true
     RIVEN_SCRAPING_ZILEAN_URL="$(require_url "Enter Zilean base URL")" ;;
  *) fail "Scraper selection REQUIRED" ;;
esac

############################################
# SECRETS
############################################
POSTGRES_PASSWORD="$(openssl rand -hex 24)"
AUTH_SECRET="$(openssl rand -base64 32)"

set +o pipefail
BACKEND_API_KEY="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
set -o pipefail
[[ "${#BACKEND_API_KEY}" -eq 32 ]] || fail "BACKEND_API_KEY generation failed"

############################################
# MEDIA UPDATER FLAGS
############################################
RIVEN_UPDATERS_JELLYFIN_ENABLED=false
RIVEN_UPDATERS_PLEX_ENABLED=false
RIVEN_UPDATERS_EMBY_ENABLED=false
RIVEN_UPDATERS_JELLYFIN_API_KEY=""
RIVEN_UPDATERS_PLEX_TOKEN=""
RIVEN_UPDATERS_EMBY_API_KEY=""

case "$MEDIA_PROFILE" in
  jellyfin) RIVEN_UPDATERS_JELLYFIN_ENABLED=true; RIVEN_UPDATERS_JELLYFIN_API_KEY="$MEDIA_API_KEY" ;;
  plex)     RIVEN_UPDATERS_PLEX_ENABLED=true;     RIVEN_UPDATERS_PLEX_TOKEN="$MEDIA_API_KEY" ;;
  emby)     RIVEN_UPDATERS_EMBY_ENABLED=true;     RIVEN_UPDATERS_EMBY_API_KEY="$MEDIA_API_KEY" ;;
esac

############################################
# WRITE .env
############################################
banner ".env Generation"

cat > .env <<EOF
TZ="$TZ_SELECTED"
ORIGIN="$ORIGIN"
MEDIA_PROFILE="$MEDIA_PROFILE"

POSTGRES_DB="riven"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"

BACKEND_API_KEY="$BACKEND_API_KEY"
AUTH_SECRET="$AUTH_SECRET"

# Auto-adjusted paths (WSL will use /mnt/c/riven/... by default)
RIVEN_UPDATERS_LIBRARY_PATH="$BACKEND_PATH"
RIVEN_UPDATERS_UPDATER_INTERVAL="120"

RIVEN_UPDATERS_JELLYFIN_ENABLED="$RIVEN_UPDATERS_JELLYFIN_ENABLED"
RIVEN_UPDATERS_JELLYFIN_API_KEY="$RIVEN_UPDATERS_JELLYFIN_API_KEY"
RIVEN_UPDATERS_JELLYFIN_URL="http://jellyfin:8096"

RIVEN_UPDATERS_PLEX_ENABLED="$RIVEN_UPDATERS_PLEX_ENABLED"
RIVEN_UPDATERS_PLEX_TOKEN="$RIVEN_UPDATERS_PLEX_TOKEN"
RIVEN_UPDATERS_PLEX_URL="http://plex:32400"

RIVEN_UPDATERS_EMBY_ENABLED="$RIVEN_UPDATERS_EMBY_ENABLED"
RIVEN_UPDATERS_EMBY_API_KEY="$RIVEN_UPDATERS_EMBY_API_KEY"
RIVEN_UPDATERS_EMBY_URL="http://emby:8097"

RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED="$RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED"
RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY="$RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY"

RIVEN_DOWNLOADERS_ALL_DEBRID_ENABLED="$RIVEN_DOWNLOADERS_ALL_DEBRID_ENABLED"
RIVEN_DOWNLOADERS_ALL_DEBRID_API_KEY="$RIVEN_DOWNLOADERS_ALL_DEBRID_API_KEY"

RIVEN_DOWNLOADERS_DEBRID_LINK_ENABLED="$RIVEN_DOWNLOADERS_DEBRID_LINK_ENABLED"
RIVEN_DOWNLOADERS_DEBRID_LINK_API_KEY="$RIVEN_DOWNLOADERS_DEBRID_LINK_API_KEY"

RIVEN_SCRAPING_TORRENTIO_ENABLED="$RIVEN_SCRAPING_TORRENTIO_ENABLED"

RIVEN_SCRAPING_PROWLARR_ENABLED="$RIVEN_SCRAPING_PROWLARR_ENABLED"
RIVEN_SCRAPING_PROWLARR_URL="$RIVEN_SCRAPING_PROWLARR_URL"
RIVEN_SCRAPING_PROWLARR_API_KEY="$RIVEN_SCRAPING_PROWLARR_API_KEY"

RIVEN_SCRAPING_COMET_ENABLED="$RIVEN_SCRAPING_COMET_ENABLED"
RIVEN_SCRAPING_COMET_URL="$RIVEN_SCRAPING_COMET_URL"

RIVEN_SCRAPING_JACKETT_ENABLED="$RIVEN_SCRAPING_JACKETT_ENABLED"
RIVEN_SCRAPING_JACKETT_URL="$RIVEN_SCRAPING_JACKETT_URL"
RIVEN_SCRAPING_JACKETT_API_KEY="$RIVEN_SCRAPING_JACKETT_API_KEY"

RIVEN_SCRAPING_ZILEAN_ENABLED="$RIVEN_SCRAPING_ZILEAN_ENABLED"
RIVEN_SCRAPING_ZILEAN_URL="$RIVEN_SCRAPING_ZILEAN_URL"
EOF

chmod 600 .env || true
ok ".env written: $INSTALL_DIR/.env"

############################################
# START RIVEN (WITH OPTIONAL WSL OVERRIDE)
############################################
banner "Starting Riven"

RIVEN_COMPOSE_ARGS=(-f docker-compose.yml)
if [[ "$USE_WSL_OVERRIDE" == true ]]; then
  RIVEN_COMPOSE_ARGS+=(-f docker-compose.wsl.override.yml)
  warn "WSL override active: docker-compose.wsl.override.yml"
fi

docker compose "${RIVEN_COMPOSE_ARGS[@]}" up -d
ok "Riven started"

############################################
# INSTALL SUMMARY
############################################
banner "INSTALL COMPLETE"

echo "📁 Paths"
echo "  • Install Dir:        $INSTALL_DIR"
echo "  • Backend Path:       $BACKEND_PATH"
echo "  • Mount Path:         $MOUNT_PATH"
echo

if [[ "$IS_WSL" == true ]]; then
  echo "⚠️  WSL MODE NOTES"
  echo "  • Docker Desktop detected: $docker_desktop_detected"
  echo "  • systemd unit installs skipped where not supported"
  echo "  • rshared mounts skipped (WSL limitation)"
  echo "  • WSL compose override used: $USE_WSL_OVERRIDE"
  echo
fi

ok "Riven is ready 🚀"
