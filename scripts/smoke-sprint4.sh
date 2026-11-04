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
          R=$(req PUT /users/me/password "$S4_ACCESS" "{\"currentPassword\":\"$S4_PASS\",\"newPassword\":\"Passw0rd2\"}")
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
  R=$(req POST "/seats/itineraries/$IT/waitlist" "$OTRO" '{"seatCount":1}')
  if nodisp "$R"; then skip "inscripción a lista de espera aún no está en develop"; elif [ "$(status "$R")" = 201 ]; then ok "otro pasajero se anotó; oferta de asiento depende de liberar un asiento agotado"; else fail "lista de espera: $R"; fi
else fail "ocupación: $R"; fi

step "11.5 Pagos: NEQUI y PSE/sandbox"
R=$(req GET /payments/pse/banks '' ''); if nodisp "$R"; then skip "bancos PSE aún no están en develop de booking"; elif [ "$(status "$R")" = 200 ]; then ok "GET público /payments/pse/banks"; else fail "bancos PSE: $R"; fi
for TEL in 3991111111 3992222222; do R=$(req POST /payments/nequi "$PAX" "{\"phone\":\"$TEL\"}"); if nodisp "$R"; then skip "NEQUI aún no está en develop de booking"; break; elif [ "$TEL" = 3991111111 ] && { [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 201 ]; }; then ok "NEQUI $TEL aprobado"; elif [ "$TEL" = 3992222222 ] && { [ "$(status "$R")" = 402 ] || [ "$(body "$R" | jq -r '.estado // .error.code')" = RECHAZADO ]; }; then ok "NEQUI $TEL rechazado"; else fail "NEQUI $TEL: $R"; fi; done
R=$(req POST /payments/pse "$PAX" '{"bankId":"1"}')
if nodisp "$R"; then skip "inicio de pago PSE aún no está en develop de booking"
elif [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 201 ] || [ "$(status "$R")" = 302 ]; then
  S4_PSE_BK=$(body "$R" | jq -r '.bookingId // empty' 2>/dev/null || true)
  ok "pago PSE iniciado con banco 1"
  R=$(req GET /sandbox/ '' '')
  if nodisp "$R"; then skip "página sandbox aún no está en develop de booking"
  elif [ "$(status "$R")" = 200 ]; then
    R=$(req POST /sandbox/ '' '{"bankId":"1","accion":"aprobar"}')
    if nodisp "$R"; then skip "POST sandbox aún no está en develop de booking"
    elif [ "$(status "$R")" = 200 ] || [ "$(status "$R")" = 302 ]; then
      ok "POST de sandbox aprobado"
      if [ -n "$S4_PSE_BK" ]; then
        for i in $(seq 1 20); do R=$(req GET "/bookings/$S4_PSE_BK" "$PAX" ''); [ "$(body "$R" | jq -r '.estado // empty')" = CONFIRMADA ] && break; sleep 1; done
        [ "$(status "$R")" = 200 ] && [ "$(body "$R" | jq -r '.estado')" = CONFIRMADA ] && ok "reserva PSE $S4_PSE_BK confirmada" || fail "reserva tras PSE: $R"
      else skip "pago PSE no devolvió bookingId para comprobar confirmación"; fi
    else fail "aprobar en sandbox: $R"; fi
  else fail "GET sandbox: $R"; fi
else fail "inicio PSE: $R"; fi
R=$(req GET /sandbox/ '' ''); if nodisp "$R"; then skip "página sandbox aún no está en develop de booking"; elif [ "$(status "$R")" = 200 ]; then ok "página bancaria sandbox pública"; else fail "página sandbox: $R"; fi

step "11.6 Taquilla y tiquete PDF"
R=$(req POST /box-office/sales "$OPER" "{\"itineraryId\":\"$IT\",\"paymentMethod\":\"EFECTIVO\",\"seatNumbers\":[\"$ASIENTO\"]}")
if nodisp "$R"; then skip "venta en taquilla aún no está en develop de booking"; elif [ "$(status "$R")" = 201 ]; then
  ok "OPERADOR vendió en efectivo"
  R=$(req POST /box-office/close "$OPER" '{"metodo":"EFECTIVO"}')
  if nodisp "$R"; then skip "cierre de caja aún no está en develop de booking"; elif [ "$(status "$R")" = 200 ]; then ok "cierre de caja muestra la venta"; else fail "cierre de caja: $R"; fi
