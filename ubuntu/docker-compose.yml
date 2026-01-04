#!/usr/bin/env bash
set -e

############################################
# CONFIG
############################################
INSTALL_DIR="/opt/riven"
COMPOSE_URL="https://raw.githubusercontent.com/AquaHorizonGaming/distributables/main/ubuntu/docker-compose.yml"
FRONTEND_PORT="3000"

############################################
# OUTPUT HELPERS
############################################
banner() {
  echo
  echo "========================================"
  echo " $1"
  echo "========================================"
}
ok()   { echo "[✔] $1"; }
warn() { echo "[!] $1"; }
fail() { echo "[✖] $1"; exit 1; }

############################################
# PRECHECKS
############################################
[ "$(id -u)" -eq 0 ] || fail "Run this script as root (sudo)"
. /etc/os-release || fail "Cannot detect OS"
[ "$ID" = "ubuntu" ] || fail "Ubuntu is required"

############################################
# TIMEZONE (INTERACTIVE, SAFE)
############################################
banner "Timezone Configuration"

TZ_DETECTED="$(timedatectl show --property=Timezone --value 2>/dev/null || echo UTC)"
echo "Detected timezone: $TZ_DETECTED"

if [ -t 0 ]; then
  read -rp "Press ENTER to accept or type another (e.g. America/New_York): " TZ_INPUT
  TZ_SELECTED="${TZ_INPUT:-$TZ_DETECTED}"
else
  TZ_SELECTED="$TZ_DETECTED"
fi

timedatectl set-timezone "$TZ_SELECTED"
ok "Timezone set to $TZ_SELECTED"

############################################
# DEPENDENCIES (ONLY IF MISSING)
############################################
banner "Dependency Check"

REQUIRED_CMDS=(curl openssl gpg)
MISSING=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null || MISSING+=("$cmd")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  warn "Installing missing packages: ${MISSING[*]}"
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl
else
  ok "All required system commands detected — skipping apt"
fi

############################################
# DOCKER INSTALL (ONLY IF MISSING)
############################################
banner "Docker"

if ! command -v docker >/dev/null; then
  warn "Docker not detected — installing"

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
else
  ok "Docker already installed"
fi

############################################
# DOCKER IPv4 ONLY (NO SYSTEM IPV6 CHANGES)
############################################
banner "Docker IPv4 Configuration"

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
  "ipv6": false,
  "dns": ["8.8.8.8", "1.1.1.1"]
}
EOF

systemctl restart docker
ok "Docker configured to use IPv4 only"

############################################
# FILESYSTEM LAYOUT
############################################
banner "Filesystem Setup"

mkdir -p \
  /mnt/riven/backend \
  /mnt/riven/mount \
  "$INSTALL_DIR"

chown -R 1000:1000 /mnt/riven || true

ok "Backend data path: /mnt/riven/backend"
ok "Media mount path:  /mnt/riven/mount"
ok "Compose directory: $INSTALL_DIR"

############################################
# MOUNT PROPAGATION (rshared)
############################################
banner "Mount Propagation (rshared)"

cat >/etc/systemd/system/riven-bind-shared.service <<EOF
[Unit]
Description=Make Riven mount bind shared
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mount --bind /mnt/riven/mount /mnt/riven/mount
ExecStart=/usr/bin/mount --make-rshared /mnt/riven/mount
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now riven-bind-shared.service
ok "Shared mount enabled"

############################################
# RIVEN DEPLOYMENT
############################################
banner "Riven Deployment"

cd "$INSTALL_DIR"
curl -fsSL "$COMPOSE_URL" -o docker-compose.yml || fail "Failed to download docker-compose.yml"
ok "docker-compose.yml downloaded"

if [ ! -f .env ]; then
  warn ".env not found — generating one (SAVE THIS FILE)"
  cat > .env <<EOF
TZ=$TZ_SELECTED
POSTGRES_DB=riven
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$(openssl rand -hex 24)
BACKEND_API_KEY=$(openssl rand -hex 32)
AUTH_SECRET=$(openssl rand -hex 32)
EOF
else
  ok ".env already exists — keeping it"
fi

docker compose pull
docker compose up -d

############################################
# VERIFY + RECOVER CONTAINERS
############################################
banner "Container Health Check"

EXPECTED_CONTAINERS=(
  riven-db
  riven
  riven-frontend
)

sleep 5

for c in "${EXPECTED_CONTAINERS[@]}"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    warn "Container $c not running — attempting restart"
    docker compose up -d "$c" || warn "Failed to start $c"
  else
    ok "Container $c is running"
  fi
done

############################################
# FINAL OUTPUT
############################################
SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[ -z "$SERVER_IP" ] && SERVER_IP="SERVER_IP"

banner "IMPORTANT NEXT STEPS"

echo "• Edit Riven configuration:"
echo "  /mnt/riven/backend/settings.json"
echo
echo "• Movies / TV / Anime will appear in:"
echo "  /mnt/riven/mount"
echo
echo "• Docker Compose location:"
echo "  /opt/riven/docker-compose.yml"
echo
echo "• Frontend is live at:"
echo "  http://${SERVER_IP}:${FRONTEND_PORT}"
echo
ok "Riven installation complete"
