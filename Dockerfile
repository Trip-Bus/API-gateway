# API Gateway de TripBus: NGINX con plantillas (envsubst al iniciar el contenedor).
# NGINX >= 1.27.3 es obligatorio: desde esa versión el open source soporta "server ... resolve" en los
# upstream (re-resuelve el DNS de los servicios mientras corre). Se fija la versión exacta: rama
# mainline 1.29.x (la estable 1.28.3 trae CVE HIGH del paquete nginx sin parche en nginx.org).
FROM nginx:1.29.8-alpine

# Parches de seguridad de los paquetes de Alpine publicados después de la imagen base (Trivy los
# exige: CRITICAL/HIGH con corrección disponible). No cambia la versión de NGINX.
RUN apk upgrade --no-cache

COPY nginx/templates/ /etc/nginx/templates/
# Corre después de 20-envsubst-on-templates.sh: genera el map de orígenes CORS permitidos.
COPY --chmod=755 nginx/entrypoint/25-cors-origins.sh /docker-entrypoint.d/25-cors-origins.sh

# Valores por defecto (nombres de servicio de docker-compose). En compose/Kubernetes se pueden cambiar.
#  RESOLVER: DNS interno de Docker (127.0.0.11); valid=10s = vuelve a preguntar la IP cada 10 s.
#  CORS_ALLOWED_ORIGIN: lista separada por comas; sin '*' por defecto.
ENV GATEWAY_PORT=18000 \
    RESOLVER="127.0.0.11 valid=10s ipv6=off" \
    IDENTITY_UPSTREAM=identity:18001 \
    CATALOG_UPSTREAM=catalog-service:18002 \
    SEAT_INVENTORY_UPSTREAM=seat-inventory-service:18003 \
    BOOKING_UPSTREAM=booking-payment-service:18004 \
    FLEET_UPSTREAM=fleet-trip-events-service:18005 \
    FLASH_OFFERS_UPSTREAM=flash-offers-service:18006 \
    CORS_ALLOWED_ORIGIN=http://localhost:5173 \
    RATE_LIMIT_PER_IP=30r/s \
    RATE_LIMIT_PER_USER=10r/s \
    RATE_LIMIT_AUTH=5r/s

EXPOSE 18000
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:${GATEWAY_PORT}/health || exit 1
