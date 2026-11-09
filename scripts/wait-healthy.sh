#!/usr/bin/env bash
# Espera a que todos los contenedores con healthcheck del proyecto estén "healthy" (y el gateway responda).
# Uso: scripts/wait-healthy.sh <proyecto> [segundos=600] [url-del-gateway=http://localhost:18000]
set -euo pipefail
P=${1:?Uso: $0 <proyecto> [segundos] [url]}; MAX=${2:-600}; API=${3:-http://localhost:18000}
fin=$(( $(date +%s) + MAX ))
while :; do
  pendientes=$(docker ps -a --filter "label=com.docker.compose.project=$P" --format '{{.Names}} {{.Status}}' \
    | grep -E '\((health: starting|unhealthy)\)|Restarting|Created' || true)
  caidos=$(docker ps -a --filter "label=com.docker.compose.project=$P" --format '{{.Names}} {{.Status}}' \
    | grep -E 'Exited \([1-9]' || true)
  if [ -n "$caidos" ]; then echo "Contenedores caídos:"; echo "$caidos"; exit 1; fi
  if [ -z "$pendientes" ] && curl -sf "$API/health" >/dev/null; then
    echo "Todo arriba:"; docker ps --filter "label=com.docker.compose.project=$P" --format '  {{.Names}}: {{.Status}}'; exit 0
  fi
  if [ "$(date +%s)" -ge "$fin" ]; then echo "Tiempo agotado esperando:"; echo "$pendientes"; exit 1; fi
  sleep 5
done
