# 🧊 Riven Proxmox LXC Installer (Docker-based)

This installer deploys **Riven** inside an **unprivileged Debian 12 LXC** on Proxmox, fully containerized with Docker.
It is designed to be **safe, repeatable, and beginner-proof**, while still supporting advanced features like GPU passthrough and multiple media servers.

---

## ▶️ Run on Proxmox Host

Run this **directly on the Proxmox host shell**:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/AquaHorizonGaming/Riven-Scripts/main/proxmox/install.sh)"
```

The installer is fully interactive and will guide you through all required selections.

---

## 🛠 What This Installer Does

### LXC Creation & System Setup
- Creates an **unprivileged Debian 12 LXC**
- Enables required container features:
  - nesting
  - keyctl
  - fuse
- Passes `/dev/fuse` into the container (required for Riven VFS)
- Optionally passes `/dev/dri` for **GPU acceleration**

### Docker Environment
- Installs **Docker Engine**
- Installs **Docker Compose plugin**
- Applies sane defaults for Docker-in-LXC operation

### Riven Deployment
- Deploys:
  - Riven backend
  - Riven frontend
  - PostgreSQL database
- Uses a unified filesystem layout under `/srv/riven`

### Media Server Support (Optional)
Media servers are included via Docker Compose **profiles**:
- Jellyfin
- Plex
- Emby

You can enable one or more at any time.

---

## 🌐 Access URLs

Once the container is running:

- **Riven Backend:**  
  `http://<CT-IP>:8080`

- **Riven Frontend:**  
  `http://<CT-IP>:3000`

### Get the Container IP
From the Proxmox host:
```bash
pct exec <CTID> -- hostname -I
```

---

## ⚠️ Required Configuration (IMPORTANT)

🚨 **Riven will NOT function without a configured media server** 🚨

You **must** edit the Riven configuration before first use.

### Edit configuration inside the container
```bash
/srv/riven/backend/settings.json
```

Configure **at least one** media server (Jellyfin, Plex, or Emby).

### Restart Riven after editing
```bash
pct exec <CTID> -- docker restart riven
```

---

## 🎬 Optional Media Servers

To enable a media server, run **inside the container**:

```bash
cd /srv/riven/app

docker compose --profile jellyfin up -d
docker compose --profile plex up -d
docker compose --profile emby up -d
```

You may enable **only one** or **multiple**, depending on your setup.

---

## 🔄 Upgrade Riven

To update Riven and its containers, run **inside the container**:

```bash
/srv/riven/app/upgrade.sh
```

This safely:
- Stops containers
- Pulls updates
- Restarts services in the correct order

---

## ✅ Summary

- Fully automated Proxmox LXC deployment
- Unprivileged, secure-by-default container
- Docker-based, easy to upgrade
- Optional GPU support
- Optional Jellyfin / Plex / Emby integration
- Unified filesystem layout for easy backups
