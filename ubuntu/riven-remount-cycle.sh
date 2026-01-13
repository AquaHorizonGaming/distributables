#!/usr/bin/env bash
set -euo pipefail

############################################
# REQUIRE ROOT
############################################
if [[ "$EUID" -ne 0 ]]; then
  echo
  echo "[✖] This script must be run with sudo"
  echo "    Example:"
  echo "    sudo curl -fsSL https://raw.githubusercontent.com/AquaHorizonGaming/riven-scripts/main/ubuntu/riven-remount-cycle.sh | sudo bash"
  echo
  exit 1
fi

############################################
# DEFAULTS
############################################
RIVEN_CONTAINER="riven"
DEFAULT_MOUNT="/mnt/riven/mount"

UNMOUNT_RETRIES=6
WAIT_BETWEEN=2
MOUNT_WAIT=30

############################################
# HELPERS
############################################
log()  { echo -e "\n[+] $1"; }
warn() { echo -e "[!] $1"; }
fail() { echo -e "\n[✖] $1"; exit 1; }

is_mounted() {
  findmnt -T "$MOUNT_PATH" >/dev/null 2>&1
}

############################################
# MOUNT PATH PROMPT
############################################
echo
read -rp "Enter mount path [${DEFAULT_MOUNT}]: " MOUNT_PATH
MOUNT_PATH="${MOUNT_PATH:-$DEFAULT_MOUNT}"

log "Using mount path: $MOUNT_PATH"

############################################
# MEDIA SERVER SELECTION
############################################
echo
echo "Select your media server:"
echo "1) Plex"
echo "2) Jellyfin"
echo "3) Emby"
echo "4) Custom container name"

read -rp "Enter choice [1-4]: " MEDIA_CHOICE

case "$MEDIA_CHOICE" in
  1) MEDIA_CONTAINER="plex" ;;
  2) MEDIA_CONTAINER="jellyfin" ;;
  3) MEDIA_CONTAINER="emby" ;;
  4)
     read -rp "Enter Docker container name: " MEDIA_CONTAINER
     ;;
  *)
     fail "Invalid selection"
     ;;
esac

log "Using media container: $MEDIA_CONTAINER"

############################################
# 1. STOP CONTAINERS
############################################
log "Stopping Riven container"
docker stop "$RIVEN_CONTAINER" || true

log "Stopping media container"
docker stop "$MEDIA_CONTAINER" || true

############################################
# 2. UNMOUNT LOOP (STRICT)
############################################
log "Ensuring mount is fully released"

for attempt in $(seq 1 $UNMOUNT_RETRIES); do
  if ! is_mounted; then
    log "Mount is gone"
    break
  fi

  warn "Unmount attempt $attempt"
  umount "$MOUNT_PATH" || true
  sleep "$WAIT_BETWEEN"
done

############################################
# 3. FINAL UNMOUNT CHECK
############################################
if is_mounted; then
  fail "Mount still present after ${UNMOUNT_RETRIES} attempts"
fi

log "Unmount verified"

############################################
# 4. START RIVEN
############################################
log "Starting Riven container"
docker start "$RIVEN_CONTAINER"

############################################
# 5. WAIT FOR REMOUNT
############################################
log "Waiting for Riven mount"

for i in $(seq 1 $MOUNT_WAIT); do
  if is_mounted; then
    log "Mount active"
    break
  fi
  sleep 1
done

if ! is_mounted; then
  fail "Riven did not remount"
fi

############################################
# 6. START MEDIA
############################################
log "Starting media container"
docker start "$MEDIA_CONTAINER"

############################################
# 7. RESTART MEDIA (POST-MOUNT SAFETY)
############################################
log "Restarting media container after mount stabilization"
sleep 5
docker restart "$MEDIA_CONTAINER"

log "Riven remount cycle complete ✔"