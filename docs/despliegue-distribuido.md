# Despliegue distribuido en 2 máquinas (escenario de calidad 1.1)

TripBus corre en dos PCs unidas por **Tailscale**. **Catalog** y **Seat Inventory** tienen una réplica en
cada máquina y el API Gateway (NGINX) las balancea con `least_conn`. Si una réplica falla, NGINX la saca
del balanceo y la vuelve a meter sola cuando se recupera.

```
                 Internet ── cloudflared ──┐
                                           ▼
┌──────────────────────── NODO A ────────────────────────┐        ┌──────────────── NODO B ─────────────────┐
│ api-gateway (NGINX :18000)                              │        │ 6 × PostgreSQL (:18101-18106)            │
│   upstream catalog        = catalog-service:18002  ─────┼─ TS ──▶│ Redis (:18100)                           │
│                             + NODO_B_IP:18002           │        │ catalog-service        réplica 2 (:18002)│
│   upstream seat_inventory = seat-inventory-service:18003│        │ seat-inventory-service réplica 2 (:18003)│
│                             + NODO_B_IP:18003           │        │ otel-collector (:4318), tempo, loki,     │
│ identity (:18001) · booking · fleet · flash-offers      │◀─ TS ──┤ promtail, grafana, prometheus, backups   │
│ realtime · frontend · swagger-ui                        │        │   (JWKS de identity y scrape de métricas)│
│ catalog-service y seat-inventory-service réplica 1      │        └──────────────────────────────────────────┘
└─────────────────────────────────────────────────────────┘                 TS = Tailscale (100.x.x.x)
```

| Archivo | Para qué |
|---|---|
| `docker-compose.nodo-a.yml` | Nodo A: entrada, servicios y réplica 1. Hereda (`extends`) de `docker-compose.yml`. |
| `docker-compose.nodo-b.yml` | Nodo B: datos, réplica 2 y observabilidad. Hereda de `docker-compose.yml`. |
| `.env.distribuido.example` | `NODO_A_IP`, `NODO_B_IP` y las interfaces donde se publican los puertos. |
| `infra/prometheus/prometheus.distribuido.yml` | Prometheus del nodo B leyendo los servicios de los dos nodos. |
| `tests/load/failover-catalog.js` | Carga constante sobre Catalog para la prueba del escenario 1.1. |

Los secretos siguen en `.env.prod` (el mismo archivo en las dos máquinas). No se repiten en los archivos nuevos.

## 1. Requisitos (en las dos PCs)

1. **Docker Desktop** encendido (motor Linux/WSL 2).
2. **Tailscale** instalado y con sesión iniciada **con la misma cuenta** en las dos PCs. Anota la IP de
   cada una con `tailscale ip -4` (empieza por `100.`). Comprueba que se ven: `tailscale ping <IP de la otra>`.
3. Este repositorio clonado en las dos PCs (misma rama).
4. `.env.prod` completo (copia de `.env.prod.example` con los secretos reales), **idéntico** en las dos PCs.
5. `.env.distribuido` (copia de `.env.distribuido.example`), idéntico en las dos PCs, con las IPs reales:
   ```dotenv
   NODO_A_IP=100.x.x.x   # tailscale ip -4 en la PC del nodo A
   NODO_B_IP=100.y.y.y   # tailscale ip -4 en la PC del nodo B
   ```
6. Acceso a las imágenes privadas de GHCR en las dos PCs: `docker login ghcr.io` con un PAT `read:packages`.

### Los puertos publicados solo deben ser accesibles por Tailscale

Los dos nodos publican puertos internos (bases de datos, Redis, réplicas, OTLP y los servicios del nodo A).
Los servicios del nodo A, además, **no pasan por la autenticación del gateway**. Nada de eso debe quedar
abierto en la LAN ni en Internet:

