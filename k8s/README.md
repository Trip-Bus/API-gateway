# k8s/ — TripBus en Kubernetes (kustomize, HT-06)

PROD y QA siguen corriendo con **Docker Compose** (README raíz). Estos manifiestos describen la misma
plataforma para un clúster de Kubernetes y el CI los valida en cada cambio (`kustomize build` +
`kubeconform`, sin clúster).

```
k8s/
  base/                     # todo lo común (namespace tripbus)
    namespace.yaml
    config.yaml             # ConfigMap tripbus-config (servicios Java) y gateway-config (NGINX)
    secrets.yaml            # PLANTILLAS de Secret (tripbus-secrets, identity-jwt-keys): sin valores reales
    redis.yaml              # StatefulSet + Service, con contraseña y AOF
    postgres/<svc>-db.yaml  # 6 StatefulSet de PostgreSQL 16 (uno por servicio) con su volumen de 2 Gi
    servicios/<svc>.yaml    # 7 Deployment + Service de los microservicios
    frontend.yaml           # SPA (NGINX :80)
    api-gateway.yaml        # NGINX :18000 (frontend, REST, /api/v1, /ws)
  overlays/
    qa/                     # namespace tripbus-qa, imágenes :qa (frontend :develop), perfil qa, 1 réplica
    prod/                   # namespace tripbus, imágenes :prod (frontend :main), 2 réplicas, LoadBalancer
```

| Componente | Tipo | Puerto | Probes | Recursos (request → limit) |
|---|---|---|---|---|
| 7 microservicios | Deployment + Service | 18001–18007 | `startupProbe` y `livenessProbe` en `/actuator/health/liveness`, `readinessProbe` en `/actuator/health/readiness` | 200m / 512Mi → 1 CPU / 640Mi (realtime 512Mi) |
| api-gateway | Deployment + Service | 18000 | `/health` | 50m / 64Mi → 500m / 128Mi |
| frontend | Deployment + Service | 80 | `/salud` | 20m / 32Mi → 200m / 64Mi |
| redis | StatefulSet + Service headless | 6379 | `redis-cli ping` | 50m / 128Mi → 256Mi |
| 6 PostgreSQL | StatefulSet + Service headless | 5432 | `pg_isready` | 100m / 256Mi → 512Mi |

Los servicios Java leen la configuración común con `envFrom: tripbus-config` (perfil, Redis, JWKS,
`OPENAPI_SERVER_URL=/api/v1`, dominios, `LOG_FORMAT`, `TRACING_SAMPLING`, `OTEL_EXPORTER_OTLP_ENDPOINT`) y cada
secreto con `secretKeyRef` a `tripbus-secrets`. Identity monta `identity-jwt-keys` en `/keys`.

**Gateway:** el resolver de NGINX no usa los dominios de búsqueda del clúster, así que las upstreams van
con el nombre completo (`identity.tripbus.svc.cluster.local:18001`) en el ConfigMap `gateway-config`; el
overlay de QA las cambia a `tripbus-qa`. `RESOLVER=kube-dns.kube-system.svc.cluster.local valid=10s`,
`REAL_IP_FROM=10.0.0.0/8` (red de pods, para un ingress o un cloudflared dentro del clúster) y `/docs`
apagado (no hay Swagger UI en Kubernetes).

## Secretos

`base/secrets.yaml` son **plantillas** (`CAMBIAR`): no se aplican. Crea los reales una vez por namespace
(`tripbus-qa` o `tripbus`):

```bash
NS=tripbus
kubectl create namespace $NS
# 1. Secretos de la plataforma (mismos nombres que .env.prod.example; genera cada uno con openssl rand -base64 32,
#    Redis con openssl rand -hex 32; las llaves VAPID con: docker run --rm node:22-alpine npx -y web-push generate-vapid-keys)
kubectl -n $NS create secret generic tripbus-secrets --from-env-file=secrets.env
#    secrets.env (NO se sube a git): REDIS_PASSWORD, INTERNAL_API_TOKEN, TICKET_SECRET, PAYMENT_WEBHOOK_SECRET,
#    MFA_ENCRYPTION_KEY, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, <SERVICIO>_DB_USERNAME y
#    <SERVICIO>_DB_PASSWORD de IDENTITY, CATALOG, INVENTORY, BOOKING, FLEET y OFFERS
#    (+ DEMO_USERS_PASSWORD en QA para los usuarios de demostración).
# 2. Llaves RSA de los JWT de identity
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out private.pem
openssl rsa -in private.pem -pubout -out public.pem
kubectl -n $NS create secret generic identity-jwt-keys --from-file=private.pem --from-file=public.pem
rm private.pem public.pem
```

## Desplegar

1. Cambia los `CAMBIAR-DOMINIO` de `base/config.yaml` (o agrega un patch en tu overlay) por el dominio
   público: `FRONTEND_URL`, `PUBLIC_API_URL`, `WS_ALLOWED_ORIGINS`, `CORS_ALLOWED_ORIGIN`.
2. Imágenes privadas de GHCR: `kubectl -n $NS create secret docker-registry ghcr --docker-server=ghcr.io
   --docker-username=<usuario> --docker-password=<PAT read:packages>` y agrega `imagePullSecrets: [{name: ghcr}]`
   a la ServiceAccount `default` (`kubectl -n $NS patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ghcr"}]}'`).
3. `scripts/k8s-apply.sh qa` o `scripts/k8s-apply.sh prod`: aplica el overlay **sin** las plantillas de
   Secret, se niega si faltan los Secret reales o aún tienen `CAMBIAR`, y espera los rollouts.

Ver el resultado sin clúster: `kubectl kustomize k8s/overlays/prod` (o `kustomize build`).

## Validación en el CI

El job `validar` de `.github/workflows/ci-cd.yml` construye los dos overlays con kustomize v5.6.0 y los
valida con kubeconform v0.6.7 (`-strict`, esquemas de Kubernetes 1.30). Localmente:

```bash
kustomize build k8s/overlays/qa | kubeconform -strict -summary -kubernetes-version 1.30.0 -
```
