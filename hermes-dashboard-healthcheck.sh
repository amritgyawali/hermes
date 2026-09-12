#!/usr/bin/env bash
set -euo pipefail

if ! curl --silent --show-error --fail --max-time 10 \
  http://172.18.0.1:9119/api/status >/dev/null; then
  logger -t hermes-dashboard-healthcheck "dashboard probe failed; restarting service"
  systemctl --user restart hermes-dashboard.service
fi
