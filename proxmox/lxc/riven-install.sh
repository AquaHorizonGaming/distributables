#!/usr/bin/env bash
set -euo pipefail

echo "== Riven Docker Install (inside LXC) =="

INSTALL_DIR="/opt/riven"
DATA_DIR="/mnt/riven"
BACKEND_DIR="$DATA_DIR/backend"
MOUNT_DIR="$DATA_DIR/mount"

RIVEN_UID=1000
RIVEN_GID=1000

mkdir -p "$INSTALL_DIR"
mkdir -p "$BACKEND_DIR" "$MOUNT_DIR"
chown -R "$RIVEN_UID:$RIVEN_GID" "$DATA_DIR"

# Ensure bind + rshared mount (inside CT)
if ! mountpoint -q "$MOUNT_DIR"; then
  mount --bind "$MOUNT_DIR" "$MOUNT_DIR"
fi
mount --make-rshared "$MOUNT_DIR"

PROP="$(findmnt -T "$MOUNT_DIR" -o PROPAGATION -n || true)"
if [[ "$PROP" != "shared" && "$PROP" != "rshared" ]]; then
  echo "ERROR: $MOUNT_DIR is not shared (got: $PROP)"
  exit 1
fi

# Persist on boot (inside CT) - ensures rshared is set before docker starts
cat >/etc/systemd/system/riven-bind-shared.service <<EOF
[Unit]
Description=Make Riven mount bind shared
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mount --bind $MOUNT_DIR $MOUNT_DIR
ExecStart=/usr/bin/mount --make-rshared $MOUNT_DIR
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now riven-bind-shared.service

cd "$INSTALL_DIR"

# Generate secrets (.env) ONLY if not exists
if [[ ! -f .env ]]; then
  POSTGRES_DB="riven"
  POSTGRES_USER="riven_$(openssl rand -hex 4)"
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  BACKEND_API_KEY="$(openssl rand -hex 16)"  # 32 chars
  AUTH_SECRET="$(openssl rand -base64 32)"
  TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"

  cat > .env <<EOF
TZ=$TZ

POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

BACKEND_API_KEY=$BACKEND_API_KEY
AUTH_SECRET=$AUTH_SECRET

DATABASE_URL=/riven/data/riven.db
BACKEND_URL=http://riven:8080
EOF
fi

# Install compose + upgrade script
cp /root/docker-compose.yml "$INSTALL_DIR/docker-compose.yml"
cp /root/upgrade.sh "$INSTALL_DIR/upgrade.sh"
chmod +x "$INSTALL_DIR/upgrade.sh"

echo "Starting containers..."
docker compose up -d

# Print creds
POSTGRES_DB="$(grep -E '^POSTGRES_DB=' .env | cut -d= -f2-)"
POSTGRES_USER="$(grep -E '^POSTGRES_USER=' .env | cut -d= -f2-)"
POSTGRES_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Riven stack deployed inside LXC"
echo
echo "📦 PostgreSQL credentials (SAVE THESE):"
echo "  Database : $POSTGRES_DB"
echo "  User     : $POSTGRES_USER"
echo "  Password : $POSTGRES_PASSWORD"
echo
echo "🚨 REQUIRED CONFIGURATION 🚨"
echo "⚠️  YOU MUST CONFIGURE A MEDIA SERVER OR RIVEN WONT START"
echo
echo
echo "Edit:"
echo "  $DATA_DIR/backend/settings.json"
echo
echo "After configuring, restart:"
echo "  docker restart riven"
echo
echo
echo "🚨  YOU MUST SELECT A MEDIA SERVER OR RIVEN WONT START 🚨"
echo
echo "Optional media servers:"
echo "  docker compose --profile jellyfin up -d"
echo "  docker compose --profile plex up -d"
echo "  docker compose --profile emby up -d"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
