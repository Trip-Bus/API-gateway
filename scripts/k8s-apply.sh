#!/usr/bin/env bash
# Despliega TODA la plataforma en Kubernetes (los 8 repos deben estar en la misma carpeta).
# Uso: ./scripts/k8s-apply.sh      (requiere kubectl apuntando al clúster)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GW="$ROOT/API-gateway"

kubectl apply -f "$GW/k8s/infra/00-namespace.yaml"
kubectl apply -f "$GW/k8s/infra/10-config.yaml"

# Llaves RSA con las que identity firma los JWT (una sola vez).
if ! kubectl -n tripbus get secret identity-jwt-keys >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/private.pem"
  openssl rsa -in "$TMP/private.pem" -pubout -out "$TMP/public.pem"
  kubectl -n tripbus create secret generic identity-jwt-keys \
    --from-file=private.pem="$TMP/private.pem" --from-file=public.pem="$TMP/public.pem"
  rm -rf "$TMP"
fi

kubectl apply -f "$GW/k8s/infra/20-postgres.yaml" -f "$GW/k8s/infra/30-redis.yaml"
kubectl -n tripbus rollout status statefulset/postgres --timeout=180s
kubectl -n tripbus rollout status statefulset/redis --timeout=120s

for repo in identity catalog-service seat-inventory-service booking-payment-service \
            fleet-trip-events-service flash-offerts-service Realtime-Gateway; do
  kubectl apply -f "$ROOT/$repo/k8s/deployment.yaml"
done
kubectl apply -f "$GW/k8s/deployment.yaml"

echo "Listo. IPs públicas:"
kubectl -n tripbus get svc api-gateway realtime-gateway