- Opción recomendada: `NODO_A_BIND_IP` / `NODO_B_BIND_IP` en `.env.distribuido` con la IP de Tailscale de
  **esa** máquina. Docker publica entonces solo en la interfaz de Tailscale. Si Docker no puede usar esa
  IP ("cannot assign requested address"), deja la variable vacía y usa la opción siguiente.
- Con la variable vacía se publica en `0.0.0.0`: limita los puertos con el firewall de Windows a la red de
  Tailscale (`100.64.0.0/10`) y bloquea el resto de orígenes. Por ejemplo, en el nodo B (PowerShell como administrador):
  ```powershell
  New-NetFirewallRule -DisplayName "TripBus nodo B (solo Tailscale)" -Direction Inbound -Protocol TCP `
    -LocalPort 18100-18106,18002,18003,4318 -RemoteAddress 100.64.0.0/10 -Action Allow
  ```
- Si quieres más control, usa las ACL de Tailscale para que solo el nodo A llegue al nodo B y al revés.

| Nodo | Puerto | Servicio | Quién lo usa |
|---|---|---|---|
| B | 18101-18106 | PostgreSQL de identity, catalog, seat-inventory, booking, fleet y offers | servicios del nodo A |
| B | 18100 | Redis | servicios del nodo A |
| B | 18002 / 18003 | catalog / seat-inventory réplica 2 | NGINX del nodo A |
| B | 4318 | OTLP/HTTP del collector | trazas de los servicios del nodo A |
| A | 18000 | API Gateway | usuarios (y el túnel de Cloudflare) |
| A | 18001 | identity (JWKS) | réplicas del nodo B; Prometheus |
| A | 18002-18007 | servicios internos | Prometheus del nodo B |

Prometheus no recibe tráfico: lee las métricas de los servicios, así que no publica nada.
Grafana tampoco se publica, porque el nodo A no lo necesita. Para abrirlo en el nodo B, agrega en un
override local `ports: ["127.0.0.1:18030:3000"]` al servicio `grafana`, o consulta Prometheus desde su
contenedor (sección 4).

## 2. Orden de arranque y comandos

Siempre **primero el nodo B** (bases de datos, Redis y collector) y **después el nodo A**. Ejecuta los
comandos desde la carpeta del repositorio.

**Nodo B:**

```powershell
docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido pull
docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido up -d
docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido ps
```

Espera a que las 6 bases y Redis estén `healthy`. Las réplicas 2 de catalog y seat-inventory validan los
JWT con identity del nodo A: hasta que el nodo A arranque registrarán errores de JWKS y luego se recuperan solas.

**Nodo A** (`--build`: el gateway se construye desde este repositorio, con la plantilla de dos réplicas):

```powershell
docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido pull --ignore-buildable
docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido up -d --build
docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido ps
```

En el log del gateway debe aparecer:

```
15-upstreams-replicas.envsh: CATALOG_UPSTREAM balanceado (least_conn) entre catalog-service:18002 y 100.y.y.y:18002
15-upstreams-replicas.envsh: SEAT_INVENTORY_UPSTREAM balanceado (least_conn) entre seat-inventory-service:18003 y 100.y.y.y:18003
```

**Apagar:** primero el nodo A y luego el nodo B, cambiando `up -d` por `down` (sin `-v`, que borra los datos).

Para escribir menos, en PowerShell puedes definir una función por nodo:

```powershell
function nodoA { docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido @args }
function nodoB { docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido @args }
# nodoB up -d   ·   nodoA up -d --build   ·   nodoA logs -f api-gateway
```

### Comprobaciones rápidas

```powershell
# Desde el nodo A: el nodo B responde por Tailscale (debe dar UP)
curl.exe -s http://100.y.y.y:18002/actuator/health
# Desde el nodo B: el JWKS de identity del nodo A
curl.exe -s http://100.x.x.x:18001/.well-known/jwks.json
# El gateway de punta a punta
curl.exe -s -o NUL -w "%{http_code}`n" http://localhost:18000/routes
```

### Reglas de este despliegue

- **Solo la réplica de catalog del nodo A puede sembrar datos** (`SEED_ON_STARTUP` de `.env.prod`). La del
  nodo B tiene `SEED_ON_STARTUP=false` fijo en su compose.
- Las dos réplicas comparten la base de datos y Redis del nodo B, así que responden lo mismo.
- NGINX balancea el tráfico **que entra por el gateway**. Las llamadas internas entre servicios del nodo A
  (por ejemplo booking → catalog) van a la réplica local.
- Si seat-inventory tiene tareas programadas (por ejemplo, la expiración de bloqueos), correrán en las dos
  réplicas. Deben ser idempotentes o coordinarse por Redis.
- Los logs de Loki son solo del nodo B (promtail lee el Docker local). Los del nodo A se ven con
  `docker compose ... logs`. Las trazas y las métricas sí incluyen los dos nodos.

## 3. Cómo comprobar que NGINX balancea entre las dos réplicas

Cada línea del access log del gateway es JSON y trae el campo `upstream` (`$upstream_addr`): la IP:puerto
de la réplica que atendió. La réplica 1 aparece con la IP de Docker del nodo A (`172.x.x.x:18002`) y la
réplica 2 con la IP de Tailscale del nodo B (`100.y.y.y:18002`).

```powershell
# Genera tráfico (200 peticiones a Catalog)
1..200 | ForEach-Object { curl.exe -s -o NUL http://localhost:18000/routes }

# Cuenta cuántas atendió cada réplica
docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido logs --no-log-prefix --since 2m api-gateway |
  Select-String '"uri":"/routes' |
  ForEach-Object { ($_.Line | ConvertFrom-Json).upstream } |
  Group-Object | Select-Object Count, Name
```

Las dos direcciones deben aparecer con conteos parecidos. Con `least_conn` el reparto sigue a las
conexiones activas, así que no tiene que ser exactamente 50/50. Para seat-inventory repite lo mismo con una
ruta pública suya (un GET bajo `/seats/...`, por ejemplo el mapa de puestos de un itinerario).

Cuando una petición se reintenta en la otra réplica, `upstream` trae las dos direcciones separadas por
coma (`"100.y.y.y:18002, 172.x.x.x:18002"`): la primera falló y la segunda respondió.

## 4. Prueba del escenario de calidad 1.1

**Estímulo:** la réplica de Catalog del nodo B se detiene durante una prueba de carga.
**Respuesta esperada:** ninguna respuesta 5xx. NGINX retira la réplica en **≤ 10 s** y la reintegra cuando vuelve.

Cómo lo hace NGINX:

- `max_fails=3 fail_timeout=10s`: 3 fallos en 10 s marcan la réplica como caída durante 10 s. Pasado ese
  tiempo prueba una petición real: si responde, vuelve al balanceo; si no, otros 10 s fuera.
- `proxy_next_upstream error timeout http_502 http_503`: la petición que falla se reintenta en la otra
  réplica, así que el cliente no ve el error.
- `proxy_connect_timeout 2s`: una réplica que no responde se descarta en 2 s como máximo.

### Procedimiento

1. Con los dos nodos arriba, comprueba el balanceo (sección 3).
2. **Nodo A, terminal 1:** sigue el log del gateway y guárdalo para analizarlo después:
   ```powershell
   docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido logs -f --no-log-prefix --tail 0 api-gateway |
     Tee-Object -FilePath escenario-1-1.log
   ```
3. **Nodo A, terminal 2:** lanza la carga (50 peticiones/s durante 3 minutos, GET `/routes`):
   ```powershell
   docker run --rm -i --network tripbus-nodo-a_default -v "${PWD}/tests/load:/scripts:ro" grafana/k6:1.2.3 `
     run -e API=http://api-gateway:18000 /scripts/failover-catalog.js
   ```
4. **Nodo B**, unos 30 s después de empezar la carga, anota la hora y detén la réplica:
   ```powershell
   Get-Date -Format o
   docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido stop catalog-service
   ```
5. **Nodo B**, unos 60 s después, anota la hora y arráncala otra vez. Espera a que esté `healthy`:
   ```powershell
   Get-Date -Format o
   docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido start catalog-service
   docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido ps catalog-service
   ```
6. Deja terminar k6 y detén el log (Ctrl+C en la terminal 1).

### Verificación

**a) Cero 5xx.** k6 termina sin umbrales fallidos: `errores_5xx` en 0 y `http_req_failed` en 0.00 %.
En el log del gateway tampoco debe haber ninguno:

