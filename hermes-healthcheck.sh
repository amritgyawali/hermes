#!/usr/bin/env bash
set -euo pipefail

if ! curl --silent --show-error --fail --max-time 10 http://127.0.0.1:8642/health >/dev/null; then
  logger -t hermes-healthcheck "gateway health probe failed; restarting service"
  systemctl --user restart hermes-gateway.service
fi
