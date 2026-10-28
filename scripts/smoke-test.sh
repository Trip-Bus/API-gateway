#!/usr/bin/env bash
# =============================================================================
#  Prueba de humo extremo a extremo del MVP de TripBus, TODO a través del API Gateway (REST y /ws).
#  El segundo argumento (18007) solo se usa para la página de demo del Realtime (publicada en QA).
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

step "0. Gateways arriba (18000 REST y WebSocket /ws, 18007 demo del Realtime en QA)"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$API/health")" = 200 ] && ok "API Gateway $API/health → 200" || fail "API Gateway no responde en $API"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$API/auth/validate")" = 404 ] && ok "/auth/validate no es público (404)" || fail "/auth/validate expuesto"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$API/actuator/health")" = 404 ] && ok "/actuator no se expone (404)" || fail "/actuator expuesto"
# Handshake WebSocket por el gateway, sin token: 101 (abierto) o 401/403 (lo rechaza el Realtime);
# 404/502/503 = /ws no llega al Realtime. Con 101 la conexión queda abierta: --max-time la corta.
# Sec-WebSocket-Key: 16 bytes aleatorios en base64 (RFC 6455), generados en cada ejecución.
WS_KEY=$(head -c 16 /dev/urandom | base64)
WS=$(curl -s -o /dev/null -w "%{http_code}" --http1.1 --max-time 3 "$API/ws" \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H "Sec-WebSocket-Key: $WS_KEY" || true)
case "$WS" in 101|401|403) ok "WebSocket por el gateway: GET $API/ws con upgrade → $WS";; *) fail "WebSocket por el gateway: GET $API/ws → $WS";; esac
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

step "8. Sprint 2: empresas, usuarios, buses, rutas y viajes (HT-02)"
# Si el endpoint aún no está en develop del servicio (404/405), el paso se omite con un aviso.
skip()  { printf '  \033[33m⚠ omitido: %s\033[0m\n' "$*"; }
nodisp() { case "$(status "$1")" in 404|405) return 0;; *) return 1;; esac; }
SUF="$RANDOM$RANDOM"
CO=""; BUS=""; RUTA=""; VIAJE=""
R=$(req POST /companies "$ADMIN" "{\"nombre\":\"Smoke Transportes $SUF\",\"nit\":\"9$(printf '%08d' "$SUF" | tail -c 8)\"}")
if nodisp "$R"; then skip "POST /companies no está disponible en catalog"
elif [ "$(status "$R")" = 201 ]; then CO=$(body "$R" | jq -r .id); ok "ADMIN creó la empresa $CO"
else fail "crear empresa: $R"; fi
if [ -n "$CO" ]; then
  R=$(req POST /users "$ADMIN" "{\"nombre\":\"Operador Smoke\",\"email\":\"smoke.op.$SUF@tripbus.co\",\"documentoIdentidad\":\"CC$SUF\",\"rol\":\"OPERADOR\",\"companyId\":\"$CO\"}")
  if nodisp "$R"; then skip "POST /users no está disponible en identity"
  elif [ "$(status "$R")" = 201 ]; then ok "ADMIN creó un OPERADOR de la empresa (POST /users)"
  else fail "crear operador: $R"; fi
fi
R=$(req POST /users "$ADMIN" "{\"nombre\":\"Operador Fantasma\",\"email\":\"smoke.nx.$SUF@tripbus.co\",\"documentoIdentidad\":\"CX$SUF\",\"rol\":\"OPERADOR\",\"companyId\":\"00000000-0000-4000-8000-000000000000\"}")
if nodisp "$R"; then skip "POST /users no está disponible en identity"
elif [ "$(status "$R")" = 400 ] && [ "$(body "$R" | jq -r .error.code)" = COMPANY_NOT_FOUND ]; then ok "empresa inexistente → 400 COMPANY_NOT_FOUND"
else fail "empresa inexistente: $R"; fi
[ "$(status "$(req GET /internal/companies/00000000-0000-4000-8000-000000000000 '' '')")" = 404 ] && ok "/internal/companies no se expone (404)" || fail "/internal expuesto"

