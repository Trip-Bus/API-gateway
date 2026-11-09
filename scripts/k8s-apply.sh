#!/usr/bin/env bash
# Despliega TripBus en Kubernetes con kustomize (HT-06). Requiere kubectl apuntando al clúster.
# Uso: scripts/k8s-apply.sh qa|prod
# ANTES: crea los Secret reales (k8s/README.md, "Secretos"); este script se niega si siguen los CAMBIAR.
set -euo pipefail
cd "$(dirname "$0")/.."
ENTORNO=${1:-}
case "$ENTORNO" in qa) NS=tripbus-qa ;; prod) NS=tripbus ;; *) echo "Uso: $0 qa|prod" >&2; exit 1 ;; esac

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
for s in tripbus-secrets identity-jwt-keys; do
  if ! kubectl -n "$NS" get secret "$s" >/dev/null 2>&1; then
    echo "Falta el Secret $s en $NS: créalo primero (k8s/README.md, sección Secretos)." >&2; exit 1
  fi
done
# "CAMBIAR..." en base64 empieza por Q0FNQklBU.
if kubectl -n "$NS" get secret tripbus-secrets -o jsonpath='{.data}' | grep -q 'Q0FNQklBU'; then
  echo "tripbus-secrets todavía tiene valores CAMBIAR: reemplázalos." >&2; exit 1
fi

# Los Secret del repo son solo plantillas: se aplica todo menos ellos (los reales ya existen).
kubectl kustomize "k8s/overlays/$ENTORNO" \
  | awk 'BEGIN{RS="\n---\n"; ORS="\n---\n"} !/\nkind: Secret\n/' \
  | kubectl apply -f -
kubectl -n "$NS" rollout status statefulset --timeout=300s
kubectl -n "$NS" rollout status deployment --timeout=600s
kubectl -n "$NS" get svc api-gateway
