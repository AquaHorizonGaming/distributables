#!/usr/bin/env bash
set -euo pipefail

# Riven Proxmox LXC Installer (Docker-based)
# Run on Proxmox host as root:
#   bash install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_DIR="$SCRIPT_DIR/lxc"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $1"; exit 1; }; }

require_cmd pveversion
require_cmd pct
require_cmd pvesm

# --- Proxmox version check (8.1+) ---
PVE_VER_RAW="$(pveversion | head -n1)"
PVE_VER="$(echo "$PVE_VER_RAW" | sed -nE 's/.*pve-manager\/([0-9]+)\.([0-9]+).*/\1.\2/p')"
if [[ -z "${PVE_VER}" ]]; then
  echo "WARNING: Could not parse Proxmox version from: $PVE_VER_RAW"
else
  MAJ="${PVE_VER%.*}"; MIN="${PVE_VER#*.}"
  if (( MAJ < 8 )) || (( MAJ == 8 && MIN < 1 )); then
    echo "ERROR: Proxmox 8.1+ required. Detected: $PVE_VER_RAW"
    exit 1
  fi
fi

echo "== Riven Proxmox LXC (Docker) Installer =="

# --- Defaults ---
DEFAULT_CTID=""
while :; do
  CANDIDATE=$(( (RANDOM % 900) + 100 ))
  if ! pct status "$CANDIDATE" >/dev/null 2>&1; then DEFAULT_CTID="$CANDIDATE"; break; fi
done

read -rp "Container ID (CTID) [${DEFAULT_CTID}]: " CTID
CTID="${CTID:-$DEFAULT_CTID}"

if pct status "$CTID" >/dev/null 2>&1; then
  echo "ERROR: CTID $CTID already exists."
  exit 1
fi

read -rp "Hostname [riven]: " HOSTNAME
HOSTNAME="${HOSTNAME:-riven}"

read -rp "Rootfs disk size (GB) [16]: " DISK_GB
DISK_GB="${DISK_GB:-16}"

read -rp "Memory (MB) [4096]: " MEM_MB
MEM_MB="${MEM_MB:-4096}"

read -rp "CPU cores [4]: " CORES
CORES="${CORES:-4}"

# Storage for rootfs (default: first local-lvm, else local)
DEFAULT_STORAGE="$(pvesm status | awk 'NR>1{print $1}' | head -n1)"
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local}"
read -rp "Proxmox storage for rootfs/template [${DEFAULT_STORAGE}]: " STORAGE
STORAGE="${STORAGE:-$DEFAULT_STORAGE}"

# Network: DHCP by default on vmbr0
read -rp "Bridge [vmbr0]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"
read -rp "Network config (dhcp or static like 192.168.1.50/24,gw=192.168.1.1) [dhcp]: " NETCFG
NETCFG="${NETCFG:-dhcp}"

# Choose static or DHCP formatting for pct
NET0="name=eth0,bridge=${BRIDGE},ip=${NETCFG}"
if [[ "${NETCFG}" == "dhcp" ]]; then
  NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

# Optional: mount host path into LXC for media VFS (recommended)
echo
echo "Optional: bind-mount a host path into the LXC as /mnt/riven (recommended for persistence)."
echo "Examples:"
echo "  /srv/riven     (ZFS/LVM dataset)"
echo "  /mnt/rivenhost (separate disk)"
read -rp "Host path to mount into CT as /mnt/riven (leave blank to use CT disk only): " HOST_RIVEN_PATH

# GPU passthrough (Intel/AMD /dev/dri; NVIDIA users may still want /dev/dri for iGPU)
GPU_ENABLE="no"
if [[ -d /dev/dri ]]; then
  read -rp "Detected /dev/dri on host. Pass GPU device into LXC? [Y/n]: " GPU_ANS
  GPU_ANS="${GPU_ANS:-Y}"
  if [[ "${GPU_ANS}" =~ ^[Yy]$ ]]; then GPU_ENABLE="yes"; fi
else
  read -rp "No /dev/dri detected on host. Pass GPU anyway? [y/N]: " GPU_ANS
  GPU_ANS="${GPU_ANS:-N}"
  if [[ "${GPU_ANS}" =~ ^[Yy]$ ]]; then GPU_ENABLE="yes"; fi
fi

# --- Create LXC ---
bash "$LXC_DIR/lxc-create.sh" \
  --ctid "$CTID" \
  --hostname "$HOSTNAME" \
  --storage "$STORAGE" \
  --disk-gb "$DISK_GB" \
  --mem-mb "$MEM_MB" \
  --cores "$CORES" \
  --net0 "$NET0" \
  --host-riven-path "$HOST_RIVEN_PATH" \
  --gpu "$GPU_ENABLE"

# --- Push scripts into CT ---
echo "Pushing installer files into CT $CTID..."
pct push "$CTID" "$LXC_DIR/lxc-bootstrap.sh" /root/lxc-bootstrap.sh -perms 0755
pct push "$CTID" "$LXC_DIR/riven-install.sh" /root/riven-install.sh -perms 0755
pct push "$CTID" "$LXC_DIR/docker-compose.yml" /root/docker-compose.yml -perms 0644
pct push "$CTID" "$LXC_DIR/upgrade.sh" /root/upgrade.sh -perms 0755

# --- Bootstrap docker ---
echo "Bootstrapping Docker inside CT..."
pct exec "$CTID" -- bash /root/lxc-bootstrap.sh

# --- Install & run Riven stack ---
echo "Installing and starting Riven stack inside CT..."
pct exec "$CTID" -- bash /root/riven-install.sh

# --- Print access info ---
echo
echo "✅ Done."
echo "Find CT IP via: pct exec $CTID -- hostname -I"
echo "Backend  : http://<CT-IP>:8080"
echo "Frontend : http://<CT-IP>:3000"
echo
echo "To view logs:"
echo "  pct exec $CTID -- docker logs -f riven"
echo "  pct exec $CTID -- docker logs -f riven-db"
