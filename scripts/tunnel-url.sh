#!/usr/bin/env bash
# Muestra el enlace del túnel rápido de Cloudflare (HT-04) leyendo los logs de cloudflared.
# Uso: scripts/tunnel-url.sh [qa|prod]      (qa por defecto; en QA el túnel va con el profile "tunel")
set -euo pipefail
ENTORNO=${1:-qa}
case "$ENTORNO" in qa|prod) ;; *) echo "Uso: $0 [qa|prod]" >&2; exit 1 ;; esac
C=$(docker ps -q --filter "label=com.docker.compose.project=tripbus-$ENTORNO" \
                 --filter "label=com.docker.compose.service=cloudflared" | head -1)
if [ -z "$C" ]; then
  echo "cloudflared no está corriendo en tripbus-$ENTORNO." >&2
  [ "$ENTORNO" = qa ] && echo "Levántalo con COMPOSE_PROFILES=tunel en .env.qa y scripts/qa.sh up." >&2
  exit 1
fi
# El enlace aparece en los logs unos segundos después de arrancar: se espera hasta 30 s.
for _ in $(seq 1 30); do
  URL=$(docker logs "$C" 2>&1 | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  if [ -n "$URL" ]; then echo "$URL"; exit 0; fi
  sleep 1
done
if docker logs "$C" 2>&1 | grep -q 'Registered tunnel connection'; then
  echo "Túnel con nombre (CLOUDFLARE_TUNNEL_TOKEN): el enlace es el hostname que configuraste en Cloudflare." >&2
else
  echo "No se encontró el enlace en los logs de cloudflared: revisa  docker logs $C" >&2
fi
exit 1
