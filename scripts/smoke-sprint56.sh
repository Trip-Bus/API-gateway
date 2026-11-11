# Sprints 5 y 6 · plataforma, tiempo real, tramos, cupones, sala de espera, viaje compartido y datos personales.
# Funciones y variables base (req/status/body/nodisp/skip/login/viaje/retener/pagar/en_seg, PAX, OPER, ADMIN,
# RUTA, IT, S3_F, DIA3) vienen de smoke-test.sh. Si un endpoint aún no está en develop de su servicio, el paso
# se omite con un aviso (⚠) en vez de fallar.
S56="$(date +%s)$RANDOM"
WS_URL="${API/http/ws}/ws"
hdrs() { curl -s -D - -o /dev/null "$API$1"; }   # encabezados de un GET (sin HEAD: no todos los upstreams lo aceptan)
hdr()  { echo "$1" | tr -d '\r' | grep -i "^$2:" | head -1 | cut -d: -f2- | sed 's/^ //'; }
# Usuario nuevo: imprime "email token"
nuevo_usuario() {
  local e="s56.$1.$S56@tripbus.co" r
  r=$(req POST /auth/register '' "{\"email\":\"$e\",\"password\":\"Passw0rd1\",\"documentoIdentidad\":\"CC$RANDOM$RANDOM\",\"nombre\":\"Smoke Sprint Seis\",\"aceptaPoliticaDatos\":true}")
  [ "$(status "$r")" = 201 ] || fail "registro de $e: $r"
  echo "$e $(body "$r" | jq -r .accessToken)"
}

step "Sprints 5 y 6 · plataforma (HT-03, HT-07, HT-12, HT-13)"
step "12.1 Frontend en / y API versionada /api/v1"
R=$(curl -s -o /tmp/tb_front -w '%{http_code} %{content_type}' "$API/")
if [ "${R%% *}" = 200 ] && grep -q 'id="root"' /tmp/tb_front; then ok "GET / → la app (index.html, ${R#* })"
else fail "GET / no devuelve el frontend: $R $(head -c 120 /tmp/tb_front)"; fi
R=$(curl -s -o /tmp/tb_front -w '%{http_code}' "$API/mis-tiquetes")
[ "$R" = 200 ] && grep -q 'id="root"' /tmp/tb_front && ok "ruta de la SPA (/mis-tiquetes) → index.html" || fail "fallback de la SPA: $R"
A=$(req GET /trips/cities '' ''); B=$(req GET /api/v1/trips/cities '' ''); C=$(req GET /api/trips/cities '' '')
[ "$A" = "$B" ] && [ "$A" = "$C" ] && [ "$(status "$A")" = 200 ] && ok "/api/v1/trips/cities y /api/trips/cities = /trips/cities (mismo status y cuerpo)" || fail "/api/v1 distinto de la ruta vieja: $A | $B | $C"
A=$(req GET "/trips/search?origin=bogota&destination=Medell%C3%ADn&date=$FECHA" '' ''); B=$(req GET "/api/v1/trips/search?origin=bogota&destination=Medell%C3%ADn&date=$FECHA" '' '')
[ "$(body "$A" | jq -c '[.[].itineraryId]')" = "$(body "$B" | jq -c '[.[].itineraryId]')" ] && ok "búsqueda con query string: mismos viajes por /api/v1" || fail "búsqueda por /api/v1 distinta"
[ "$(status "$(req GET /api/v1/bookings '' '')")" = 401 ] && ok "/api/v1/bookings sin token → 401 (misma autenticación)" || fail "/api/v1 sin autenticación"
[ "$(status "$(req GET /api/v1/bookings "$PAX" '')")" = 200 ] && ok "/api/v1/bookings con token → 200" || fail "/api/v1/bookings con token"
R=$(req GET /api/v1/no-existe '' '')
[ "$(status "$R")" = 404 ] && [ "$(body "$R" | jq -r .error.code)" = NOT_FOUND ] && ok "ruta desconocida bajo /api/ → 404 JSON" || fail "/api/v1/no-existe: $R"
[ "$(status "$(req GET /api/v1/internal/companies/x '' '')")" = 404 ] && ok "/api/v1/internal/* tampoco se expone (404)" || fail "/internal expuesto por /api/v1"

