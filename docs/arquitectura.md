# TripBus MVP — Arquitectura implementada

Implementación del documento *Arquitectura de Microservicios — MVP Sprint 1* (8 microservicios +
CI/CD + observabilidad) y de las 27 historias del backlog del Sprint 1.

## Decisiones técnicas (y por qué)

| Tema | Decisión en el MVP | Motivo / cuándo cambiarla |
|---|---|---|
| Lenguaje | Java 21 + Spring Boot 3.3.4 en todos los servicios | Mismo stack que `identity`; un solo pipeline. |
| Comunicación síncrona | **REST interno** (`/internal/**` + `X-Internal-Token`) | El doc *recomienda* gRPC para Seat Inventory y Flash Offers; REST mantiene el MVP simple. Los métodos (`HoldSeats`, `ConfirmSale`, `ReserveOfferSeat`…) existen con la misma semántica, así que migrar a gRPC no cambia la lógica. |
| Bus de eventos | **Redis Streams**, un stream `tripbus:events` | Cubre lo que el doc llama "Redis Pub/Sub (MVP)" con entrega fiable: cada servicio lee con su *consumer group* (una réplica procesa cada evento) y el Realtime Gateway lee todo (difusión a todas sus réplicas). Kafka en producción. |
| Base de datos | **Una PostgreSQL por servicio** (6 contenedores `postgres:16-alpine`, cada uno con su volumen, usuario y contraseña) | "PostgreSQL propia" literal: ningún servicio puede leer la base de otro ni siquiera por error de configuración, y cada una se respalda/restaura por separado. Antes era un solo servidor con 6 bases (`infra/postgres/01-databases.sql`, ya eliminado). |
| API Gateway | NGINX (`auth_request` para validar JWT con identity) | Opción listada en el doc; sin dependencias extra. |
| Pasarela de pagos | **Sandbox local** con webhook firmado (HMAC) que además se reenvía duplicado | No hay credenciales de una pasarela real; la interfaz `PaymentGateway` permite cambiarla (Wompi/PayU). |
| Telemetría | Stream `tripbus:telemetry` + consumidor independiente | "Ingesta asíncrona" del doc. TimescaleDB opcional: PostgreSQL + índices. |
| Despliegue | Docker Compose: QA en el PC del desarrollador, PROD en un servidor | Lo más simple que funciona. Los manifiestos de `k8s/` están desactualizados (ver `k8s/README.md`). |

### Diferencias menores frente al documento

- **Identity**: la revocación de tokens (logout) se guarda en la tabla `sesiones_revocadas` de su
  PostgreSQL en lugar de una lista negra en Redis (la base ya se consulta en cada request).
  Se agregó el claim `jti` a los JWT, `POST /auth/logout`, `GET|POST /auth/validate`,
  `GET /users/{id}/roles`, la aceptación obligatoria de la política de datos (`aceptaPoliticaDatos`,
  tabla `consentimientos`) y usuarios de demostración opcionales (`DEMO_USERS_ENABLED`).
- **Catalog**: el precio vive en `itineraries.precio_base` (sin tabla `prices` separada) y el
  "índice de búsqueda" es un índice sobre origen/destino normalizados (sin tildes).
- **Booking**: la saga se orquesta dentro del servicio (llamadas directas a Seat Inventory) en lugar
  de reaccionar a `SeatHeld`/`SeatSold`; el resultado y las compensaciones son los del doc.
- Algunos *payloads* de eventos incluyen campos extra (p. ej. `holdId`, `offerId`, `seatNumbers`)
  necesarios para los consumidores.

## Reglas duras implementadas

| Regla del doc | Dónde |
|---|---|
| Contraseñas con Argon2id, errores genéricos en login | identity (ya existía) |
| JWT firmado RS256, expiración ≤ 60 min, JWKS público | identity; los demás validan con `/.well-known/jwks.json` |
| Búsqueda ordenada por salida, cache Redis 45 s, seed idempotente | catalog `SearchService`, `SearchCache`, `SeedService` (UUID deterministas) |
| 1.ª defensa: lock Redis por asiento TTL 15 s, hash tag `{itinerario:id}`, orden ascendente, fail-fast 500 ms | seat-inventory `DistributedSeatLock` |
| 2.ª defensa: único `(itinerary_id, seat_number)` + trigger que impide revender un asiento vendido | seat-inventory `V1`, `V2__guard_double_sale_trigger.sql` |
| 3.ª defensa: `SELECT … FOR UPDATE` en orden determinista | seat-inventory `SeatStateRepository.lockSeats` |
| Retención 10 min, extensión única ≤ 5 min, barrido en un solo nodo | `Hold`, `ExpiredHoldsSweeper` + `LeaderLock` |
| Idempotency-Key obligatoria (TTL 24 h), webhook idempotente y firmado | booking `IdempotencyService`, `PaymentService.handleWebhook` |
| Nunca guardar el número de tarjeta | booking solo recibe `cardToken` y guarda los últimos 4 |
| Saga con estado persistido + recuperación + conciliación cada 15 min | `saga_log`, `SagaRecoveryJob` |
| Una reserva nunca tiene dos pagos vivos ni dos tiquetes | índices únicos `uq_payments_booking_activo`, `uq_tickets_booking` |
| Contador atómico de cupo en Redis (DECR + revertir con INCR) | flash-offers `QuotaCounter` (script Lua) |
| Idempotencia por `(offerId, userId, docId)` | `uq_offer_sales_persona` |
| Activación/cierre automático por horario | `OfferScheduler` |
| Transactional outbox + idempotencia por `eventId` | fleet `Outbox`, `OutboxRelay` (`FOR UPDATE SKIP LOCKED`) |
| Última posición en Redis, validación mínima de GPS | `TelemetryService` |
| Realtime: sin BD, heartbeat 20 s / cierre a los 45 s, snapshot al suscribirse, JWT en el handshake | `RealtimeHandler`, `HandshakeAuthInterceptor`, `SnapshotService` |
| Control de acceso por rol (US-005) | `@PreAuthorize` en cada servicio + restricción por empresa para operador/conductor |