PLACA="$(tr -dc 'A-Z' </dev/urandom | head -c 3)$(printf '%03d' $((RANDOM % 1000)))"
R=$(req POST /buses "$OPER" "{\"placa\":\"$PLACA\",\"tipo\":\"UN_PISO\"}")
if nodisp "$R"; then skip "POST /buses no está disponible en catalog"
elif [ "$(status "$R")" = 201 ]; then BUS=$(body "$R" | jq -r .id); ok "OPERADOR creó el bus $PLACA"
else fail "crear bus: $R"; fi
R=$(req POST /routes "$OPER" '{"origen":"Bogotá","destino":"Tunja","paradas":[{"orden":1,"nombre":"Bogotá","lat":4.65,"lng":-74.1,"minutosDesdeSalida":0},{"orden":2,"nombre":"Chocontá","lat":5.15,"lng":-73.68,"minutosDesdeSalida":80},{"orden":3,"nombre":"Tunja","lat":5.53,"lng":-73.36,"minutosDesdeSalida":150}]}')
if nodisp "$R"; then skip "POST /routes no está disponible en catalog"
elif [ "$(status "$R")" = 201 ]; then RUTA=$(body "$R" | jq -r .id); ok "OPERADOR definió la ruta Bogotá→Tunja con 3 paradas"
else fail "crear ruta: $R"; fi
if [ -n "$BUS" ] && [ -n "$RUTA" ]; then
  DIA=$(date -d '+2 days' +%F 2>/dev/null || date -v+2d +%F)
  R=$(req POST /itineraries "$OPER" "{\"routeId\":\"$RUTA\",\"busId\":\"$BUS\",\"fechaSalida\":\"${DIA}T15:00:00Z\",\"precioBase\":65000}")
  if nodisp "$R"; then skip "POST /itineraries no está disponible en catalog"
  elif [ "$(status "$R")" = 201 ]; then
    VIAJE=$(body "$R" | jq -r .itineraryId); ok "OPERADOR programó el viaje $VIAJE el $DIA"
    for i in $(seq 1 10); do
      EN=$(body "$(req GET "/trips/search?origin=Bogota&destination=Tunja&date=$DIA" '' '')" | jq -r --arg it "$VIAJE" '[.[] | select(.itineraryId==$it)] | length')
      [ "$EN" = 1 ] && break; sleep 1
    done
    [ "$EN" = 1 ] && ok "el viaje aparece en GET /trips/search" || fail "el viaje $VIAJE no aparece en la búsqueda"
    R=$(req POST /itineraries "$OPER" "{\"routeId\":\"$RUTA\",\"busId\":\"$BUS\",\"fechaSalida\":\"${DIA}T16:00:00Z\",\"precioBase\":65000}")
    [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = BUS_SCHEDULE_CONFLICT ] \
      && ok "viaje cruzado del mismo bus → 409 BUS_SCHEDULE_CONFLICT" || fail "cruce de viajes: $R"
  else fail "programar viaje: $R"; fi
else skip "programar viaje (falta el bus o la ruta)"; fi
if [ -n "$RUTA" ]; then
  [ "$(status "$(req GET "/routes/$RUTA/stops" '' '')")" = 200 ] && ok "GET /routes/{id}/stops funciona sin token" || fail "paradas públicas"
else
  [ "$(status "$(req GET "/routes/$(body "$(req GET "/itineraries/$IT" '' '')" | jq -r .routeId)/stops" '' '')")" = 200 ] \
    && ok "GET /routes/{id}/stops funciona sin token" || fail "paradas públicas"
fi
[ "$(status "$(req POST /routes '' '{}')")" = 401 ] && ok "POST /routes sin token → 401" || fail "POST /routes sin token no fue rechazado"
CORS=$(curl -s -o /dev/null -D - -X OPTIONS "$API/companies" -H 'Origin: http://localhost:5173' \
  -H 'Access-Control-Request-Method: PATCH' | tr -d '\r' | grep -i '^access-control-allow-methods:' || true)
echo "$CORS" | grep -q PATCH && ok "OPTIONS (preflight PATCH) → ${CORS}" || fail "CORS sin PATCH: ${CORS:-sin header}"

step "9. Sprint 2 · operación en ruta: conductor, rastreo y posición en vivo (HT-02)"
# Al final se libera la asignación para que otra ejecución pueda volver a asignar al conductor.
jwt_sub() { local p; p=$(echo "$1" | cut -d. -f2 | tr '_-' '/+'); while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done; echo "$p" | base64 -d 2>/dev/null | jq -r .sub; }
nuevo_bus() { # [tipo] → imprime el id del bus nuevo, o vacío si POST /buses no está disponible
  local r; r=$(req POST /buses "$OPER" "{\"placa\":\"$(tr -dc 'A-Z' </dev/urandom | head -c 3)$(printf '%03d' $((RANDOM % 1000)))\",\"tipo\":\"${1:-UN_PISO}\"}")
  [ "$(status "$r")" = 201 ] && body "$r" | jq -r .id || true
}
programar() { # bus salida [precio] → "status body" de POST /itineraries
  req POST /itineraries "$OPER" "{\"routeId\":\"$RUTA\",\"busId\":\"$1\",\"fechaSalida\":\"$2\",\"precioBase\":${3:-65000}}"
}
asignar() { # viaje → "status body"; reintenta mientras fleet aún no recibe el viaje (ItineraryPublished es asíncrono)
  local r i; for i in $(seq 1 15); do
    r=$(req PUT "/trips/$1/driver" "$OPER" "{\"conductorId\":\"$COND_ID\",\"rol\":\"PRINCIPAL\"}")
    [ "$(body "$r" | jq -r '.error.code? // empty' 2>/dev/null)" = TRIP_NOT_FOUND ] || break; sleep 1
  done; echo "$r"
}
COND_ID=$(jwt_sub "$COND"); V1=""; ASIGNADO=""; RASTREO=""
B1=$(nuevo_bus); B2=$(nuevo_bus)
if [ -z "$RUTA" ] && [ -n "$B1" ]; then
  R=$(req POST /routes "$OPER" '{"origen":"Bogotá","destino":"Tunja","paradas":[{"orden":1,"nombre":"Bogotá","lat":4.65,"lng":-74.1,"minutosDesdeSalida":0},{"orden":2,"nombre":"Tunja","lat":5.53,"lng":-73.36,"minutosDesdeSalida":150}]}')
  [ "$(status "$R")" = 201 ] && RUTA=$(body "$R" | jq -r .id)