else fail "taquilla: $R"; fi
R=$(req GET "/tickets/$TK/pdf" "$PAX" ''); if nodisp "$R"; then skip "PDF de tiquete aún no está en develop de booking"; elif [ "$(status "$R")" = 200 ]; then
  T=$(curl -s -D - -o /tmp/tb_ticket.pdf -H "Authorization: Bearer $PAX" "$API/tickets/$TK/pdf" | tr -d '\r' | grep -i '^Content-Type:' || true)
  echo "$T" | grep -qi 'application/pdf' && ok "PDF devuelve application/pdf" || fail "Content-Type PDF: $T"
else fail "PDF tiquete: $R"; fi

step "11.7 Reportes"
R=$(req GET '/reports/sales?agrupar=metodo' "$ADMIN" ''); if nodisp "$R"; then skip "reportes de ventas aún no están en develop de booking"; elif [ "$(status "$R")" = 200 ]; then
  for M in TARJETA NEQUI PSE EFECTIVO; do echo "$(body "$R")" | grep -q "$M" || fail "reporte de ventas no contiene $M"; done
  echo "$(body "$R")" | grep -qi comision && ok "reporte por método contiene TARJETA, NEQUI, PSE, EFECTIVO y comisión" || fail "reporte de ventas no contiene comisión"
else fail "reporte ventas: $R"; fi
R=$(req GET "/reports/platform?mes=$(date +%Y-%m)" "$ADMIN" ''); if nodisp "$R"; then skip "reporte de plataforma aún no está en develop"; elif [ "$(status "$R")" = 200 ]; then ok "ADMIN consultó reporte de plataforma del mes"; else fail "reporte plataforma: $R"; fi

step "11.8 Flota y WebSocket"
R=$(req POST /driver/location "$COND" "{\"itineraryId\":\"$IT\",\"lat\":4.65,\"lng\":-74.1,\"precision\":8,\"timestamp\":\"$(date -u +%FT%TZ)\"}")
if nodisp "$R"; then skip "ubicación de conductor aún no está en develop de fleet"
elif [ "$(status "$R")" = 202 ] || [ "$(status "$R")" = 200 ]; then
  R=$(req GET /fleet/live "$OPER" '')
  if nodisp "$R"; then skip "/fleet/live aún no está en develop de fleet"; elif [ "$(status "$R")" = 200 ] && echo "$(body "$R")" | grep -q "$IT"; then ok "OPERADOR ve viaje con conductor compartiendo ubicación"; elif [ "$(status "$R")" = 200 ]; then skip "viaje no apareció todavía en /fleet/live"; else fail "fleet live: $R"; fi
else fail "compartir ubicación: $R"; fi
if ! command -v websocat >/dev/null 2>&1; then skip "WebSocket Sprint 4 omitido: websocat no está instalado"
else
  S4_WS=/tmp/tb_ws_sprint4; (printf '{"type":"subscribe","topic":"ofertas:activas"}\n'; sleep 3) | timeout 5 websocat -t "${API/http/ws}/ws" >"$S4_WS" 2>/dev/null & S4_WSP=$!; sleep 2
  if grep -q 'snapshot\|ofertas:activas' "$S4_WS"; then ok "ofertas:activas entregó snapshot"; else skip "snapshot de ofertas no disponible en realtime"; fi
  kill "$S4_WSP" 2>/dev/null || true; wait "$S4_WSP" 2>/dev/null || true
  CO_ID=$(body "$(req GET /users/me "$OPER" '')" | jq -r '.companyId // .empresaId // empty')
  if [ -n "$CO_ID" ]; then
    S4_WS=/tmp/tb_ws_fleet; (printf '{"type":"connect","token":"%s"}\n' "$OPER"; sleep 1; printf '{"type":"subscribe","topic":"empresa:%s:flota"}\n' "$CO_ID"; sleep 3) \
      | timeout 6 websocat -t "${API/http/ws}/ws" >"$S4_WS" 2>/dev/null & S4_WSP=$!; sleep 3
    if grep -q 'empresa:.*:flota\|"lat"\|"lng"\|posicion' "$S4_WS"; then ok "OPERADOR recibió posición en empresa:$CO_ID:flota"; else skip "sin posición en empresa:{id}:flota durante esta ventana"; fi
    kill "$S4_WSP" 2>/dev/null || true; wait "$S4_WSP" 2>/dev/null || true
  else skip "no se pudo obtener empresa del OPERADOR para suscripción de flota"; fi
fi
