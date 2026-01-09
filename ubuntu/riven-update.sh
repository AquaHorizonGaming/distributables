#!/usr/bin/env bash
set -euo pipefail

############################################
# CONSTANTS
############################################
INSTALL_DIR="/opt/riven"
MEDIA_COMPOSE="docker-compose.media.yml"
RIVEN_COMPOSE="docker-compose.yml"

############################################
# HELPERS
############################################
banner(){ echo -e "\n========================================\n $1\n========================================"; }
ok(){ echo "[✔] $1"; }
warn(){ echo "[!] $1"; }
fail(){ echo "[✖] $1"; exit 1; }

############################################
# ROOT CHECK
############################################
[[ "$(id -u)" -eq 0 ]] || fail "Run with sudo"

############################################
# DOCKER CHECK
############################################
banner "Docker Check"

command -v docker >/dev/null \
  || fail "Docker is not installed"

docker info >/dev/null 2>&1 \
  || fail "Docker is installed but not running"

docker compose version >/dev/null 2>&1 \
  || fail "Docker Compose plugin is missing"

ok "Docker and Docker Compose are available"

############################################
# PRE-FLIGHT CHECKS
############################################
banner "Riven Update"

[[ -d "$INSTALL_DIR" ]] \
  || fail "Riven is not installed ($INSTALL_DIR missing)"

cd "$INSTALL_DIR"

[[ -f "$RIVEN_COMPOSE" ]] \
  || fail "Missing $RIVEN_COMPOSE"

[[ -f ".env" ]] \
  || fail "Missing .env file"

ok "Riven installation detected"

############################################
# MEDIA SERVER PROMPT
############################################
banner "Media Server Update"

UPDATE_MEDIA=false
read -rp "Update media server containers too? (y/N): " ANSWER
[[ "${ANSWER,,}" == "y" ]] && UPDATE_MEDIA=true

############################################
# UPDATE RIVEN
############################################
banner "Updating Riven"

docker compose pull
docker compose up -d

ok "Riven updated successfully"

############################################
# UPDATE MEDIA SERVER (OPTIONAL)
############################################
if [[ "$UPDATE_MEDIA" == "true" ]]; then
  banner "Updating Media Server"

  if [[ -f "$MEDIA_COMPOSE" ]]; then
    docker compose -f "$MEDIA_COMPOSE" pull
    docker compose -f "$MEDIA_COMPOSE" up -d
    ok "Media server updated"
  else
    warn "Media compose file not found — skipping media update"
  fi
else
  ok "Media server update skipped"
fi

############################################
# OPTIONAL IMAGE CLEANUP
############################################
banner "Optional Docker Image Cleanup"

read -rp "Prune unused Docker images? (y/N): " PRUNE
if [[ "${PRUNE,,}" == "y" ]]; then
  docker image prune
  ok "Unused images pruned"
else
  ok "Image cleanup skipped"
fi

############################################
# SUMMARY
############################################
banner "UPDATE COMPLETE"

echo "✔ Riven updated"
[[ "$UPDATE_MEDIA" == "true" ]] \
  && echo "✔ Media server updated" \
  || echo "• Media server unchanged"

echo
echo "No volumes, mounts, or configuration files were modified."

ok "Update finished 🚀"