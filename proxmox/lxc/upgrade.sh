#!/usr/bin/env bash
set -e

cd /opt/riven

echo "Stopping Riven stack..."
docker compose down

echo "Pulling latest images..."
docker compose pull

echo "Starting Riven stack..."
docker compose up -d --remove-orphans

echo "Cleaning old images..."
docker image prune -f

echo "Upgrade complete"
