#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"

CONTROLLER_FILE="${REPO_ROOT}/scripts/controller.sh"

required_vars=(
  HEALTH_REPORT_URL
  HIVEMOOT_AGENT_TOKEN
  HIVEMOOT_AGENT_TOKEN_FILE
  HEALTH_REPORT_TIMEOUT_SECS
  HEALTH_REPORT_MAX_RETRIES
  HEALTH_REPORT_RUN_SUMMARY
)

# Health-report vars that the controller must also forward to worker containers.
# Any var added to required_vars that starts with HEALTH_REPORT_ should appear
# here so that missing controller forwarding fails CI immediately.
health_report_controller_vars=(
  HEALTH_REPORT_URL
  HEALTH_REPORT_TIMEOUT_SECS
  HEALTH_REPORT_MAX_RETRIES
  HEALTH_REPORT_RUN_SUMMARY
)

fail=0
for var in "${required_vars[@]}"; do
  pattern="^[[:space:]]+${var}:[[:space:]]+\\$\\{${var}:-"
  if ! grep -Eq "$pattern" "$COMPOSE_FILE"; then
    echo "Missing docker-compose env wiring for ${var}" >&2
    fail=1
  fi
done

for var in "${health_report_controller_vars[@]}"; do
  if ! grep -qF "append_env_if_set ${var}" "$CONTROLLER_FILE"; then
    echo "Missing controller.sh forwarding for ${var} (append_env_if_set ${var})" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: health reporting env vars are wired into docker-compose runtime env and controller.sh"
