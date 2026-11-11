#!/usr/bin/env bash
# Entorno PROD (servidor): imágenes de GHCR (tag prod), solo publica 18000 (REST y WebSocket /ws).
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
# Con el profile "observabilidad" (COMPOSE_PROFILES en el entorno o en $ENV_FILE) se agrega el override que
# activa trazas OTLP y logs JSON en los servicios Java (HT-10).
FILES=(-f docker-compose.yml -f docker-compose.prod.yml)
PROFILES=${COMPOSE_PROFILES:-$(grep -E '^COMPOSE_PROFILES=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)}
if echo ",$PROFILES," | grep -Eq ',[[:space:]]*observabilidad[[:space:]]*,|,[[:space:]]*observability[[:space:]]*,'; then
  FILES+=(-f docker-compose.observabilidad.yml)
fi
compose() { docker compose -p tripbus-prod --env-file "$ENV_FILE" "${FILES[@]}" "$@"; }

case "${1:-}" in
  pull)   compose pull ;;
  up)     compose up -d --no-build --remove-orphans && docker image prune -f ;;
  down)   compose down ;;            # conserva los datos (volúmenes)
  ps)     compose ps ;;
  logs)   shift; compose logs -f --tail=200 "$@" ;;
  config) compose config ;;
  *) echo "Uso: $0 pull | up | down | ps | logs [servicio] | config" >&2; exit 1 ;;
esac
