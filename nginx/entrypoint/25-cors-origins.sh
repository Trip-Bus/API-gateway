#!/bin/sh
# Convierte CORS_ALLOWED_ORIGIN (lista separada por comas) en el cuerpo de un "map" de NGINX:
#   el header Access-Control-Allow-Origin solo se devuelve si el Origin de la petición está en la lista.
# '*' en la lista permite cualquier origen (solo para pruebas; en PROD se declara el dominio).
set -eu

OUT=/etc/nginx/cors-origins.map
LIST=${CORS_ALLOWED_ORIGIN:-}

if [ -z "$LIST" ]; then
  echo "25-cors-origins.sh: CORS_ALLOWED_ORIGIN vacío: el navegador no podrá llamar al API desde otro origen" >&2
fi

{
  if echo ",$LIST," | grep -q ',[[:space:]]*\*[[:space:]]*,'; then
    echo 'default "*";'
  else
    echo 'default "";'
  fi
  echo "$LIST" | tr ',' '\n' | while read -r origin; do
    [ -z "$origin" ] || [ "$origin" = "*" ] && continue
    # Solo caracteres válidos de un origen (esquema://host[:puerto]): evita inyectar configuración.
    if ! echo "$origin" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$'; then
      echo "25-cors-origins.sh: origen CORS inválido: '$origin'" >&2
      exit 1
    fi
    echo "\"$origin\" \$http_origin;"
  done
} > "$OUT"

echo "25-cors-origins.sh: orígenes CORS permitidos: ${LIST:-(ninguno)}"