step "12.2 Documentación unificada /docs (HT-13)"
R=$(curl -s -o /tmp/tb_docs -w '%{http_code}' "$API/docs/")
if [ "$R" = 404 ]; then skip "/docs apagado (DOCS_ENABLED=false en este entorno)"
elif [ "$R" = 200 ] && grep -qi 'swagger' /tmp/tb_docs; then
  ok "GET /docs/ → Swagger UI"
  for s in identity catalog seat-inventory booking fleet flash-offers realtime; do
    R=$(req GET "/docs/specs/$s" '' '')
    if [ "$(status "$R")" = 200 ] && [ -n "$(body "$R" | jq -r '.openapi // empty' 2>/dev/null)" ]; then
      SRV=$(body "$R" | jq -r '.servers[0].url // ""')
      [ "$SRV" = /api/v1 ] && ok "spec de $s (servidor /api/v1)" || skip "spec de $s sin OPENAPI_SERVER_URL=/api/v1 (servidor: ${SRV:-ninguno}; aún no está en develop)"
    else skip "spec de $s no disponible ($(status "$R")): springdoc apagado o aún no está en develop"; fi
  done
else fail "/docs: $R"; fi

step "12.3 Encabezados de seguridad (HT-12)"
H=$(hdrs /)
CSP=$(hdr "$H" Content-Security-Policy)
echo "$CSP" | grep -q "default-src 'self'" && echo "$CSP" | grep -q "form-action 'self'" && ok "CSP: $(echo "$CSP" | cut -c1-70)…" || fail "CSP: '$CSP'"
echo "$CSP" | grep -q 'fonts.googleapis.com' && echo "$CSP" | grep -q 'wss://' && ok "CSP permite Google Fonts y el WebSocket del mismo origen" || fail "CSP sin Google Fonts o wss: $CSP"
[ "$(hdr "$H" X-Content-Type-Options)" = nosniff ] && ok "X-Content-Type-Options: nosniff" || fail "falta nosniff"
[ "$(hdr "$H" Referrer-Policy)" = strict-origin-when-cross-origin ] && ok "Referrer-Policy: strict-origin-when-cross-origin" || fail "Referrer-Policy"
[ "$(hdr "$H" X-Frame-Options)" = DENY ] && ok "X-Frame-Options: DENY" || fail "X-Frame-Options: $(hdr "$H" X-Frame-Options)"
[ "$(hdr "$H" Permissions-Policy)" = "geolocation=(self)" ] && ok "Permissions-Policy: geolocation=(self)" || fail "Permissions-Policy"
[ "$(echo "$H" | tr -d '\r' | grep -ic '^X-Frame-Options:')" = 1 ] && ok "sin encabezados duplicados (los del frontend se ocultan)" || fail "X-Frame-Options duplicado"
if [ -n "$(hdr "$H" Strict-Transport-Security)" ]; then ok "HSTS activo (HSTS_ENABLED=true)"; else ok "sin HSTS (HSTS_ENABLED=false, sin HTTPS)"; fi
[ -n "$(hdr "$(hdrs /trips/cities)" Content-Security-Policy)" ] && ok "las respuestas del API también llevan los encabezados" || fail "API sin encabezados de seguridad"
SB=$(hdr "$(hdrs /sandbox/pse/no-existe)" Content-Security-Policy)
echo "$SB" | grep -q "form-action 'self'" && ok "/sandbox/ (banco de prueba): form-action 'self'$(echo "$SB" | sed -n "s/.*form-action 'self'\(.*\)/\1/p")" || fail "CSP de /sandbox/: $SB"

