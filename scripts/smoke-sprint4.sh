# Sprint 4 · ventas y negocio. Funciones/variables base (req/status/body/nodisp/skip)
# vienen de smoke-test.sh. Mailpit es la única dependencia fuera de :18000.
MAILPIT=${MAILPIT_URL:-http://localhost:18025}
S4="$(date +%s)-$RANDOM$RANDOM"

step "Sprint 4 · ventas y negocio"
step "11.1 Identity: correo, verificación, password, refresh y bloqueo"
S4_EMAIL="sprint4.$S4@tripbus.co"; S4_PASS=Passw0rd1
R=$(req POST /auth/register '' "{\"email\":\"$S4_EMAIL\",\"password\":\"$S4_PASS\",\"documentoIdentidad\":\"CC$S4\",\"nombre\":\"Sprint Cuatro\",\"aceptaPoliticaDatos\":true}")
if nodisp "$R"; then skip "registro aún no está en develop de identity"
elif [ "$(status "$R")" = 201 ]; then
  ok "usuario nuevo registrado; se consulta correo en Mailpit"
  MID=""; for i in $(seq 1 15); do
    MID=$(curl -fsS "$MAILPIT/api/v1/messages?limit=50" 2>/dev/null | jq -r --arg e "$S4_EMAIL" '.messages[]? | select((.To // [] | tostring) | contains($e)) | .ID' | head -n1 || true)
    [ -n "$MID" ] && break; sleep 1
  done
  if [ -z "$MID" ]; then skip "correo de verificación no encontrado en $MAILPIT"
  else
    MSG=$(curl -fsS "$MAILPIT/api/v1/message/$MID" 2>/dev/null || true)
    VT=$(echo "$MSG" | grep -oE '[?&]token=[A-Za-z0-9_-]+' | head -n1 | sed 's/^[^=]*=//' || true)
    if [ -z "$VT" ]; then skip "no se pudo extraer token del correo de Mailpit"
    else
      R=$(req POST /auth/verify-email '' "{\"token\":\"$VT\"}")
      if nodisp "$R"; then skip "verificación de email aún no está en develop de identity"
      elif [ "$(status "$R")" -ge 200 ] && [ "$(status "$R")" -lt 300 ]; then
        ok "token del correo verificado"
        R=$(req POST /auth/login '' "{\"email\":\"$S4_EMAIL\",\"password\":\"$S4_PASS\"}")
        S4_ACCESS=$(body "$R" | jq -r '.accessToken // .token // empty'); S4_REFRESH=$(body "$R" | jq -r '.refreshToken // empty')
        if [ -z "$S4_ACCESS" ]; then skip "login verificado no devolvió access token"
        else
          R=$(req PUT /users/me/password "$S4_ACCESS" "{\"passwordActual\":\"$S4_PASS\",\"passwordNueva\":\"Passw0rd2\"}")
          if nodisp "$R"; then skip "cambio de password aún no está en develop de identity"
          elif [ "$(status "$R")" -ge 200 ] && [ "$(status "$R")" -lt 300 ]; then
            [ "$(status "$(req GET /users/me "$S4_ACCESS" '')")" = 401 ] && ok "token viejo → 401" || fail "token viejo no fue revocado al cambiar password"
            R=$(req POST /auth/login '' "{\"email\":\"$S4_EMAIL\",\"password\":\"Passw0rd2\"}")
            S4_ACCESS=$(body "$R" | jq -r '.accessToken // .token // empty'); S4_REFRESH=$(body "$R" | jq -r '.refreshToken // empty')
            [ -n "$S4_ACCESS" ] && [ "$(status "$(req GET /users/me "$S4_ACCESS" '')")" = 200 ] && ok "token nuevo autenticado" || fail "token nuevo no funciona: $R"
          else fail "cambiar password: $R"; fi
        fi
        if [ -n "$S4_REFRESH" ]; then
          R=$(req POST /auth/refresh '' "{\"refreshToken\":\"$S4_REFRESH\"}")
          if nodisp "$R"; then skip "refresh aún no está en develop de identity"
          elif [ "$(status "$R")" = 200 ]; then
            S4_REFRESH_NEW=$(body "$R" | jq -r '.refreshToken // empty')
            [ -n "$S4_REFRESH_NEW" ] && [ "$S4_REFRESH_NEW" != "$S4_REFRESH" ] || fail "refresh no rotó el token: $R"
            R=$(req POST /auth/refresh '' "{\"refreshToken\":\"$S4_REFRESH\"}")
            [ "$(status "$R")" = 401 ] && [ "$(body "$R" | jq -r .error.code)" = REFRESH_TOKEN_REUSED ] && ok "refresh rotado; reuso → 401 REFRESH_TOKEN_REUSED" || fail "reuso de refresh: $R"
          else fail "refresh: $R"; fi
        else skip "no hay refreshToken en respuesta de login"; fi
      elif nodisp "$R"; then skip "POST /auth/verify-email aún no está en develop"
      else fail "verificar email: $R"; fi
    fi
  fi
elif [ "$(status "$R")" = 404 ] || [ "$(status "$R")" = 405 ]; then skip "registro aún no está en develop de identity"
else fail "registro Sprint 4: $R"; fi
for i in $(seq 1 5); do R=$(req POST /auth/login '' "{\"email\":\"$S4_EMAIL\",\"password\":\"incorrecta-$i\"}"); done
if [ "$(status "$R")" = 423 ] && [ "$(body "$R" | jq -r .error.code)" = ACCOUNT_LOCKED ]; then ok "5 logins fallidos → 423 ACCOUNT_LOCKED"
else skip "bloqueo de cuenta no disponible/verificable (última respuesta: $(status "$R"))"; fi

step "11.2 Catalog: búsqueda, panel operador y comisión"
R=$(req GET "/trips/search?origin=Bogota&destination=Medellin&date=$FECHA&franja=MANANA&sort=precio" '' '')
if nodisp "$R"; then skip "búsqueda con filtros aún no está en develop de catalog"
elif [ "$(status "$R")" = 200 ]; then
  H=$(curl -s -D - -o /dev/null "$API/trips/search?origin=Bogota&destination=Medellin&date=$FECHA&franja=MANANA&sort=precio" | tr -d '\r' | grep -i '^X-Total-Count:' || true)
  [ -n "$H" ] && ok "búsqueda sort=precio y franja devuelve $H" || fail "falta X-Total-Count"
else fail "búsqueda Sprint 4: $R"; fi
R=$(req GET /operator/trips "$OPER" ''); if nodisp "$R"; then skip "/operator/trips aún no está en develop de catalog"; elif [ "$(status "$R")" = 200 ]; then ok "OPERADOR ve /operator/trips y ocupación"; else fail "panel operador: $R"; fi
R=$(req POST /admin/commission-validities "$ADMIN" "{\"porcentaje\":5,\"vigenteDesde\":\"$(date +%F)\"}")
if nodisp "$R"; then skip "vigencia de comisión aún no está en develop de catalog"; elif [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 201 ]; then ok "ADMIN agregó vigencia de comisión"; else fail "comisión: $R"; fi

step "11.3 Ofertas: CRUD operador, showcase, follows y métricas"
R=$(req POST /operator/offers "$OPER" "{\"itineraryId\":\"$IT\",\"seatNumbers\":$LIBRES,\"precioOferta\":45000,\"cupo\":2,\"inicio\":\"$(en_seg 120)\",\"fin\":\"$FIN\"}")
S4_OF=""
if nodisp "$R"; then skip "gestión /operator/offers aún no está en develop de flash-offers"
elif [ "$(status "$R")" = 201 ]; then
  S4_OF=$(body "$R" | jq -r '.offerId // .id'); ok "OPERADOR creó $S4_OF"
  R=$(req PATCH "/operator/offers/$S4_OF" "$OPER" '{"precioOferta":44000}')
  if nodisp "$R"; then skip "edición de ofertas aún no está disponible"; elif [ "$(status "$R")" = 200 ]; then ok "oferta editada"; else fail "editar oferta: $R"; fi
  R=$(req POST "/operator/offers/$S4_OF/duplicate" "$OPER" '')
  if nodisp "$R"; then skip "duplicado de ofertas aún no está disponible"; elif [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 201 ]; then ok "oferta duplicada"; else fail "duplicar oferta: $R"; fi
  R=$(req POST /operator/offers "$OPER" "{\"itineraryId\":\"$IT\",\"seatNumbers\":$LIBRES,\"precioOferta\":6500,\"cupo\":2,\"inicio\":\"$(en_seg 120)\",\"fin\":\"$FIN\"}")
  if [ "$(status "$R")" = 400 ] && [ "$(body "$R" | jq -r .error.code)" = INVALID_DISCOUNT ]; then ok "90 % → 400 INVALID_DISCOUNT"; elif nodisp "$R"; then skip "validación de descuento aún no disponible"; else fail "descuento 90%: $R"; fi
else fail "crear oferta: $R"; fi
R=$(req GET /offers/showcase '' ''); if nodisp "$R"; then skip "/offers/showcase aún no está en develop"; elif [ "$(status "$R")" = 200 ]; then ok "showcase público responde sin token"; else fail "showcase: $R"; fi
R=$(req POST /offers/follows '' '{"itineraryId":"smoke"}'); if [ "$(status "$R")" = 401 ]; then ok "/offers/follows sin token → 401"; elif nodisp "$R"; then skip "/offers/follows aún no está en develop"; else fail "follows sin token: $R"; fi
if [ -n "$S4_OF" ]; then R=$(req GET "/offers/$S4_OF/metrics" "$OPER" ''); if nodisp "$R"; then skip "métricas aún no están en develop"; elif [ "$(status "$R")" = 200 ]; then ok "métricas de oferta para OPERADOR"; else fail "métricas: $R"; fi; fi

cerrar_ofertas_de "$IT"   # las ofertas de 11.3 (y su duplicado) no deben bloquear la próxima ejecución

step "11.4 Lista de espera"
R=$(req GET "/seats/itineraries/$IT/occupancy" "$OPER" '')
if nodisp "$R"; then skip "ocupación/lista de espera aún no está en develop de seat-inventory"
elif [ "$(status "$R")" = 200 ]; then
  # El token de $OTRO ya fue revocado por el logout de smoke-test.sh: se registra un pasajero nuevo.
  R=$(req POST /auth/register '' "{\"email\":\"smoke.$RANDOM$RANDOM@tripbus.co\",\"password\":\"Passw0rd1\",\"documentoIdentidad\":\"CC$RANDOM$RANDOM\",\"nombre\":\"Lista Espera\",\"aceptaPoliticaDatos\":true}")
  [ "$(status "$R")" = 201 ] || fail "registro para lista de espera: $R"; S4_ESPERA=$(body "$R" | jq -r .accessToken)
  R=$(req POST "/seats/itineraries/$IT/waitlist" "$S4_ESPERA" '{"cantidad":1}')
  # Solo se entra a la lista si el viaje no tiene cupo: con asientos libres responde 409 SEATS_AVAILABLE.
  if nodisp "$R"; then skip "inscripción a lista de espera aún no está en develop"
  elif [ "$(status "$R")" = 201 ]; then ok "otro pasajero se anotó en la lista de espera"
  elif [ "$(status "$R")" = 409 ] && [ "$(body "$R" | jq -r '.error.code // empty' 2>/dev/null)" = SEATS_AVAILABLE ]; then ok "con asientos libres la lista de espera rechaza la inscripción (409 SEATS_AVAILABLE)"
  else fail "lista de espera: $R"; fi
else fail "ocupación: $R"; fi

step "11.5 Pagos: NEQUI y PSE/sandbox"
s4_libre() { body "$(req GET "/seats/itineraries/$IT" '' '')" | jq -r '[.asientos[] | select(.estado=="DISPONIBLE")][0].seatNumber // empty'; }
s4_reserva() { # retiene 1 asiento libre de $IT y crea la reserva del PASAJERO → S4_BK
  local a r; S4_BK=""; a=$(s4_libre); [ -n "$a" ] || fail "no quedan asientos libres en $IT"
  r=$(req POST /seats/holds "$PAX" "{\"itineraryId\":\"$IT\",\"seatNumbers\":[\"$a\"]}")
  [ "$(status "$r")" = 201 ] || fail "retención para $1: $r"
  r=$(req POST /bookings "$PAX" "{\"holdId\":\"$(body "$r" | jq -r .holdId)\",\"pasajeros\":[{\"nombre\":\"Smoke $1\",\"tipoDocumento\":\"CC\",\"numeroDocumento\":\"1020304050\"}]}")
  [ "$(status "$r")" = 201 ] || fail "reserva para $1: $r"; S4_BK=$(body "$r" | jq -r .bookingId)
}
s4_espera() { # reserva → espera hasta 20 s a CONFIRMADA y deja el estado en S4_EST
  local i; for i in $(seq 1 20); do
    S4_EST=$(body "$(req GET "/bookings/$1" "$PAX" '')" | jq -r '.estado // empty'); [ "$S4_EST" = CONFIRMADA ] && return 0; sleep 1
  done; return 1
}
s4_pagar() { req POST "/bookings/$1/pay" "$PAX" "$2" "Idempotency-Key: smoke4-$(date +%s)-$RANDOM"; }

R=$(req GET /payments/pse/banks '' ''); if nodisp "$R"; then skip "bancos PSE aún no están en develop de booking"; elif [ "$(status "$R")" = 200 ]; then ok "GET público /payments/pse/banks"; else fail "bancos PSE: $R"; fi

s4_reserva "NEQUI aprobado"
R=$(s4_pagar "$S4_BK" '{"metodo":"NEQUI","nequi":{"telefono":"3991111111"}}')
case "$(status "$R")" in 200|202) ok "pago NEQUI 3991111111 enviado";; *) fail "pago NEQUI 3991111111: $R";; esac
s4_espera "$S4_BK" && ok "reserva NEQUI $S4_BK CONFIRMADA" || fail "la reserva NEQUI $S4_BK quedó en $S4_EST"

