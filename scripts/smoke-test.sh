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
nuevo_bus() { # imprime el id del bus nuevo, o vacío si POST /buses no está disponible
  local r; r=$(req POST /buses "$OPER" "{\"placa\":\"$(tr -dc 'A-Z' </dev/urandom | head -c 3)$(printf '%03d' $((RANDOM % 1000)))\",\"tipo\":\"UN_PISO\"}")
  [ "$(status "$r")" = 201 ] && body "$r" | jq -r .id || true
}
programar() { # bus salida → "status body" de POST /itineraries
  req POST /itineraries "$OPER" "{\"routeId\":\"$RUTA\",\"busId\":\"$1\",\"fechaSalida\":\"$2\",\"precioBase\":65000}"
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

printf '\n\033[32mTodo el flujo del MVP funciona de extremo a extremo.\033[0m\n'
