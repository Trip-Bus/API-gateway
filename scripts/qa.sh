#!/usr/bin/env bash
# Entorno QA (tu PC): compila los 8 servicios desde el código y publica todos los puertos.
# Uso: scripts/qa.sh up | down | ps | logs [servicio] | config
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env.qa
if [ ! -f "$ENV_FILE" ]; then
  echo "Falta $ENV_FILE. Créalo con:  cp .env.qa.example .env.qa" >&2
  exit 1
fi
# Con el profile "observabilidad" (COMPOSE_PROFILES en el entorno o en $ENV_FILE) se agrega el override que
# activa trazas OTLP y logs JSON en los servicios Java (HT-10).
FILES=(-f docker-compose.yml -f docker-compose.qa.yml)
PROFILES=${COMPOSE_PROFILES:-$(grep -E '^COMPOSE_PROFILES=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)}
if echo ",$PROFILES," | grep -Eq ',[[:space:]]*observabilidad[[:space:]]*,|,[[:space:]]*observability[[:space:]]*,'; then
  FILES+=(-f docker-compose.observabilidad.yml)
fi
compose() { docker compose -p tripbus-qa --env-file "$ENV_FILE" "${FILES[@]}" "$@"; }

case "${1:-}" in
  up)     compose up -d --build ;;
  down)   compose down ;;            # conserva los datos (volúmenes); para borrarlos: down -v a mano
  ps)     compose ps ;;
  logs)   shift; compose logs -f --tail=200 "$@" ;;
  config) compose config ;;
  *) echo "Uso: $0 up | down | ps | logs [servicio] | config" >&2; exit 1 ;;
esac
