#!/usr/bin/env bash
set -euo pipefail

# setup.sh - run init.sh, bring up docker compose, and remove install.php inside the glpi container
# Usage: ./setup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Running init.sh..."
if [ -f "./init.sh" ]; then
  if [ -x "./init.sh" ]; then
    ./init.sh
  else
    bash ./init.sh
  fi
else
  echo "init.sh not found in $SCRIPT_DIR" >&2
  exit 1
fi

# Start docker compose
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found in PATH" >&2
  exit 1
fi

echo "Starting containers with docker compose up -d..."
docker compose up -d

# Target container and file
CONTAINER_NAME="glpi"
TARGET_PATH="/var/www/glpi/install/install.php"

# Wait up to 30s for container to appear running
echo "Waiting for container '$CONTAINER_NAME' to be running (timeout 30s)..."
for i in $(seq 1 30); do
  if docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container ${CONTAINER_NAME} is running"
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "Container ${CONTAINER_NAME} did not start within 30s" >&2
    # continue anyway; docker exec will fail with useful message
  fi
done

# Helper: determine whether GLPI appears initialized inside the container
is_glpi_initialized() {
  # Check for config files that are created when installation finishes
  # And verify the web root returns HTTP 200
  # Returns 0 only if both config files exist and HTTP check returns 200

  # 1) file checks inside container
  docker exec "$CONTAINER_NAME" sh -c 'test -s /var/glpi/config/config_db.php && test -s /var/glpi/config/glpicrypt.key' >/dev/null 2>&1 || return 1

  # 2) HTTP check: try to find host mapped port for container's port 80
  HOST_PORT="$(docker inspect --format '{{ (index (index .NetworkSettings.Ports "80/tcp") 0).HostPort }}' "$CONTAINER_NAME" 2>/dev/null || true)"

  # If we got a host port, try curl from the host
  if [ -n "$HOST_PORT" ]; then
    if command -v curl >/dev/null 2>&1; then
      http_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/" 2>/dev/null || true)"
      [ "$http_code" = "200" ] && return 0 || return 1
    fi
  fi

  # Fallback: try curl inside the container (if available there)
  docker exec "$CONTAINER_NAME" sh -c 'command -v curl >/dev/null 2>&1 && curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ || true' >/tmp/.glpi_http_check 2>/dev/null || true
  # read result file from host
  if docker exec "$CONTAINER_NAME" sh -c 'test -f /tmp/.glpi_http_check' >/dev/null 2>&1; then
    http_code="$(docker exec "$CONTAINER_NAME" cat /tmp/.glpi_http_check 2>/dev/null || true)"
    # clean up
    docker exec "$CONTAINER_NAME" rm -f /tmp/.glpi_http_check >/dev/null 2>&1 || true
    [ "$http_code" = "200" ] && return 0 || return 1
  fi

  # If we couldn't determine HTTP status, return 1 to indicate not yet initialized
  return 1
}

# Wait settings (seconds)
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600}    # total seconds to wait for initialization (default 10 minutes)
POLL_INTERVAL=${POLL_INTERVAL:-5}    # how often to poll (seconds)

echo "Checking whether GLPI is initialized inside container '$CONTAINER_NAME'..."
if docker exec "$CONTAINER_NAME" test -e "$TARGET_PATH" >/dev/null 2>&1; then
  echo "$TARGET_PATH exists inside $CONTAINER_NAME"
  # If already initialized, remove immediately
  if is_glpi_initialized; then
    echo "GLPI already initialized (config_db.php present). Removing $TARGET_PATH inside $CONTAINER_NAME..."
    docker exec "$CONTAINER_NAME" rm -f "$TARGET_PATH" && echo "Removed $TARGET_PATH"
  else
    echo "GLPI not initialized yet. Will wait up to ${WAIT_TIMEOUT}s for installation to complete..."
    elapsed=0
    while ! is_glpi_initialized; do
      if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
        echo "Timed out after ${WAIT_TIMEOUT}s waiting for GLPI initialization. Skipping removal." >&2
        echo "To force removal now, run: docker exec $CONTAINER_NAME rm -f $TARGET_PATH"
        break
      fi
      echo "Not initialized yet; sleeping ${POLL_INTERVAL}s (elapsed ${elapsed}s)..."
      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    done

    if is_glpi_initialized; then
      echo "GLPI is now initialized (config_db.php present). Removing $TARGET_PATH inside $CONTAINER_NAME..."
      docker exec "$CONTAINER_NAME" rm -f "$TARGET_PATH" && echo "Removed $TARGET_PATH"
    fi
  fi
else
  echo "$TARGET_PATH not found inside $CONTAINER_NAME; nothing to remove"
fi

echo "setup.sh completed"