```powershell
Get-Content escenario-1-1.log | Select-String '"uri":"/routes' |
  ForEach-Object { $_.Line | ConvertFrom-Json } | Where-Object { $_.status -ge 500 } | Measure-Object
```

**b) Retiro en ≤ 10 s.** Es la diferencia entre la hora del `stop` (paso 4) y la última petición que
todavía intentó la réplica del nodo B. Después de esa línea, el nodo B no debe aparecer hasta que se reintegre:

```powershell
$nodoB = '100.y.y.y:18002'   # NODO_B_IP:18002
$l = Get-Content escenario-1-1.log | Select-String '"uri":"/routes' | ForEach-Object { $_.Line | ConvertFrom-Json }
# Intentos fallidos contra el nodo B: dos direcciones en "upstream", la primera es el nodo B
$l | Where-Object { $_.upstream -like "$nodoB, *" } | Select-Object time, upstream, status
```

Los intentos fallidos se concentran justo después del `stop`. Mientras la réplica está detenida, NGINX
vuelve a probarla una vez cada 10 s (`fail_timeout`): verás un intento aislado cada ~10 s, siempre
reintentado en el nodo A con `status` 200. La réplica queda retirada en cuanto acumula 3 fallos, que con
50 peticiones/s ocurre en menos de 1 s (muy por debajo de 10 s). El log de errores de NGINX lo confirma
con la línea `upstream server temporarily disabled`:

