#!/usr/bin/env bash
set -euo pipefail

exec 9>/run/postiz-watchdog.lock
flock -n 9 || exit 0

CONTAINERS=(
  postiz
  postiz-postgres
  postiz-redis
  temporal
  temporal-elasticsearch
  temporal-postgresql
  temporal-ui
  temporal-admin-tools
)

for container in "${CONTAINERS[@]}"; do
  if ! docker inspect "$container" >/dev/null 2>&1; then
    logger -t postiz-watchdog "missing container: $container"
    continue
  fi

  running="$(docker inspect -f '{{.State.Running}}' "$container")"
  if [[ "$running" != "true" ]]; then
    logger -t postiz-watchdog "starting stopped container: $container"
    docker start "$container" >/dev/null
    continue
  fi

  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
  if [[ "$health" == "unhealthy" ]]; then
    logger -t postiz-watchdog "restarting unhealthy container: $container"
    docker restart "$container" >/dev/null
  fi
done