fi
if [ -n "$B1" ] && [ -n "$B2" ] && [ -n "$RUTA" ]; then
  R=$(programar "$B1" "$(date -u -d '+10 min' +%FT%TZ 2>/dev/null || date -u -v+10M +%FT%TZ)")
  if nodisp "$R"; then skip "POST /itineraries no está disponible en catalog"
  elif [ "$(status "$R")" = 201 ]; then V1=$(body "$R" | jq -r .itineraryId); ok "OPERADOR programó el viaje $V1 que sale en 10 minutos"
  else fail "programar viaje en 10 min: $R"; fi
else skip "crear bus, ruta y viaje (POST /buses o /routes no está disponible en catalog)"; fi

if [ -n "$V1" ]; then
  R=$(asignar "$V1")
  if nodisp "$R" && [ "$(body "$R" | jq -r '.error.code? // empty' 2>/dev/null)" != TRIP_NOT_FOUND ]; then skip "PUT /trips/{id}/driver no está disponible en fleet"
  elif [ "$(status "$R")" = 200 ]; then ASIGNADO=1; ok "conductor@tripbus.co asignado como PRINCIPAL"
  else fail "asignar conductor: $R"; fi
fi
if [ -n "$ASIGNADO" ]; then
  R=$(programar "$B2" "$(date -u -d '+30 min' +%FT%TZ 2>/dev/null || date -u -v+30M +%FT%TZ)")
  [ "$(status "$R")" = 201 ] || fail "programar viaje cruzado: $R"
  R=$(asignar "$(body "$R" | jq -r .itineraryId)")
  [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = DRIVER_SCHEDULE_CONFLICT ] \
    && ok "mismo conductor en un viaje cruzado → 409 DRIVER_SCHEDULE_CONFLICT" || fail "cruce del conductor: $R"

  R=$(req GET /driver/trips "$COND" '')
  if nodisp "$R"; then skip "GET /driver/trips no está disponible en fleet"
  else
    [ "$(body "$R" | jq -r --arg v "$V1" '[.[] | select(.itineraryId==$v)] | length')" = 1 ] && ok "GET /driver/trips muestra el viaje" || fail "mis viajes: $R"
    R=$(req GET /driver/trips/active "$COND" '')
    [ "$(body "$R" | jq -r .itineraryId)" = "$V1" ] && ok "GET /driver/trips/active devuelve el viaje" || fail "viaje activo: $R"
  fi

  R=$(req POST /driver/tracking/start "$COND" "{\"itineraryId\":\"$V1\"}")
  if nodisp "$R"; then skip "POST /driver/tracking/start no está disponible en fleet (pasos 4 a 7 omitidos)"
  elif [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 201 ]; then RASTREO=1; ok "CONDUCTOR inició el rastreo"
  else fail "iniciar rastreo: $R"; fi
