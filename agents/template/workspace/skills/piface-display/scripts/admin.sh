#!/usr/bin/env bash
# piface-admin: update the persistent Admin Dashboard on the PiFace LCD
# Use: bash admin.sh "user_id" "action_summary" "balance"

USER="${1:-None}"
ACTION="${2:-Idle}"
BAL="${3:-N/A}"

PIFACE_URL="${PIFACE_ADMIN_URL:-http://host.docker.internal:18794/admin_stats}"

# Update the host bridge with the admin stats
if curl -sf -m 3 -G \
  --data-urlencode "user=$USER" \
  --data-urlencode "action=$ACTION" \
  --data-urlencode "bal=$BAL" \
  "${PIFACE_URL}" >/dev/null 2>/dev/null; then
    echo '{"status": "ok", "message": "Admin dashboard updated successfully."}'
else
    echo '{"status": "error", "message": "Could not reach the PiFace bridge on the host."}'
fi

exit 0
