#!/usr/bin/env bash
# Restaura la copia de UNA base (HT-05). REEMPLAZA los datos actuales de esa base.
# Uso: scripts/restore.sh <servicio> <archivo.dump> [qa|prod]
#   servicio: identity | catalog | seat-inventory | booking | fleet | offers
#   ej.:      scripts/restore.sh catalog backups/2026-11-09/catalog.dump
# Detén antes el servicio dueño de la base (p. ej. scripts/qa.sh ... stop catalog-service) y arráncalo después.
set -euo pipefail
SERVICIO=${1:-}; ARCHIVO=${2:-}; ENTORNO=${3:-qa}
case "$SERVICIO" in
  identity) DB=identity-db ;; catalog) DB=catalog-db ;; seat-inventory) DB=seat-inventory-db ;;
  booking) DB=booking-db ;; fleet) DB=fleet-db ;; offers) DB=offers-db ;;
  *) echo "Uso: $0 <identity|catalog|seat-inventory|booking|fleet|offers> <archivo.dump> [qa|prod]" >&2; exit 1 ;;
esac
case "$ENTORNO" in qa|prod) ;; *) echo "Entorno inválido: $ENTORNO (qa o prod)" >&2; exit 1 ;; esac
[ -f "$ARCHIVO" ] || { echo "No existe el archivo $ARCHIVO" >&2; exit 1; }
C=$(docker ps -q --filter "label=com.docker.compose.project=tripbus-$ENTORNO" \
                 --filter "label=com.docker.compose.service=$DB" | head -1)
[ -n "$C" ] || { echo "La base $DB no está corriendo en tripbus-$ENTORNO." >&2; exit 1; }

echo "Vas a REEMPLAZAR la base de $SERVICIO ($DB, tripbus-$ENTORNO) con $ARCHIVO."
read -r -p "Escribe el nombre del servicio ($SERVICIO) para confirmar: " OK
[ "$OK" = "$SERVICIO" ] || { echo "Cancelado."; exit 1; }

# --clean --if-exists: borra y recrea cada objeto; --no-owner: los objetos quedan del usuario de la base.
docker exec -i "$C" sh -c 'pg_restore --clean --if-exists --no-owner --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$ARCHIVO"
echo "Restaurada la base de $SERVICIO desde $ARCHIVO. Reinicia el servicio dueño de la base."
