#!/usr/bin/env bash
# Entorno PROD (servidor): imágenes de GHCR (tag prod), solo publica 18000 y 18007.
# Uso: scripts/prod.sh pull | up | down | ps | logs [servicio] | config
# Antes de "pull": docker login ghcr.io (las imágenes son privadas, ver README).
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env.prod
if [ ! -f "$ENV_FILE" ]; then
  echo "Falta $ENV_FILE. Créalo con:  cp .env.prod.example .env.prod  y cambia cada CAMBIAR_*" >&2
  exit 1
fi
if grep -q 'CAMBIAR' "$ENV_FILE"; then
  echo "$ENV_FILE todavía tiene valores CAMBIAR_*: reemplázalos antes de desplegar." >&2
  exit 1
fi
compose() { docker compose -p tripbus-prod --env-file "$ENV_FILE" -f docker-compose.yml -f docker-compose.prod.yml "$@"; }

case "${1:-}" in
  pull)   compose pull ;;
  up)     compose up -d --no-build --remove-orphans && docker image prune -f ;;
  down)   compose down ;;            # conserva los datos (volúmenes)
  ps)     compose ps ;;
  logs)   shift; compose logs -f --tail=200 "$@" ;;
  config) compose config ;;
  *) echo "Uso: $0 pull | up | down | ps | logs [servicio] | config" >&2; exit 1 ;;
esac