step "Sprints 5 y 6 · tiempo real (US-184, HT-11)"
step "12.4 WebSocket: reconexión con resume y límite de conexiones"
if ! command -v websocat >/dev/null 2>&1; then skip "reconexión y límite de conexiones (instala websocat)"
else
  OUT=$( (printf '{"type":"subscribe","topic":"ofertas:activas"}\n'; sleep 3) | timeout 6 websocat -t "$WS_URL" 2>/dev/null || true)
  SEQ=$(echo "$OUT" | jq -r 'select(.type=="snapshot") | .asOfSeq // empty' 2>/dev/null | head -1)
  if [ -z "$SEQ" ]; then skip "sin snapshot con asOfSeq de ofertas:activas (resume aún no está en develop del realtime): $(echo "$OUT" | head -c 150)"
  else
    OUT=$( (printf '{"type":"resume","topic":"ofertas:activas","lastSeq":"%s"}\n' "$SEQ"; sleep 3) | timeout 6 websocat -t "$WS_URL" 2>/dev/null || true)
    if echo "$OUT" | grep -q '"type":"resumed"\|"type":"snapshot"'; then
      ok "resume desde $SEQ → $(echo "$OUT" | grep -o '"type":"\(resumed\|snapshot\)"' | head -1)"
    elif echo "$OUT" | grep -q 'INVALID_MESSAGE\|UNKNOWN_TYPE'; then skip "resume aún no está en develop del realtime"
    else fail "resume: $(echo "$OUT" | head -c 200)"; fi
  fi
  # Límite por usuario (5): 5 conexiones autenticadas abiertas y la sexta se rechaza con TOO_MANY_CONNECTIONS (4429).
  read -r _ WS_TOKEN <<<"$(nuevo_usuario ws)"; [ -n "${WS_TOKEN:-}" ] || fail "no se pudo registrar el usuario del WebSocket"
  PIDS=""; for i in 1 2 3 4 5; do
    (printf '{"type":"connect","token":"%s"}\n' "$WS_TOKEN"; sleep 12) | timeout 14 websocat -t "$WS_URL" >/dev/null 2>&1 &
    PIDS="$PIDS $!"; sleep 0.3
  done
  sleep 2
  OUT=$( (printf '{"type":"connect","token":"%s"}\n' "$WS_TOKEN"; sleep 3) | timeout 6 websocat -t "$WS_URL" 2>&1 || true)
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true
  if echo "$OUT" | grep -q 'TOO_MANY_CONNECTIONS\|4429'; then ok "sexta conexión del mismo usuario → TOO_MANY_CONNECTIONS (cierre 4429)"
  elif echo "$OUT" | grep -q '"authenticated"\|"connected"'; then skip "el límite por usuario aún no está en develop del realtime"
  else fail "límite de conexiones: $(echo "$OUT" | head -c 200)"; fi
fi

step "Sprints 5 y 6 · compra (US-138, US-142, US-146, US-147)"
step "12.5 Compra de un tramo con tipo de pasajero y cupón; comprobante PDF"
CUPON="SMOKE$S56"; CUPON_OK=""
R=$(req POST /coupons "$ADMIN" "$(jq -nc --arg c "$CUPON" --arg d "$(date -u -d '-1 min' +%FT%TZ 2>/dev/null || date -u -v-1M +%FT%TZ)" --arg h "$(en_seg 86400)" \
  '{codigo:$c, tipo:"PORCENTAJE", valor:10, vigenteDesde:$d, vigenteHasta:$h, activo:true}')")
