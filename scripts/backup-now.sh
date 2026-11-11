#!/usr/bin/env bash
# Copia de seguridad inmediata de las 6 bases (HT-05) en ./backups/AAAA-MM-DD/<servicio>.dump.
# Usa el contenedor "backups" (el mismo que hace la copia diaria). Uso: scripts/backup-now.sh [qa|prod]
set -euo pipefail
ENTORNO=${1:-qa}
case "$ENTORNO" in qa|prod) ;; *) echo "Uso: $0 [qa|prod]" >&2; exit 1 ;; esac
C=$(docker ps -q --filter "label=com.docker.compose.project=tripbus-$ENTORNO" \
                 --filter "label=com.docker.compose.service=backups" | head -1)
[ -n "$C" ] || { echo "El contenedor backups no está corriendo en tripbus-$ENTORNO (scripts/$ENTORNO.sh up)." >&2; exit 1; }
docker exec "$C" sh /backup/backup.sh once