s4_reserva "NEQUI rechazado"
R=$(s4_pagar "$S4_BK" '{"metodo":"NEQUI","nequi":{"telefono":"3992222222"}}')
if [ "$(status "$R")" = 402 ] || [ "$(body "$R" | jq -r '.estado // empty' 2>/dev/null)" = RECHAZADO ]; then ok "NEQUI 3992222222 rechazado ($(status "$R"))"
elif [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 202 ]; then
  s4_espera "$S4_BK" && fail "NEQUI 3992222222 debía rechazarse y la reserva quedó CONFIRMADA" || ok "NEQUI 3992222222 rechazado: la reserva quedó en $S4_EST"
else fail "pago NEQUI 3992222222: $R"; fi

s4_reserva "PSE"
R=$(s4_pagar "$S4_BK" '{"metodo":"PSE","pse":{"bancoCodigo":"1","tipoPersona":"NATURAL","tipoDocumento":"CC","numeroDocumento":"12345678"}}')
case "$(status "$R")" in 200|202) ;; *) fail "pago PSE: $R";; esac
S4_PSE_URL=$(body "$R" | jq -r '.redirectUrl // empty'); [ -n "$S4_PSE_URL" ] || fail "pago PSE sin redirectUrl: $R"
S4_PSE_ID=${S4_PSE_URL##*/sandbox/pse/}; ok "pago PSE iniciado con banco 1 → $S4_PSE_URL"
R=$(req GET "/sandbox/pse/$S4_PSE_ID" '' '')
[ "$(status "$R")" = 200 ] && body "$R" | grep -qi 'Banco de prueba' && ok "página bancaria sandbox pública (Banco de prueba)" || fail "GET sandbox PSE: $(status "$R") $(body "$R" | head -c 200)"
R=$(req POST "/sandbox/pse/$S4_PSE_ID?action=approve" '' '')
[ "$(status "$R")" = 302 ] && ok "sandbox PSE aprobó el pago (302)" || fail "aprobar en sandbox PSE: $R"
s4_espera "$S4_BK" && ok "reserva PSE $S4_BK CONFIRMADA" || fail "la reserva PSE $S4_BK quedó en $S4_EST"

step "11.6 Taquilla y tiquete PDF"
S4_TQ=$(s4_libre); [ -n "$S4_TQ" ] || fail "no quedan asientos libres en $IT para la taquilla"
R=$(req POST /box-office/sales "$OPER" "{\"itineraryId\":\"$IT\",\"seatNumbers\":[\"$S4_TQ\"],\"pasajeros\":[{\"nombre\":\"Taquilla Smoke\",\"tipoDocumento\":\"CC\",\"numeroDocumento\":\"1234567\"}],\"comprador\":{\"nombre\":\"Taquilla Smoke\",\"email\":\"taquilla.smoke@tripbus.co\",\"telefono\":\"3001234567\"}}" "Idempotency-Key: smoke4-taquilla-$(date +%s)-$RANDOM")
if nodisp "$R"; then skip "venta en taquilla aún no está en develop de booking"; elif [ "$(status "$R")" = 201 ]; then
  ok "OPERADOR vendió el asiento $S4_TQ en taquilla"
  R=$(req GET /box-office/sales "$OPER" '')
  [ "$(status "$R")" = 200 ] && ok "cierre de caja: GET /box-office/sales" || fail "cierre de caja: $R"
else fail "taquilla: $R"; fi
R=$(req GET "/tickets/$TK/pdf" "$PAX" ''); if nodisp "$R"; then skip "PDF de tiquete aún no está en develop de booking"; elif [ "$(status "$R")" = 200 ]; then
  T=$(curl -s -D - -o /tmp/tb_ticket.pdf -H "Authorization: Bearer $PAX" "$API/tickets/$TK/pdf" | tr -d '\r' | grep -i '^Content-Type:' || true)
  echo "$T" | grep -qi 'application/pdf' && ok "PDF devuelve application/pdf" || fail "Content-Type PDF: $T"
else fail "PDF tiquete: $R"; fi

step "11.7 Reportes"
# booking cuenta los días en hora de Colombia: desde ayer hasta hoy (America/Bogota), no en UTC del runner.
S4_HOY=$(TZ=America/Bogota date +%F); S4_AYER=$(TZ=America/Bogota date -d yesterday +%F 2>/dev/null || TZ=America/Bogota date -v-1d +%F)
R=$(req GET "/reports/sales?desde=$S4_AYER&hasta=$S4_HOY&agrupar=metodo" "$ADMIN" ''); if nodisp "$R"; then skip "reportes de ventas aún no están en develop de booking"; elif [ "$(status "$R")" = 200 ]; then
  [ "$(body "$R" | jq '.grupos | length')" -gt 0 ] || fail "reporte de ventas sin grupos: $R"
  body "$R" | jq -e '.totales | has("comisionTripBus")' >/dev/null || fail "reporte de ventas sin comisionTripBus: $R"
  ok "reporte por método: $(body "$R" | jq -r '[.grupos[].grupo] | join(", ")') con comisión $(body "$R" | jq -r .totales.comisionTripBus) COP"
else fail "reporte ventas: $R"; fi
R=$(req GET "/reports/platform?mes=$(TZ=America/Bogota date +%Y-%m)" "$ADMIN" ''); if nodisp "$R"; then skip "reporte de plataforma aún no está en develop"; elif [ "$(status "$R")" = 200 ]; then ok "ADMIN consultó reporte de plataforma del mes"; else fail "reporte plataforma: $R"; fi

step "11.8 Flota y WebSocket"
# El conductor solo comparte ubicación de un viaje suyo EN CURSO (10.8 ya finalizó y liberó el suyo):
# se programa un viaje que sale en 10 min, se le asigna, se inicia y al final siempre se finaliza y se libera.
S4_V=""; S4_V_ASIG=""
s4_limpiar_viaje() {
  [ -n "$S4_V" ] && req POST "/driver/trips/$S4_V/finish" "$COND" '' >/dev/null 2>&1 || true
  [ -n "$S4_V_ASIG" ] && req DELETE "/trips/$S4_V/driver/PRINCIPAL" "$OPER" '' >/dev/null 2>&1 || true
}
s4_ubicacion() { req POST /driver/location "$COND" "{\"itineraryId\":\"$S4_V\",\"lat\":4.65,\"lng\":-74.1,\"precision\":8,\"velocidad\":0,\"timestamp\":\"$(date -u +%FT%TZ)\"}"; }
[ -n "$RUTA" ] && S4_V=$(viaje UN_PISO "$(date -u -d '+10 min' +%FT%TZ 2>/dev/null || date -u -v+10M +%FT%TZ)")
if [ -z "$S4_V" ]; then skip "sin ruta o sin viaje programado: se omite flota en vivo y WebSocket de flota"
else
  trap s4_limpiar_viaje EXIT   # si un fail corta el script, el viaje igual se finaliza y se libera
  R=$(asignar "$S4_V"); [ "$(status "$R")" = 200 ] || fail "asignar conductor al viaje de flota: $R"; S4_V_ASIG=1
  ok "conductor@tripbus.co asignado al viaje $S4_V (sale en 10 min)"
  R=$(req POST "/driver/trips/$S4_V/start" "$COND" '{"checklist":{"manifiestoRevisado":true,"documentosBus":true,"lucesYLlantas":true,"botiquinYExtintor":true}}')
  [ "$(status "$R")" = 200 ] || fail "iniciar viaje de flota: $R"; ok "viaje $S4_V iniciado con el checklist completo"
  R=$(s4_ubicacion); [ "$(status "$R")" = 202 ] || fail "compartir ubicación: $R"; ok "el conductor compartió su ubicación (202)"
  for i in $(seq 1 10); do R=$(req GET /fleet/live "$OPER" ''); [ "$(status "$R")" = 200 ] && body "$R" | grep -q "$S4_V" && break; nodisp "$R" && break; sleep 1; done
  if nodisp "$R"; then skip "/fleet/live aún no está en develop de fleet"; elif [ "$(status "$R")" = 200 ] && body "$R" | grep -q "$S4_V"; then ok "OPERADOR ve el viaje con conductor compartiendo ubicación"; elif [ "$(status "$R")" = 200 ]; then skip "viaje no apareció todavía en /fleet/live"; else fail "fleet live: $R"; fi
fi
if ! command -v websocat >/dev/null 2>&1; then skip "WebSocket Sprint 4 omitido: websocat no está instalado"
else
  S4_WS=/tmp/tb_ws_sprint4; (printf '{"type":"subscribe","topic":"ofertas:activas"}\n'; sleep 3) | timeout 5 websocat -t "${API/http/ws}/ws" >"$S4_WS" 2>/dev/null & S4_WSP=$!; sleep 2
  if grep -q 'snapshot\|ofertas:activas' "$S4_WS"; then ok "ofertas:activas entregó snapshot"; else skip "snapshot de ofertas no disponible en realtime"; fi
  kill "$S4_WSP" 2>/dev/null || true; wait "$S4_WSP" 2>/dev/null || true
  CO_ID=$(body "$(req GET /users/me "$OPER" '')" | jq -r '.companyId // .empresaId // empty')
  if [ -n "$CO_ID" ]; then
    S4_WS=/tmp/tb_ws_fleet; (printf '{"type":"connect","token":"%s"}\n' "$OPER"; sleep 1; printf '{"type":"subscribe","topic":"empresa:%s:flota"}\n' "$CO_ID"; sleep 3) \
      | timeout 6 websocat -t "${API/http/ws}/ws" >"$S4_WS" 2>/dev/null & S4_WSP=$!
    # ~1 s después de suscribirse se envía otra posición para que llegue dentro de la ventana de flota.
    [ -n "$S4_V" ] && { sleep 2; s4_ubicacion >/dev/null; } & S4_LOCP=$!
    sleep 3
    if grep -q 'empresa:.*:flota\|"lat"\|"lng"\|posicion' "$S4_WS"; then ok "OPERADOR recibió posición en empresa:$CO_ID:flota"; else skip "sin posición en empresa:{id}:flota durante esta ventana"; fi
    kill "$S4_WSP" 2>/dev/null || true; wait "$S4_WSP" "$S4_LOCP" 2>/dev/null || true
  else skip "no se pudo obtener empresa del OPERADOR para suscripción de flota"; fi
fi
s4_limpiar_viaje; trap - EXIT; S4_V=""; S4_V_ASIG=""