if nodisp "$R"; then skip "/coupons aún no está en develop de booking"
elif [ "$(status "$R")" = 201 ]; then CUPON_OK=1; ok "ADMIN creó el cupón $CUPON (10 %)"
else fail "crear cupón: $R"; fi
TRAMO=""; [ -n "${RUTA:-}" ] && TRAMO=$(viaje UN_PISO "${DIA3}T16:00:00Z")
PID=""
if [ -z "$TRAMO" ]; then skip "no se pudo programar el viaje para el tramo (sin ruta de 3 paradas)"
else
  for i in $(seq 1 15); do
    R=$(req POST /seats/holds "$PAX" "{\"itineraryId\":\"$TRAMO\",\"seatNumbers\":[\"3\",\"4\"],\"fromOrden\":1,\"toOrden\":2}")
    [ "$(status "$R")" = 201 ] && break; sleep 1
  done
  if [ "$(status "$R")" != 201 ]; then fail "retener por tramo: $R"
  elif [ "$(body "$R" | jq -r '.toOrden // empty')" != 2 ]; then skip "retención por tramo (fromOrden/toOrden) aún no está en develop de seat-inventory"
  else
    ok "asientos 3 y 4 retenidos solo para el tramo 1 → 2"
    PAX2=$(jq -nc --arg c "$([ -n "$CUPON_OK" ] && echo "$CUPON")" --arg h "$(body "$R" | jq -r .holdId)" \
      '{holdId:$h, pasajeros:[{nombre:"Ana Pérez", tipoDocumento:"CC", numeroDocumento:"1020304050", tipoPasajero:"ADULTO"},
                              {nombre:"Tomás Pérez", tipoDocumento:"TI", numeroDocumento:"1122334455", tipoPasajero:"NINO"}]}
       + (if $c == "" then {} else {cupon:$c} end)')
    R=$(req POST /bookings "$PAX" "$PAX2")
    if [ "$(status "$R")" = 503 ] && [ "$(body "$R" | jq -r .error.code)" = PRICING_UNAVAILABLE ]; then
      fail "booking no pudo calcular el precio con catalog (PRICING_UNAVAILABLE): revisa que POST /internal/pricing de catalog y booking usen el mismo contrato"
    elif [ "$(status "$R")" != 201 ]; then fail "reserva del tramo: $R"
    elif [ -z "$(body "$R" | jq -r '.tramo // empty')" ]; then skip "precio por tramo y tipo de pasajero aún no está en develop de booking"
    else
      BKT=$(body "$R" | jq -r .bookingId)
      ok "reserva del tramo $(body "$R" | jq -r '.tramo.paradaAbordaje // .tramo.fromOrden') → $(body "$R" | jq -r '.tramo.paradaBajada // .tramo.toOrden'): total $(body "$R" | jq -r .total) COP"
      [ -n "$CUPON_OK" ] && { [ "$(body "$R" | jq -r '.descuentoCupon // 0 | floor')" -gt 0 ] && ok "cupón aplicado: −$(body "$R" | jq -r .descuentoCupon) COP" || fail "el cupón no descontó: $R"; }
      R=$(req POST "/bookings/$BKT/pay" "$PAX" '{"cardToken":"tok_visa_approved","cardLast4":"4242"}' "Idempotency-Key: smoke56-$S56")
      case "$(status "$R")" in 200|202) PID=$(body "$R" | jq -r .paymentId);; *) fail "pago del tramo: $R";; esac
      confirmada "$BKT"; ok "tramo pagado y CONFIRMADO"
    fi
  fi
fi
if [ -z "$PID" ]; then
  # Sin la compra del tramo: el comprobante del pago del paso 4.
  PID=$(body "${R1:-0 {}}" | jq -r '.paymentId // empty' 2>/dev/null || true)
fi
if [ -z "$PID" ]; then skip "sin un pago para pedir el comprobante"
else
  [ "$(status "$(req GET "/payments/$PID/receipt.pdf" '' '')")" = 401 ] && ok "comprobante sin token → 401" || fail "comprobante público"
  R=$(req GET "/payments/$PID/receipt.pdf" "$PAX" '')
  if nodisp "$R"; then skip "comprobante PDF aún no está en develop de booking"
  elif [ "$(status "$R")" = 200 ] && [ "$(head -c 4 /tmp/tb_body)" = "%PDF" ]; then ok "comprobante de pago en PDF ($(wc -c </tmp/tb_body) bytes)"
  else fail "comprobante: $(status "$R")"; fi
fi