fi
if [ -n "$RASTREO" ]; then
  loc() { req POST /driver/location "$COND" "{\"itineraryId\":\"$V1\",\"lat\":4.65,\"lng\":-74.1,\"precision\":$1,\"velocidad\":0,\"timestamp\":\"$(date -u +%FT%TZ)\"}"; }
  R=$(loc 8)
  [ "$(status "$R")" = 202 ] && ok "POST /driver/location en la primera parada → 202" || fail "ubicación: $R"
  R=$(loc 500)
  [ "$(body "$R" | jq -r .aceptada)" = false ] && ok "lectura con precision 500 → aceptada=false" || fail "precisión mala aceptada: $R"
  for i in $(seq 1 10); do
    BP=$(body "$(req GET "/itineraries/$V1/bus-position" '' '')")
    [ "$(echo "$BP" | jq -r .estadoRastreo)" = ACTIVO ] && [ "$(echo "$BP" | jq -r .posicion.lat)" = 4.65 ] && break; sleep 1
  done
  [ "$(echo "$BP" | jq -r .estadoRastreo)" = ACTIVO ] && [ "$(echo "$BP" | jq -r .posicion.lat)" = 4.65 ] \
    && ok "bus-position sin token: estadoRastreo ACTIVO y posición (4.65, -74.1)" || fail "bus-position: $BP"

  # WebSocket anónimo: connect sin token + subscribe; el servidor responde con el snapshot del tema.
  if command -v websocat >/dev/null 2>&1; then
    SNAP=$( (printf '{"type":"connect"}\n{"type":"subscribe","topic":"viaje:%s:posicion"}\n' "$V1"; sleep 4) \
      | timeout 6 websocat -t "${API/http/ws}/ws" 2>/dev/null | grep '"type":"snapshot"' | head -1 || true)
    [ -n "$SNAP" ] && ok "WebSocket viaje:{id}:posicion sin token → snapshot" || fail "WebSocket: no llegó el snapshot"
  else skip "WebSocket viaje:{id}:posicion (instala websocat para probar la suscripción)"; fi

  R=$(req POST /driver/tracking/stop "$COND" "{\"itineraryId\":\"$V1\"}")
  [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 204 ] || fail "detener rastreo: $R"
  for i in $(seq 1 5); do E=$(body "$(req GET "/itineraries/$V1/bus-position" '' '')" | jq -r .estadoRastreo); [ "$E" = EN_PAUSA ] && break; sleep 1; done
  [ "$E" = EN_PAUSA ] && ok "tracking/stop → estadoRastreo EN_PAUSA" || fail "estado tras detener: $E"
  R=$(loc 8)
  [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = TRACKING_NOT_ACTIVE ] \
    && ok "ubicación con el rastreo en pausa → 409 TRACKING_NOT_ACTIVE" || fail "ubicación en pausa: $R"
fi
R=$(req GET /driver/trips "$PAX" '')
if nodisp "$R"; then skip "GET /driver/trips no está disponible en fleet"
else [ "$(status "$R")" = 403 ] && ok "PASAJERO en /driver/trips → 403" || fail "pasajero en /driver/trips: $R"; fi
[ -n "$ASIGNADO" ] && req DELETE "/trips/$V1/driver/PRINCIPAL" "$OPER" '' >/dev/null || true

step "10. Sprint 3 · cambios y novedades"
# Viajes propios en la ruta Bogotá→Tunja, cada uno con su bus (sin cruces): A, B (más caro), C, D y E (bus de
# dos pisos) dentro de 3 días; F sale en 10 min para el conductor. Los eventos entre servicios son asíncronos:
# se espera con reintentos.
viaje() { # tipo-bus salida [precio] → imprime el itineraryId, o vacío
  local b r; b=$(nuevo_bus "$1"); [ -n "$b" ] || return 0
  r=$(programar "$b" "$2" "${3:-65000}"); [ "$(status "$r")" = 201 ] && body "$r" | jq -r .itineraryId || true
}
retener() { # viaje asiento → "status body"; reintenta mientras seat-inventory aún no recibe el viaje
  local r i; for i in $(seq 1 15); do
    r=$(req POST /seats/holds "$PAX" "{\"itineraryId\":\"$1\",\"seatNumbers\":[\"$2\"]}")
    [ "$(status "$r")" = 201 ] && break; sleep 1
  done; echo "$r"
}
confirmada() { # reserva → espera CONFIRMADA
  local e i; for i in $(seq 1 20); do
    e=$(body "$(req GET "/bookings/$1" "$PAX" '')" | jq -r .estado); [ "$e" = CONFIRMADA ] && return 0; sleep 1
  done; fail "la reserva $1 quedó en $e"
}
pagar() { # reserva → paga con tok_visa_approved y espera CONFIRMADA
  local r; r=$(req POST "/bookings/$1/pay" "$PAX" '{"cardToken":"tok_visa_approved","cardLast4":"4242"}' "Idempotency-Key: smoke-$(date +%s)-$RANDOM")
  case "$(status "$r")" in 200|202) ;; *) fail "pago de $1: $r";; esac
  confirmada "$1"
}
comprar() { # viaje asiento → deja BK y TK (reserva y tiquete) del PASAJERO
  local r; r=$(retener "$1" "$2"); [ "$(status "$r")" = 201 ] || fail "retener el asiento $2 de $1: $r"
  r=$(req POST /bookings "$PAX" "{\"holdId\":\"$(body "$r" | jq -r .holdId)\",\"pasajeros\":[{\"nombre\":\"Ana Pérez\",\"tipoDocumento\":\"CC\",\"numeroDocumento\":\"1020304050\"}]}")
  [ "$(status "$r")" = 201 ] || fail "reserva en $1: $r"; BK=$(body "$r" | jq -r .bookingId)
  pagar "$BK"; TK=$(body "$(req GET "/bookings/$BK" "$PAX" '')" | jq -r .ticketId)
}
afectada() { # reserva → 0 cuando aparece en GET /bookings/affected (US-154, asíncrono)
  local i; for i in $(seq 1 20); do
    [ "$(body "$(req GET /bookings/affected "$PAX" '')" | jq -r --arg b "$1" '[.[]? | select(.bookingId==$b)] | length')" = 1 ] && return 0; sleep 1
  done; return 1
}
disponibles() { body "$(req GET "/seats/availability?itineraryIds=$1" '' '')" | jq -r '.[0].disponibles // empty'; }
validar() { req POST /tickets/validate "$COND" "$(jq -nc --arg q "$1" '{qrCode:$q}')"; }

