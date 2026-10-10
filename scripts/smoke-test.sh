#!/usr/bin/env bash
# =============================================================================
#  Prueba de humo extremo a extremo del MVP de TripBus, TODO a través del API Gateway.
#  Requisitos: curl y jq. Uso:  ./scripts/smoke-test.sh [http://localhost:18000] [http://localhost:18007]
#  Pensado para QA (perfil qa): usa los usuarios de demostración y el catálogo sembrado.
#  Sin jq (p. ej. Windows), córrelo en un contenedor dentro de la red de QA (ver README).
# =============================================================================
set -euo pipefail
API=${1:-${API_URL:-http://localhost:18000}}
RT=${2:-${RT_URL:-http://localhost:18007}}
PASS=${DEMO_USERS_PASSWORD:-TripBus2026}
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
req()  { # método url [token] [body] [headers extra...] -> imprime "status body"
  local m=$1 u=$2 t=${3:-} b=${4:-}; shift 4 || shift $#
  local args=(-s -o /tmp/tb_body -w '%{http_code}' -X "$m" "$API$u" -H 'Content-Type: application/json')
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$b" ] && args+=(-d "$b")
  for h in "$@"; do args+=(-H "$h"); done
  local code; code=$(curl "${args[@]}"); echo "$code $(cat /tmp/tb_body)"
}
status() { echo "${1%% *}"; }
body()   { echo "${1#* }"; }
login()  { body "$(req POST /auth/login '' "{\"email\":\"$1\",\"password\":\"$PASS\"}")" | jq -r .accessToken; }

step "0. Gateways arriba (18000 REST, 18007 Realtime)"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$API/health")" = 200 ] && ok "API Gateway $API/health → 200" || fail "API Gateway no responde en $API"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$API/auth/validate")" = 404 ] && ok "/auth/validate no es público (404)" || fail "/auth/validate expuesto"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$API/actuator/health")" = 404 ] && ok "/actuator no se expone (404)" || fail "/actuator expuesto"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$RT/")" = 200 ] && ok "Realtime Gateway: página de demo en $RT/" || fail "Realtime no responde en $RT"
ok "demo-config.json apunta a $(curl -s "$RT/demo-config.json" | jq -r .apiUrl)"

step "1. Identity: login de los usuarios de demostración (US-096)"
PAX=$(login pasajero@tripbus.co); OPER=$(login operador@tripbus.co); COND=$(login conductor@tripbus.co); ADMIN=$(login admin@tripbus.co)
[ "$PAX" != "null" ] && [ "$OPER" != "null" ] || fail "no se pudo iniciar sesión"
ok "tokens emitidos para pasajero, operador, conductor y admin"
R=$(req POST /auth/register '' "{\"email\":\"smoke.$RANDOM$RANDOM@tripbus.co\",\"password\":\"Passw0rd1\",\"documentoIdentidad\":\"CC$RANDOM$RANDOM\",\"nombre\":\"Smoke Test\",\"aceptaPoliticaDatos\":true}")
[ "$(status "$R")" = 201 ] || fail "registro: $R"; OTRO=$(body "$R" | jq -r .accessToken); ok "registro de un pasajero nuevo con consentimiento (US-001)"
[ "$(status "$(req POST /admin/seed "$PAX" '')")" = 403 ] && ok "un pasajero NO puede ejecutar el seed (US-005)" || fail "control de roles"

step "2. Catalog: búsqueda (US-007/008)"
FECHA=$(date -d tomorrow +%F 2>/dev/null || date -v+1d +%F)
R=$(req GET "/trips/search?origin=bogota&destination=Medell%C3%ADn&date=$FECHA" '' '')
[ "$(status "$R")" = 200 ] || fail "búsqueda: $R"
IT=$(body "$R" | jq -r '.[0].itineraryId'); N=$(body "$R" | jq length); DISP=$(body "$R" | jq -r '.[0].asientosDisponibles')
ok "$N viajes Bogotá→Medellín el $FECHA; primero $IT con $DISP asientos disponibles"

step "3. Seat Inventory: mapa, retención y concurrencia (US-016/017/018/022/026)"
[ "$(status "$(req GET "/itineraries/$IT/seatmap" '' '')")" = 200 ] && ok "mapa real del bus"
ASIENTO=$(body "$(req GET "/seats/itineraries/$IT" '' '')" | jq -r '[.asientos[] | select(.estado=="DISPONIBLE")][0].seatNumber')
R=$(req POST /seats/holds "$PAX" "{\"itineraryId\":\"$IT\",\"seatNumbers\":[\"$ASIENTO\"]}")
[ "$(status "$R")" = 201 ] || fail "retención: $R"; HOLD=$(body "$R" | jq -r .holdId)
ok "asiento $ASIENTO retenido ($(body "$R" | jq -r .segundosRestantes) s restantes)"
R=$(req POST /seats/holds "$OTRO" "{\"itineraryId\":\"$IT\",\"seatNumbers\":[\"$ASIENTO\"]}")
[ "$(status "$R")" = 409 ] && ok "otro pasajero NO puede tomar el mismo asiento → 409 $(body "$R" | jq -r .error.code)" || fail "doble retención: $R"

step "4. Booking + Payment: datos, pago idempotente y tiquete QR (US-031/032/033/034)"
R=$(req POST /bookings "$PAX" "{\"holdId\":\"$HOLD\",\"pasajeros\":[{\"nombre\":\"Ana Pérez\",\"tipoDocumento\":\"CC\",\"numeroDocumento\":\"1020304050\"}]}")
[ "$(status "$R")" = 201 ] || fail "reserva: $R"; BK=$(body "$R" | jq -r .bookingId); ok "reserva $BK por $(body "$R" | jq -r .total) COP"
KEY="smoke-$(date +%s)-$RANDOM"
R1=$(req POST "/bookings/$BK/pay" "$PAX" '{"cardToken":"tok_visa_approved","cardLast4":"4242"}' "Idempotency-Key: $KEY")
R2=$(req POST "/bookings/$BK/pay" "$PAX" '{"cardToken":"tok_visa_approved","cardLast4":"4242"}' "Idempotency-Key: $KEY")
[ "$(body "$R1" | jq -r .paymentId)" = "$(body "$R2" | jq -r .paymentId)" ] && ok "dos envíos del pago con la misma Idempotency-Key → un solo cobro" || fail "idempotencia: $R1 / $R2"
for i in $(seq 1 20); do E=$(body "$(req GET "/bookings/$BK" "$PAX" '')" | jq -r .estado); [ "$E" = CONFIRMADA ] && break; sleep 1; done
[ "$E" = CONFIRMADA ] || fail "la reserva quedó en $E"
TK=$(body "$(req GET "/bookings/$BK" "$PAX" '')" | jq -r .ticketId)
R=$(req GET "/tickets/$TK" "$PAX" '')
[ "$(body "$R" | jq -r '.qrImage[0:22]')" = "data:image/png;base64," ] && ok "pago aprobado por webhook (enviado 2 veces) → 1 tiquete con QR: $TK" || fail "tiquete: $R"
[ "$(body "$(req GET "/seats/itineraries/$IT/$ASIENTO" '' '')" | jq -r .estado)" = VENDIDO ] && ok "el asiento $ASIENTO quedó VENDIDO (US-025)"

step "5. Flash Offers: crear y vender sin superar el cupo (US-054/058/014)"
LIBRES=$(body "$(req GET "/seats/itineraries/$IT" '' '')" | jq -c '[.asientos[] | select(.estado=="DISPONIBLE")][-3:] | map(.seatNumber)')
FIN=$(date -u -d '+30 min' +%FT%TZ 2>/dev/null || date -u -v+30M +%FT%TZ)
R=$(req POST /offers "$OPER" "{\"itineraryId\":\"$IT\",\"seatNumbers\":$LIBRES,\"precioOferta\":49900,\"cupo\":2,\"inicio\":\"$(date -u +%FT%TZ)\",\"fin\":\"$FIN\"}")
[ "$(status "$R")" = 201 ] || fail "oferta: $R"; OF=$(body "$R" | jq -r .offerId); ok "oferta $OF ACTIVA con cupo 2"
sleep 2
[ "$(body "$(req GET "/trips/search?origin=Bogota&destination=Medellin&date=$FECHA" '' '')" | jq -r --arg it "$IT" '.[] | select(.itineraryId==$it) | .ofertaActiva.offerId')" = "$OF" ] && ok "la búsqueda marca el viaje con oferta relámpago (US-014)"
C1=$(status "$(req POST "/offers/$OF/reservations" "$PAX" '{"docId":"1020304050"}')")
C2=$(status "$(req POST "/offers/$OF/reservations" "$OTRO" '{"docId":"99887766"}')")
C3=$(status "$(req POST "/offers/$OF/reservations" "$ADMIN" '{"docId":"11223344"}')")
[ "$C1$C2$C3" = "201201409" ] && ok "3 compradores para cupo 2 → 201, 201, 409 OUT_OF_STOCK" || fail "cupo: $C1 $C2 $C3"
[ "$(body "$(req GET "/offers/$OF/quota" '' '')" | jq -r .cupoRestante)" = 0 ] && ok "cupo restante 0 (US-056)"

step "6. Fleet + Trip Events (US-038/039/046)"
R=$(req POST /telemetry/position "$COND" "{\"busId\":\"$(body "$(req GET "/itineraries/$IT" '' '')" | jq -r .busId)\",\"itineraryId\":\"$IT\",\"lat\":4.9,\"lng\":-74.4,\"velocidad\":72}")
[ "$(status "$R")" = 202 ] && ok "posición GPS aceptada (ingesta asíncrona)"
sleep 2
[ "$(body "$(req GET "/itineraries/$IT/bus-position" '' '')" | jq -r .posicion.lat)" = 4.9 ] && ok "dónde va mi bus: última posición conocida"
R=$(req POST "/trips/$IT/events" "$COND" '{"tipo":"RETRASO","descripcion":"Cierre parcial en la vía","detalle":{"minutos":25}}')
[ "$(status "$R")" = 201 ] && ok "el conductor reportó un RETRASO" || fail "novedad: $R"
[ "$(status "$(req POST "/trips/$IT/events" "$PAX" '{"tipo":"RETRASO"}')")" = 403 ] && ok "un pasajero NO puede reportar novedades (US-005)"

step "7. Cierre de sesión (US-096)"
[ "$(status "$(req POST /auth/logout "$OTRO" '')")" = 204 ] && ok "logout"
[ "$(status "$(req GET /bookings "$OTRO" '')")" = 401 ] && ok "el token revocado es rechazado en el API Gateway" || fail "revocación"

printf '\n\033[32mTodo el flujo del MVP funciona de extremo a extremo.\033[0m\n'