step "Sprints 5 y 6 · ofertas y viaje (US-162, US-181, US-182, US-193)"
step "12.6 Sala de espera de una oferta"
SALA=""; [ -n "${RUTA:-}" ] && SALA=$(viaje DOS_PISOS "${DIA3}T19:00:00Z")
if [ -z "$SALA" ]; then skip "no se pudo programar el viaje de la sala de espera"
else
  LIBRES=""; for i in $(seq 1 15); do
    LIBRES=$(body "$(req GET "/seats/itineraries/$SALA" '' '')" | jq -c '[.asientos[]? | select(.estado=="DISPONIBLE")][0:2] | map(.seatNumber)' 2>/dev/null || true)
    [ "$(echo "$LIBRES" | jq 'length' 2>/dev/null)" = 2 ] && break; sleep 1
  done
  # Inicio en 5 min: la sala abre 10 min antes, así que ya se puede entrar.
  R=$(req POST /offers "$OPER" "{\"itineraryId\":\"$SALA\",\"seatNumbers\":$LIBRES,\"precioOferta\":49900,\"cupo\":2,\"inicio\":\"$(en_seg 300)\",\"fin\":\"$(en_seg 1800)\",\"salaEsperaHabilitada\":true}")
  [ "$(status "$R")" = 201 ] || fail "oferta con sala de espera: $R"; OFS=$(body "$R" | jq -r .offerId)
  if [ "$(body "$R" | jq -r '.salaEsperaHabilitada // empty')" != true ]; then skip "sala de espera aún no está en develop de flash-offers"
  else
    [ "$(status "$(req GET "/offers/$OFS/queue/me" '' '')")" = 401 ] && ok "GET /offers/{id}/queue/me sin token → 401" || fail "sala sin autenticación"
    R=$(req POST "/offers/$OFS/queue" "$PAX" '')
    case "$(status "$R")" in 200|201) ok "PASAJERO entró a la sala de espera";; *) fail "entrar a la sala: $R";; esac
    E=$(body "$(req GET "/offers/$OFS/queue/me" "$PAX" '')" | jq -r .estado)
    [ "$E" = EN_SALA ] && ok "GET /offers/{id}/queue/me → EN_SALA (posición oculta hasta el sorteo)" || fail "estado en la sala: $E"
  fi
  req DELETE "/offers/$OFS" "$OPER" '' >/dev/null || true
fi

step "12.7 Compartir mi viaje (enlace público)"
R=$(req POST /share-links "$PAX" "{\"itineraryId\":\"$IT\"}")
if nodisp "$R"; then skip "/share-links aún no está en develop de fleet"
elif [ "$(status "$R")" = 201 ]; then
  COD=$(body "$R" | jq -r .codigo)
  R=$(req GET "/share/$COD" '' '')
  [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r .itineraryId)" = "$IT" ] && ok "enlace $COD: GET /share/{codigo} sin token → el viaje" || fail "abrir enlace: $R"
  [ "$(status "$(req POST /share-links '' "{\"itineraryId\":\"$IT\"}")")" = 401 ] && ok "crear enlace sin token → 401" || fail "/share-links sin autenticación"
else fail "crear enlace: $R"; fi

step "12.8 Recorrido y puntualidad de un viaje terminado"
if [ -z "${S3_F:-}" ]; then skip "sin el viaje F terminado en 10.8"
else
  R=$(req GET "/itineraries/$S3_F/track" '' '')
  if nodisp "$R"; then skip "GET /itineraries/{id}/track aún no está en develop de fleet"
  elif [ "$(status "$R")" = 200 ]; then ok "recorrido del viaje F sin token → $(body "$R" | jq -r '(.paradas // []) | length') paradas"
  else fail "recorrido: $R"; fi
fi
HOY=$(TZ=America/Bogota date +%F)   # fleet cuenta los días en hora de Colombia
R=$(req GET "/reports/punctuality?desde=$HOY&hasta=$HOY&agrupar=ruta" "$OPER" '')
if nodisp "$R"; then skip "/reports/punctuality aún no está en develop de fleet"
elif [ "$(status "$R")" = 200 ]; then ok "OPERADOR: reporte de puntualidad de hoy por ruta (fleet, no booking)"
else fail "puntualidad: $R"; fi
[ "$(status "$(req GET "/reports/punctuality?desde=$HOY&hasta=$HOY" '' '')")" = 401 ] && ok "puntualidad sin token → 401" || fail "puntualidad pública"

