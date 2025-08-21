#!/usr/bin/env bash
set -euo pipefail

# init.sh - prepare glpi data directories and .env
# Usage: ./init.sh

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
# Resolve symlink to real path if possible
if command -v readlink >/dev/null 2>&1; then
  SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
echo "Project root: $ROOT_DIR"

# We will mount GLPI application storage and MariaDB data under ./storage and ./data
# Define absolute host paths inside the project folder
GLPI_STORAGE_DIR="$ROOT_DIR/data/glpi"
GLPI_DB_DIR="$ROOT_DIR/data/mariadb"

mkdir -p "$GLPI_STORAGE_DIR" "$GLPI_DB_DIR"
echo "Ensured directories:"
echo " - $GLPI_STORAGE_DIR"
echo " - $GLPI_DB_DIR"

# Create .env from template if missing
if [ ! -f "$ROOT_DIR/.env" ]; then
  if [ -f "$ROOT_DIR/.env.template" ]; then
    echo "Creating .env from .env.template"
    cp "$ROOT_DIR/.env.template" "$ROOT_DIR/.env"
    chmod 600 "$ROOT_DIR/.env" || true
    echo "Wrote .env (permission 600) - edit it with your secrets"
  else
    echo ".env.template not found; creating minimal .env"
  cat > "$ROOT_DIR/.env" <<EOF
DB_HOST=glpi-db
DB_NAME=glpi
DB_USER=glpi
DB_PASSWORD=please_change_me
DB_ROOT_PASSWORD=please_change_root
GLPI_DB_DATA_DIR=$GLPI_DB_DIR
GLPI_STORAGE_DIR=$GLPI_STORAGE_DIR
EOF
    chmod 600 "$ROOT_DIR/.env" || true
  fi
else
  echo ".env already exists; updating GLPI path variables to local ./data"
fi

# Ensure .env contains the GLPI path vars pointing to the local data dirs
set_or_replace_var() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

set_or_replace_var "$ROOT_DIR/.env" "GLPI_DB_DATA_DIR" "$GLPI_DB_DIR"
set_or_replace_var "$ROOT_DIR/.env" "GLPI_STORAGE_DIR" "$GLPI_STORAGE_DIR"

# Create docker network if missing
NET_NAME="shared-network"
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found; skipping network creation"
else
  if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    echo "Creating docker network: $NET_NAME"
    docker network create "$NET_NAME"
  else
    echo "Docker network $NET_NAME already exists"
  fi
fi

echo
echo "Next steps (relative to $ROOT_DIR):"
echo " - Edit $ROOT_DIR/.env with real secrets and verify the GLPI_* paths"
echo " - Run: (from any directory) cd $ROOT_DIR && docker compose up -d"

exit 0
