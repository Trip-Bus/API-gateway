# k8s/ — DESACTUALIZADO

> **Estos manifiestos no se usan hoy.** PROD y QA corren con **Docker Compose** (ver el README raíz:
> `docker-compose.yml` + `docker-compose.qa.yml` / `docker-compose.prod.yml`).

Quedaron de la primera versión del MVP y **no siguen la convención v3.1**:

- Usan los puertos viejos **1600x** (identity 16001 … realtime 16007) y el gateway en 8080; la
  convención actual es **18000–18007**.
- Usan **una sola PostgreSQL compartida** (`k8s/infra/20-postgres.yaml`, variable `DB_URL`); hoy cada
  servicio tiene **su propia PostgreSQL** (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`).
- Redis sin contraseña y sin `REDIS_PASSWORD`, `SPRING_PROFILES_ACTIVE` ni el perfil `desplegado`.

Antes de volver a usarlos hay que actualizarlos a la convención (y en el gateway definir
`RESOLVER` con el DNS del clúster, p. ej. `kube-dns.kube-system.svc.cluster.local valid=10s`).
