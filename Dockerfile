# API Gateway de TripBus: NGINX con plantillas (envsubst al iniciar el contenedor).
FROM nginx:1.27-alpine

COPY nginx/templates/ /etc/nginx/templates/

# Valores por defecto (nombres de servicio de docker-compose / Kubernetes).
ENV GATEWAY_PORT=8080 \
    IDENTITY_UPSTREAM=identity:16001 \
    CATALOG_UPSTREAM=catalog-service:16002 \
    SEAT_INVENTORY_UPSTREAM=seat-inventory-service:16003 \
    BOOKING_UPSTREAM=booking-payment-service:16004 \
    FLEET_UPSTREAM=fleet-trip-events-service:16005 \
    FLASH_OFFERS_UPSTREAM=flash-offers-service:16006 \
    CORS_ALLOWED_ORIGIN=* \
    RATE_LIMIT_PER_IP=30r/s \
    RATE_LIMIT_PER_USER=10r/s \
    RATE_LIMIT_AUTH=5r/s

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -qO- http://localhost:8080/health || exit 1