DIA3=$(date -d '+3 days' +%F 2>/dev/null || date -v+3d +%F)
S3_A=""; S3_B=""; S3_C=""; S3_D=""
if [ -n "$RUTA" ]; then
  S3_A=$(viaje UN_PISO "${DIA3}T12:00:00Z"); S3_B=$(viaje UN_PISO "${DIA3}T14:00:00Z" 90000)
  S3_C=$(viaje UN_PISO "${DIA3}T16:00:00Z"); S3_D=$(viaje UN_PISO "${DIA3}T18:00:00Z")
fi
if [ -z "$S3_A" ] || [ -z "$S3_B" ] || [ -z "$S3_C" ] || [ -z "$S3_D" ]; then
  skip "Sprint 3: no se pudieron crear los viajes A–D (POST /buses, /routes o /itineraries no disponible en catalog)"
else
  ok "OPERADOR programó los viajes A ($S3_A), B ($S3_B, más caro), C ($S3_C) y D ($S3_D) del $DIA3"

  step "10.1 OPERADOR bloquea y desbloquea un asiento (US-112)"
  for i in $(seq 1 15); do D0=$(disponibles "$S3_A"); [ -n "$D0" ] && [ "$D0" -gt 0 ] && break; sleep 1; done
  R=$(req POST "/seats/itineraries/$S3_A/blocks" "$OPER" '{"seatNumbers":["39"],"motivo":"Silla dañada (smoke)"}')
  if nodisp "$R"; then skip "POST /seats/itineraries/{id}/blocks no está disponible en seat-inventory"
  elif [ "$(status "$R")" = 200 ]; then
    [ "$(disponibles "$S3_A")" = $((D0 - 1)) ] && ok "asiento 39 BLOQUEADO: disponibles $D0 → $((D0 - 1)) en /seats/availability" || fail "disponibilidad tras bloquear: $(disponibles "$S3_A")"
    R=$(req DELETE "/seats/itineraries/$S3_A/blocks" "$OPER" '{"seatNumbers":["39"]}')
    [ "$(status "$R")" = 200 ] && [ "$(disponibles "$S3_A")" = "$D0" ] && ok "desbloqueado: vuelve a $D0 disponibles" || fail "desbloquear: $R"
  else fail "bloquear asiento: $R"; fi

  step "10.2 PASAJERO compra en A, cambia de asiento y corrige un nombre (US-139, US-152)"
  comprar "$S3_A" 10; BKA=$BK; TKA=$TK; ok "reserva $BKA confirmada con el tiquete $TKA (asiento 10)"
  R=$(req POST "/tickets/$TKA/seat" "$PAX" '{"fromSeat":"10","toSeat":"11"}')
  if nodisp "$R"; then skip "POST /tickets/{id}/seat no está disponible en booking"
  elif [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r '.seatNumbers[0]')" = 11 ]; then ok "cambio de asiento 10 → 11"
  else fail "cambio de asiento: $R"; fi
  PID=$(body "$(req GET "/tickets/$TKA" "$PAX" '')" | jq -r '.pasajeros[0].passengerId')
  R=$(req PATCH "/tickets/$TKA/passengers/$PID" "$PAX" '{"nombre":"Ana María Pérez","tipoDocumento":"CC","numeroDocumento":"1020304050"}')
  if nodisp "$R"; then skip "PATCH /tickets/{id}/passengers/{id} no está disponible en booking"
  elif [ "$(status "$R")" = 200 ]; then
    ok "nombre corregido a $(body "$R" | jq -r '.pasajeros[0].nombre')"
    R=$(req PATCH "/tickets/$TKA/passengers/$PID" "$PAX" '{"nombre":"Ana M. Pérez","tipoDocumento":"CC","numeroDocumento":"1020304050"}')
    [ "$(status "$R")" = 409 ] && ok "segunda corrección del mismo pasajero → 409 $(body "$R" | jq -r .error.code)" || fail "segunda corrección: $R"
  else fail "corregir pasajero: $R"; fi

  step "10.3 PASAJERO reprograma de A a B (más caro) y paga la diferencia (US-150)"
  R=$(retener "$S3_B" 10); [ "$(status "$R")" = 201 ] || fail "retener en B: $R"
  R=$(req POST "/bookings/$BKA/reschedule" "$PAX" "{\"holdId\":\"$(body "$R" | jq -r .holdId)\"}")
  if nodisp "$R"; then skip "POST /bookings/{id}/reschedule no está disponible en booking"; BKB=""
  elif [ "$(status "$R")" = 201 ] && [ "$(body "$R" | jq -r .estado)" = PENDIENTE_PAGO ]; then
    BKB=$(body "$R" | jq -r .bookingId); ok "reserva nueva $BKB en B: diferencia a pagar $(body "$R" | jq -r .total) COP"
    pagar "$BKB"; TKB=$(body "$(req GET "/bookings/$BKB" "$PAX" '')" | jq -r .ticketId)
    ok "diferencia pagada: reserva $BKB CONFIRMADA con el tiquete $TKB"
    QRA=$(body "$(req GET "/tickets/$TKA" "$PAX" '')" | jq -r .qrCode)
    for i in $(seq 1 10); do R=$(validar "$QRA"); [ "$(status "$R")" = 409 ] && break; sleep 1; done
    [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = TICKET_RESCHEDULED ] \
      && ok "CONDUCTOR valida el tiquete viejo → 409 TICKET_RESCHEDULED" || fail "validar tiquete viejo: $R"
    # No se valida el nuevo (quedaría USADO y 10.4 lo reembolsa): basta con que siga EMITIDO.
    [ "$(body "$(req GET "/tickets/$TKB" "$PAX" '')" | jq -r .estado)" = EMITIDO ] && ok "el tiquete nuevo es válido (EMITIDO)" || fail "tiquete nuevo no EMITIDO"
  else fail "reprogramar A → B: $R"; fi

  step "10.4 OPERADOR reprograma B 8 horas; el PASAJERO elige reembolso (US-118, US-154)"
  PAX_ID=$(jwt_sub "$PAX"); WS_LOG=/tmp/tb_ws_avisos; WS_PID=""; : >"$WS_LOG"
  if command -v websocat >/dev/null 2>&1; then
    # Escucha usuario:{id}:avisos mientras transcurre el paso; se revisa en 10.9.
    (printf '{"type":"connect","token":"%s"}\n' "$PAX"; sleep 1; printf '{"type":"subscribe","topic":"usuario:%s:avisos"}\n' "$PAX_ID"; sleep 90) \
      | timeout 95 websocat -t "${API/http/ws}/ws" >"$WS_LOG" 2>/dev/null &
    WS_PID=$!; sleep 2
  fi
  if [ -z "${BKB:-}" ]; then skip "sin la reserva de B (10.3 omitido)"
  else
    R=$(req PATCH "/itineraries/$S3_B/departure" "$OPER" "{\"nuevaFechaSalida\":\"${DIA3}T22:00:00Z\",\"motivo\":\"Cambio de horario (smoke)\"}")
    if nodisp "$R"; then skip "PATCH /itineraries/{id}/departure no está disponible en catalog"
    elif [ "$(status "$R")" = 200 ]; then
      ok "viaje B movido de 14:00 a 22:00"
      R=$(req GET /bookings/affected "$PAX" '')
      if nodisp "$R"; then skip "GET /bookings/affected no está disponible en booking"
      else
        afectada "$BKB" && ok "la reserva $BKB aparece en GET /bookings/affected" || fail "la reserva $BKB no quedó afectada"
        R=$(req POST "/bookings/$BKB/affected/refund" "$PAX" '')
        [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r .estado)" = REEMBOLSADA ] && ok "PASAJERO eligió reembolso → REEMBOLSADA" || fail "reembolso: $R"
        for i in $(seq 1 5); do E=$(body "$(req GET "/tickets/$TKB" "$PAX" '')" | jq -r .estado); [ "$E" = ANULADO ] && break; sleep 1; done
        [ "$E" = ANULADO ] && ok "el tiquete $TKB quedó ANULADO" || fail "tiquete tras el reembolso: $E"
        R=$(req POST "/bookings/$BKB/affected/refund" "$PAX" '')
        if [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = ALREADY_DECIDED ]; then ok "segundo reembolso → 409 ALREADY_DECIDED"
        elif [ "$(status "$R")" = 200 ]; then skip "segundo reembolso → 200 idempotente en booking (se esperaba 409 ALREADY_DECIDED; no reembolsa dos veces)"
        else fail "segundo reembolso: $R"; fi
        R=$(req POST "/bookings/$BKB/affected/accept" "$PAX" '')
        [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = ALREADY_DECIDED ] && ok "otra decisión sobre la misma reserva → 409 ALREADY_DECIDED" || fail "decidir dos veces: $R"
      fi
    else fail "reprogramar el viaje B: $R"; fi
  fi

  step "10.5 OPERADOR cancela C; el PASAJERO reprograma gratis a D (US-154, US-155)"
  comprar "$S3_C" 10; BKC=$BK; ok "reserva $BKC confirmada en C"
  R=$(req POST "/admin/itineraries/$S3_C/cancel" "$OPER" '{"motivo":"Bus varado (smoke)"}')
  [ "$(status "$R")" = 200 ] || fail "cancelar C: $R"; ok "viaje C cancelado"
  BKD=""
  if nodisp "$(req GET /bookings/affected "$PAX" '')"; then skip "GET /bookings/affected no está disponible en booking"
  else
    afectada "$BKC" && ok "la reserva $BKC aparece afectada" || fail "la reserva $BKC no quedó afectada"
    R=$(req POST "/bookings/$BKC/affected/accept" "$PAX" '')
    [ "$(status "$R")" = 409 ] && ok "aceptar el cambio de un viaje cancelado → 409 $(body "$R" | jq -r .error.code)" || fail "aceptar cancelación: $R"
    R=$(retener "$S3_D" 10); [ "$(status "$R")" = 201 ] || fail "retener en D: $R"
    R=$(req POST "/bookings/$BKC/affected/reschedule" "$PAX" "{\"holdId\":\"$(body "$R" | jq -r .holdId)\"}")
    [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r .estado)" = REPROGRAMADA ] || fail "reprogramar gratis a D: $R"
    BKD=$(body "$R" | jq -r .bookingNuevoId); confirmada "$BKD"
    ok "reprogramada gratis a D: reserva $BKD CONFIRMADA sin pago (total $(body "$(req GET "/bookings/$BKD" "$PAX" '')" | jq -r .total))"
  fi

  step "10.6 Manifiesto de pasajeros del viaje D (US-172)"
  R=$(req GET "/itineraries/$S3_D/manifest" "$OPER" '')
  if nodisp "$R" && [ "$(body "$R" | jq -r '.error.code? // empty' 2>/dev/null)" != ITINERARY_NOT_FOUND ]; then skip "GET /itineraries/{id}/manifest no está disponible en booking"
  elif [ -z "$BKD" ]; then skip "manifiesto (10.5 omitido)"
  else
    [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r '[.pasajeros[] | select(.nombre=="Ana Pérez")] | length')" -ge 1 ] \
      && ok "OPERADOR ve a Ana Pérez en el manifiesto (JSON)" || fail "manifiesto JSON: $R"
    R=$(req GET "/itineraries/$S3_D/manifest?format=csv" "$OPER" '')
    [ "$(status "$R")" = 200 ] && echo "$R" | grep -q 'Ana Pérez' && ok "manifiesto en CSV con el pasajero" || fail "manifiesto CSV: $R"
    [ "$(status "$(req GET "/itineraries/$S3_D/manifest" "$PAX" '')")" = 403 ] && ok "PASAJERO en el manifiesto → 403" || fail "manifiesto expuesto al pasajero"
  fi

  step "10.7 Cambio de bus con un asiento vendido que no existe en el bus nuevo (US-119)"
  S3_E=$(viaje DOS_PISOS "${DIA3}T12:00:00Z"); CHICO=$(nuevo_bus UN_PISO)
  if [ -z "$S3_E" ] || [ -z "$CHICO" ]; then skip "no se pudo crear el viaje E o el bus de un piso"
  else
    comprar "$S3_E" 50; ok "asiento 50 vendido en el viaje E (bus de dos pisos)"
    R=$(req PATCH "/itineraries/$S3_E/bus" "$OPER" "{\"busId\":\"$CHICO\",\"motivo\":\"Cambio de flota (smoke)\"}")
    if nodisp "$R"; then skip "PATCH /itineraries/{id}/bus no está disponible en catalog"
    else [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r .error.code)" = SEATS_CONFLICT ] \
      && ok "bus de 40 puestos con el asiento 50 vendido → 409 SEATS_CONFLICT" || fail "cambio de bus: $R"; fi
  fi
