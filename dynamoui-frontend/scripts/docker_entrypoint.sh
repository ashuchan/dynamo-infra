#!/bin/sh
set -e
: "${BACKEND_URL:?ERROR: BACKEND_URL environment variable is required}"
echo "[entrypoint] Substituting BACKEND_URL into nginx config..."
envsubst '$BACKEND_URL' \
  < /etc/nginx/templates/nginx.conf.template \
  > /etc/nginx/conf.d/default.conf
echo "[entrypoint] Starting nginx..."
exec nginx -g "daemon off;"
