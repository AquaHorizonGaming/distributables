#!/usr/bin/env bash
set -euo pipefail

############################################
# CONSTANTS (MUST MATCH INSTALLER)
############################################
INSTALL_DIR="/opt/riven"
RIVEN_ROOT="/mnt/riven"
BACKEND_PATH="$RIVEN_ROOT/backend"
MOUNT_PATH="$RIVEN_ROOT/mount"
LOG_DIR="/tmp/logs/riven"

SERVICE_NAME="riven-bind-shared.service"

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
# CONFIRMATION
############################################
banner "RIVEN UNINSTALLER"

echo "⚠️  WARNING"
echo "This will COMPLETELY REMOVE:"
echo "  • Riven containers"
echo "  • Media containers"
echo "  • systemd rshared mount unit"
echo "  • $INSTALL_DIR"
echo "  • $RIVEN_ROOT (backend + mount)"
echo "  • Logs in $LOG_DIR"
echo
read -rp "Type UNINSTALL to continue: " CONFIRM
[[ "$CONFIRM" == "UNINSTALL" ]] || fail "Aborted by user"

############################################
# STOP CONTAINERS
############################################
banner "Stopping Containers"

if command -v docker >/dev/null; then
  if [[ -d "$INSTALL_DIR" ]]; then
    cd "$INSTALL_DIR"

    [[ -f docker-compose.yml ]] \
      && docker compose down --volumes --remove-orphans || true

    [[ -f docker-compose.media.yml ]] \
      && docker compose -f docker-compose.media.yml down --volumes --remove-orphans || true
  fi
else
  warn "Docker not installed — skipping container shutdown"
fi

ok "Containers stopped"

############################################
# REMOVE SYSTEMD MOUNT UNIT
############################################
banner "Removing rshared mount service"

if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
  systemctl disable --now "$SERVICE_NAME" || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reexec
  systemctl daemon-reload
  ok "systemd mount unit removed"
else
  warn "No rshared mount service found"
fi

############################################
# UNMOUNT RIVEN MOUNT (SAFE)
############################################
banner "Unmounting Riven mount"

if mountpoint -q "$MOUNT_PATH"; then
  umount -R "$MOUNT_PATH" || warn "Failed to fully unmount $MOUNT_PATH"
  ok "Unmounted $MOUNT_PATH"
else
  warn "$MOUNT_PATH is not mounted"
fi

############################################
# REMOVE BACKEND + MOUNT PATHS
############################################
banner "Removing Riven filesystem"

rm -rf "$BACKEND_PATH"
ok "Removed $BACKEND_PATH"

rm -rf "$MOUNT_PATH"
ok "Removed $MOUNT_PATH"

############################################
# REMOVE /mnt/riven IF EMPTY
############################################
if [[ -d "$RIVEN_ROOT" ]] && [[ -z "$(ls -A "$RIVEN_ROOT")" ]]; then
  rmdir "$RIVEN_ROOT"
  ok "Removed empty $RIVEN_ROOT"
else
  warn "$RIVEN_ROOT not empty — leaving in place"
fi

############################################
# REMOVE INSTALL DIR + LOGS
############################################
banner "Removing install artifacts"

rm -rf "$INSTALL_DIR"
ok "Removed $INSTALL_DIR"

rm -rf "$LOG_DIR"
ok "Removed logs"

############################################
# DOCKER CLEANUP (SAFE)
############################################
banner "Docker Cleanup"

if command -v docker >/dev/null; then
  docker network prune -f || true
  docker volume prune -f || true
  ok "Docker cleanup complete"
else
  warn "Docker not installed — skipping cleanup"
fi

############################################
# OPTIONAL: DOCKER REMOVAL
############################################
banner "Optional Docker Removal"

read -rp "Remove Docker entirely? (y/N): " REMOVE_DOCKER
if [[ "${REMOVE_DOCKER,,}" == "y" ]]; then
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
  apt-get autoremove -y
  rm -rf /var/lib/docker /var/lib/containerd
  ok "Docker fully removed"
else
  ok "Docker preserved"
fi

############################################
# FINAL SUMMARY
############################################
banner "UNINSTALL COMPLETE"

echo "✔ Riven fully removed"
echo "✔ /mnt/riven cleaned"
echo "✔ systemd mount removed"
echo "✔ Containers removed"
echo
echo "System restored to pre-install state."

ok "Cleanup complete 🧹"