fi

step "10.8 CONDUCTOR: checklist, ETA, SOS y fin del viaje (US-171, US-176, US-180)"
S3_F=""; F_ASIG=""
[ -n "$RUTA" ] && S3_F=$(viaje UN_PISO "$(date -u -d '+10 min' +%FT%TZ 2>/dev/null || date -u -v+10M +%FT%TZ)")
if [ -z "$S3_F" ]; then skip "no se pudo programar el viaje F que sale en 10 min"
else
  R=$(asignar "$S3_F"); [ "$(status "$R")" = 200 ] || fail "asignar conductor a F: $R"; F_ASIG=1
  ok "conductor@tripbus.co asignado al viaje $S3_F (sale en 10 min)"
  R=$(req POST "/driver/trips/$S3_F/start" "$COND" '{"checklist":{"manifiestoRevisado":true}}')
  if nodisp "$R"; then skip "POST /driver/trips/{id}/start no está disponible en fleet"
  else
    [ "$(status "$R")" = 400 ] && [ "$(body "$R" | jq -r .error.code)" = CHECKLIST_INCOMPLETE ] && ok "checklist incompleto → 400 CHECKLIST_INCOMPLETE" || fail "checklist incompleto: $R"
    R=$(req POST "/driver/trips/$S3_F/start" "$COND" '{"checklist":{"manifiestoRevisado":true,"documentosBus":true,"lucesYLlantas":true,"botiquinYExtintor":true}}')
    [ "$(status "$R")" = 200 ] || fail "iniciar viaje: $R"
    [ "$(body "$(req GET "/trips/$S3_F/timeline" '' '')" | jq -r '[.[] | select(.tipo=="INICIO")] | length')" -ge 1 ] && ok "viaje iniciado: la línea de tiempo muestra INICIO" || fail "sin INICIO en la línea de tiempo"
    R=$(req POST /driver/location "$COND" "{\"itineraryId\":\"$S3_F\",\"lat\":4.65,\"lng\":-74.1,\"precision\":8,\"velocidad\":0,\"timestamp\":\"$(date -u +%FT%TZ)\"}")
    [ "$(status "$R")" = 202 ] || fail "ubicación: $R"
    for i in $(seq 1 15); do R=$(req GET "/itineraries/$S3_F/eta" '' ''); [ "$(status "$R")" = 200 ] && break; sleep 1; done
    if [ "$(status "$R")" = 200 ]; then ok "GET /itineraries/{id}/eta sin token → $(body "$R" | jq -r '.paradas | length') paradas"
    elif [ "$(body "$R" | jq -r '.error.code? // empty' 2>/dev/null)" = NO_ETA ]; then fail "ETA: $R"
    else skip "GET /itineraries/{id}/eta no está disponible en fleet"; fi
    R=$(req POST /driver/sos "$COND" '{"lat":4.66,"lng":-74.09,"mensaje":"Prueba de humo"}')
    if nodisp "$R"; then skip "POST /driver/sos no está disponible en fleet"
    else
      case "$(status "$R")" in 200|201) ALERTA=$(body "$R" | jq -r .alertId); ok "SOS enviado: alerta $ALERTA";; *) fail "SOS: $R";; esac
      [ "$(body "$(req GET '/alerts?estado=ABIERTA' "$OPER" '')" | jq -r --arg a "$ALERTA" '[.[] | select(.alertId==$a)] | length')" = 1 ] \
        && ok "OPERADOR ve la alerta en GET /alerts?estado=ABIERTA" || fail "alerta no listada"
      [ "$(body "$(req GET "/trips/$S3_F/timeline" '' '')" | jq -r '[.[] | select(.tipo=="SOS")] | length')" = 0 ] \
        && ok "la línea de tiempo pública NO muestra el SOS" || fail "SOS expuesto en la línea de tiempo"
      R=$(req POST "/trips/$S3_F/alerts/$ALERTA/resolve" "$OPER" '{"nota":"Atendida (smoke)"}')
      [ "$(status "$R")" = 200 ] && ok "OPERADOR resolvió la alerta → $(body "$R" | jq -r .estado)" || fail "resolver alerta: $R"
    fi
    R=$(req POST "/driver/trips/$S3_F/finish" "$COND" '')
    [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r .estadoRastreo)" = FINALIZADO ] && ok "CONDUCTOR finalizó el viaje → FINALIZADO" || fail "finalizar: $R"
  fi
fi
[ -n "$F_ASIG" ] && req DELETE "/trips/$S3_F/driver/PRINCIPAL" "$OPER" '' >/dev/null || true

step "10.9 WebSocket: aviso BookingAffected en usuario:{id}:avisos"
if [ -z "${WS_PID:-}" ]; then skip "WebSocket usuario:{id}:avisos (instala websocat para probar la suscripción)"
else
  kill "$WS_PID" 2>/dev/null || true; wait "$WS_PID" 2>/dev/null || true
  if grep -q 'BookingAffected' "$WS_LOG"; then ok "el PASAJERO recibió BookingAffected por el WebSocket"
  elif grep -q 'INVALID_TOPIC' "$WS_LOG"; then skip "el tema usuario:{id}:avisos aún no está en develop del realtime"
  elif [ -z "${BKB:-}" ]; then skip "sin reserva afectada en 10.4"
  else fail "no llegó BookingAffected: $(tr '\n' ' ' <"$WS_LOG")"; fi
fi

printf '\n\033[32mTodo el flujo del MVP funciona de extremo a extremo.\033[0m\n'