## Pruebas automáticas

| Repositorio | Pruebas destacadas |
|---|---|
| seat-inventory-service | **US-080**: 500 hilos por el mismo asiento × `CONCURRENCY_RUNS` (100 en CI) → exactamente 1 retención; confirmaciones concurrentes; la BD rechaza una doble venta; extensión y expiración. |
| flash-offerts-service | **US-058**: 1.000 solicitudes concurrentes con cupo 20 → exactamente 20 ventas y el contador nunca < 0. |
| booking-payment-service | Saga completa: 5 reintentos concurrentes del pago = 1 cobro; webhook duplicado = 1 tiquete; pago rechazado libera; asiento perdido ⇒ reembolso. |
| catalog / fleet / realtime / identity | Seed idempotente, búsqueda, ofertas marcadas; outbox; WebSocket con snapshot y difusión; logout y consentimiento. |

Las pruebas `*IT` usan PostgreSQL y Redis reales y se activan con `TRIPBUS_IT=true`
(en local: el `docker-compose.yml` propio de cada servicio levanta su PostgreSQL y Redis).

## Catálogo de eventos (stream `tripbus:events`)

Campos de cada registro: `eventId`, `type`, `source`, `occurredAt`, `payload` (JSON).

| Evento | Publica | Consumen |
|---|---|---|
| `UserRegistered`, `UserLoggedIn` | identity | catalog (auditoría) |
| `ItineraryPublished` (incluye `seatNumbers`) | catalog | seat-inventory (crea asientos), fleet (bus ↔ itinerario) |
| `ItineraryCancelled` | catalog | seat-inventory, fleet, flash-offers |
| `SeatHeld`, `SeatReleased`, `SeatSold`, `HoldExpired`, `SeatStateChanged` | seat-inventory | realtime; booking (`HoldExpired`); flash-offers (retenciones de oferta) |
| `BookingCreated`, `PaymentApproved`, `PaymentFailed`, `TicketIssued`, `RefundProcessed` | booking | seat-inventory (`PaymentFailed`) |
| `OfferCreated`, `OfferActivated`, `OfferClosed`, `OfferSoldOut`, `OfferQuotaUpdated` | flash-offers | catalog (marca ofertas), seat-inventory (`OfferClosed`), realtime |
| `PositionUpdated`, `TripEventReported` | fleet (vía outbox) | realtime |

Tópicos WebSocket: `itinerario:{id}:asientos`, `oferta:{id}:cupo`, `viaje:{id}:eventos`, `bus:{id}:posicion`.

## API interna (servicio a servicio, nunca expuesta por el gateway)

| Servicio | Endpoint | Equivalente del doc |
|---|---|---|
| seat-inventory | `POST /internal/holds` · `GET /internal/holds/{id}` · `POST /internal/holds/{id}/confirm` · `POST /internal/holds/{id}/release` | `HoldSeats`, `ConfirmSale`, `ReleaseHold` |
| seat-inventory | `POST /internal/offers/{id}/seats` · `POST /internal/offers/{id}/release` | reserva de asientos para una oferta |
| flash-offers | `GET /internal/offers/{offerId}/reservations/by-hold/{holdId}` | validar precio de oferta en Booking |

## Puertos (convención v3.1)

| Componente | Puerto | Base de datos (puerto en QA → BD / usuario) |
|---|---|---|
| api-gateway (NGINX) | **18000** | — |
| identity | 18001 | identity-db 18101 → `tripbus_identity` / `identity` |
| catalog-service | 18002 | catalog-db 18102 → `tripbus_catalog` / `catalog` |
| seat-inventory-service | 18003 | seat-inventory-db 18103 → `tripbus_inventory` / `inventory` |
| booking-payment-service | 18004 | booking-db 18104 → `tripbus_booking` / `booking` |
| fleet-trip-events-service | 18005 | fleet-db 18105 → `tripbus_fleet` / `fleet` |
| flash-offers-service | 18006 | offers-db 18106 → `tripbus_offers` / `offers` |
| realtime-gateway | **18007** | sin BD (solo Redis) |
| Redis (compartido, con contraseña) | 18100 | — |

Dentro de la red de Docker cada servicio escucha en su puerto 1800x y cada PostgreSQL en 5432
(`DB_HOST=<servicio>-db`, `DB_PORT=5432`). En QA se publican todos los puertos de la tabla; en PROD
solo 18000 y 18007.