```powershell
docker compose -f docker-compose.nodo-a.yml --env-file .env.prod --env-file .env.distribuido logs --no-log-prefix api-gateway |
  Select-String 'temporarily disabled|connect\(\) failed'
```

**c) Reintegro al volver.** La primera línea con `upstream` igual a solo el nodo B después del `start`.
Debe aparecer a lo sumo 10 s (`fail_timeout`) después de que la réplica esté `healthy`, y desde ahí el
reparto vuelve a ser como en la sección 3:

```powershell
$l | Where-Object { $_.upstream -eq $nodoB } | Select-Object -Last 5 time, upstream, status
```

**d) Métricas (opcional).** Prometheus (nodo B) ve la réplica caída y luego recuperada:

```powershell
docker compose -f docker-compose.nodo-b.yml --env-file .env.prod --env-file .env.distribuido exec prometheus `
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{servicio="catalog-service"}'
```

Debe haber dos series (`nodo="a"` y `nodo="b"`): la del nodo B en 0 mientras estuvo detenida y en 1 al volver.

Resultado esperado: **0 respuestas 5xx**, la réplica sale del balanceo en menos de 10 s y vuelve sola en
menos de 10 s después de estar sana.

## 5. Despliegue de un solo nodo (sin cambios)

`docker-compose.yml` con `docker-compose.qa.yml` o `docker-compose.prod.yml` funciona igual que antes:
`CATALOG_UPSTREAM_2` y `SEAT_INVENTORY_UPSTREAM_2` quedan vacías, la plantilla deja un solo servidor en cada
upstream y el CI y el E2E no cambian. La plantilla usa `resolve` (DNS de Docker) solo para nombres de
contenedor. Una IP (`100.x.x.x:puerto`) se usa tal cual. Lo decide `nginx/entrypoint/15-upstreams-replicas.envsh`
al arrancar el contenedor.