step "12.8b Verificación en dos pasos por el gateway (US-106)"
# /users/me/2fa/* no pasa por auth_request (identity exige el JWT): si MFA_REQUIRED_ROLES obliga al rol, el
# usuario igual puede activarla. Repetir el setup antes de activar solo reemplaza el secreto pendiente.
R=$(req POST /users/me/2fa/setup "$OPER" '')
if nodisp "$R"; then skip "/users/me/2fa/setup aún no está en develop de identity"
elif [ "$(status "$R")" = 200 ] && [ -n "$(body "$R" | jq -r '.otpauthUri // empty')" ]; then ok "OPERADOR: POST /users/me/2fa/setup → otpauthUri para el QR"
elif [ "$(status "$R")" = 409 ]; then ok "OPERADOR ya tiene la 2FA activa (409 MFA_ALREADY_ENABLED)"
else fail "2FA setup: $R"; fi
[ "$(status "$(req POST /users/me/2fa/setup '' '')")" = 401 ] && ok "2FA setup sin token → 401 (lo exige identity)" || fail "2FA setup sin token"
R=$(req POST /auth/2fa '' '{"mfaToken":"no-existe","code":"000000"}')
if nodisp "$R"; then skip "/auth/2fa aún no está en develop de identity"
else [ "$(status "$R")" = 401 ] && ok "POST /auth/2fa con un mfaToken inválido → 401 $(body "$R" | jq -r .error.code)" || fail "/auth/2fa: $R"; fi

step "Sprints 5 y 6 · datos personales y auditoría (US-131, US-105)"
step "12.9 Exportar y eliminar mis datos; auditoría"
read -r DEL_EMAIL DEL_TOKEN <<<"$(nuevo_usuario borrar)"; [ -n "${DEL_TOKEN:-}" ] || fail "no se pudo registrar el usuario a eliminar"
R=$(req GET /users/me/data "$DEL_TOKEN" '')
if nodisp "$R"; then skip "GET /users/me/data aún no está en develop de identity"
elif [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r .perfil.email)" = "$DEL_EMAIL" ]; then ok "exportar mis datos: perfil, $(body "$R" | jq -r '.consentimientos | length') consentimiento(s), sin secretos"
else fail "exportar mis datos: $R"; fi
DEL_ID=$(jwt_sub "$DEL_TOKEN")
R=$(req POST /users/me/delete "$DEL_TOKEN" '{"password":"Passw0rd1","confirmacion":"ELIMINAR"}')
if nodisp "$R"; then skip "POST /users/me/delete aún no está en develop de identity"
elif [ "$(status "$R")" = 204 ]; then
  ok "cuenta eliminada"
  [ "$(status "$(req POST /auth/login '' "{\"email\":\"$DEL_EMAIL\",\"password\":\"Passw0rd1\"}")")" = 401 ] && ok "ya no puede iniciar sesión" || fail "la cuenta eliminada sigue entrando"
  R=$(req GET "/admin/audit?accion=ELIMINAR_CUENTA&size=100" "$ADMIN" '')
  if nodisp "$R"; then skip "/admin/audit aún no está en develop de identity"
  else
    [ "$(body "$R" | jq -r --arg u "$DEL_ID" '[(.content // .)[]? | select(.targetUserId==$u)] | length')" -ge 1 ] \
      && ok "ADMIN ve ELIMINAR_CUENTA en /admin/audit (identity, no catalog)" || fail "auditoría sin la eliminación: $(status "$R")"
  fi
  [ "$(status "$(req GET /admin/audit "$PAX" '')")" = 403 ] && ok "un PASAJERO no ve la auditoría (403)" || fail "auditoría expuesta a un PASAJERO"
else fail "eliminar cuenta: $R"; fi
