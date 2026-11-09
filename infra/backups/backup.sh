#!/bin/sh
# =============================================================================
#  Copias de seguridad de las 6 PostgreSQL de TripBus (HT-05). Corre en el contenedor "backups"
#  (postgres:16-alpine, mismo pg_dump que las bases).
#    backup.sh loop   espera hasta BACKUP_HOUR (hora de Colombia) y hace una copia al día
#    backup.sh once   una copia ahora (la usa scripts/backup-now.sh)
#  Cada copia: /backups/AAAA-MM-DD/<servicio>.dump (pg_dump -Fc, formato propio de pg_restore).
#  Después borra las carpetas de fecha con más de BACKUP_KEEP_DAYS días (7 por defecto).
# =============================================================================
set -u

KEEP=${BACKUP_KEEP_DAYS:-7}
HOUR=${BACKUP_HOUR:-3}
# Colombia no tiene horario de verano: siempre UTC-5. Así no hace falta tzdata en la imagen.
OFFSET=$((5 * 3600))

hoy() { date -u -d "@$(( $(date -u +%s) - OFFSET ))" +%F; }

# servicio  host               base                usuario y contraseña (variables)
BASES="identity:identity-db:tripbus_identity:IDENTITY
catalog:catalog-db:tripbus_catalog:CATALOG
seat-inventory:seat-inventory-db:tripbus_inventory:INVENTORY
booking:booking-db:tripbus_booking:BOOKING
fleet:fleet-db:tripbus_fleet:FLEET
offers:offers-db:tripbus_offers:OFFERS"

copia() {
  dia=$(hoy); dir=/backups/$dia; fallos=0; usuario=""; clave=""
  mkdir -p "$dir"
  for linea in $BASES; do
    servicio=${linea%%:*}; resto=${linea#*:}
    host=${resto%%:*}; resto=${resto#*:}
    base=${resto%%:*}; pref=${resto#*:}
    eval "usuario=\${${pref}_DB_USERNAME:-}; clave=\${${pref}_DB_PASSWORD:-}"
    if PGPASSWORD="$clave" pg_dump -h "$host" -U "$usuario" -d "$base" -Fc -f "$dir/$servicio.dump.tmp"; then
      mv "$dir/$servicio.dump.tmp" "$dir/$servicio.dump"
      echo "$(date -u +%FT%TZ) backup OK  $servicio -> $dir/$servicio.dump ($(wc -c < "$dir/$servicio.dump") bytes)"
    else
      rm -f "$dir/$servicio.dump.tmp"; fallos=$((fallos + 1))
      echo "$(date -u +%FT%TZ) backup ERROR $servicio ($host/$base)" >&2
    fi
  done
  limpiar
  return "$fallos"
}

# Borra /backups/AAAA-MM-DD con fecha anterior a hoy - KEEP días (compara AAAAMMDD como números).
limpiar() {
  limite=$(date -u -d "@$(( $(date -u +%s) - OFFSET - KEEP * 86400 ))" +%Y%m%d)
  for d in /backups/????-??-??; do
    [ -d "$d" ] || continue
    n=$(basename "$d" | tr -d '-')
    if [ "$n" -lt "$limite" ] 2>/dev/null; then
      rm -rf "$d" && echo "$(date -u +%FT%TZ) borrada la copia vieja $d (más de $KEEP días)"
    fi
  done
}

# Segundos hasta la próxima BACKUP_HOUR:00 de Colombia.
espera() {
  ahora=$(( $(date -u +%s) - OFFSET ))
  hoy0=$(( ahora - ahora % 86400 ))
  objetivo=$(( hoy0 + HOUR * 3600 ))
  [ "$objetivo" -le "$ahora" ] && objetivo=$(( objetivo + 86400 ))
  echo $(( objetivo - ahora ))
}

case "${1:-loop}" in
  once) copia ;;
  loop)
    trap 'exit 0' TERM INT
    echo "backups: una copia al día a las ${HOUR}:00 (Colombia), se conservan $KEEP días"
    while true; do
      s=$(espera); echo "backups: próxima copia en ${s}s"
      sleep "$s" & wait $!
      copia || true
    done ;;
  *) echo "Uso: backup.sh once | loop" >&2; exit 2 ;;
esac
