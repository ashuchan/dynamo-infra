#!/bin/sh
# canvas-migrate entrypoint
# Runs inside the dynamoui-backend container as the Cloud Run Job command.
#
# Environment variables expected (injected by Cloud Run Job):
#   CANVAS_DB_HOST        — Unix socket: /cloudsql/<project:region:instance>
#   CANVAS_DB_NAME        — e.g. canvas
#   CANVAS_DB_USER        — from Secret Manager
#   CANVAS_DB_PASSWORD    — from Secret Manager
#   CANVAS_DB_RESYNC      — "true" or "false"
#   CANVAS_OUTPUT_BUCKET  — GCS bucket name (no gs:// prefix)

set -eu

echo "[migrate] Starting canvas-migrate job"
echo "[migrate] CANVAS_DB_RESYNC=${CANVAS_DB_RESYNC}"

export CANVAS_DATABASE_URL="postgresql+psycopg2://${CANVAS_DB_USER}:${CANVAS_DB_PASSWORD}@/${CANVAS_DB_NAME}?host=${CANVAS_DB_HOST}"

echo "[migrate] Running alembic upgrade head..."
cd /app
alembic -c alembic_canvas.ini upgrade head
echo "[migrate] Migrations complete."

if [ "${CANVAS_DB_RESYNC}" = "true" ]; then
  echo "[migrate] CANVAS_DB_RESYNC=true — running dynamoui scaffold..."

  SCAFFOLD_OUT="/tmp/canvas-scaffold"
  mkdir -p "${SCAFFOLD_OUT}/skills"
  mkdir -p "${SCAFFOLD_OUT}/patterns"

  dynamoui scaffold \
    --adapter postgresql \
    --schema canvas \
    --output-dir "${SCAFFOLD_OUT}/skills" \
    --patterns-dir "${SCAFFOLD_OUT}/patterns" \
    --no-interactive

  echo "[migrate] Scaffold output:"
  ls -lh "${SCAFFOLD_OUT}/skills/" "${SCAFFOLD_OUT}/patterns/"

  BUCKET_ROOT="gs://${CANVAS_OUTPUT_BUCKET}/canvas-output"

  echo "[migrate] Uploading skills to ${BUCKET_ROOT}/skills/ ..."
  gsutil -m cp "${SCAFFOLD_OUT}/skills/"*.yaml "${BUCKET_ROOT}/skills/"

  echo "[migrate] Uploading patterns to ${BUCKET_ROOT}/patterns/ ..."
  if ls "${SCAFFOLD_OUT}/patterns/"*.yaml 2>/dev/null | head -1 | grep -q .; then
    gsutil -m cp "${SCAFFOLD_OUT}/patterns/"*.yaml "${BUCKET_ROOT}/patterns/"
  else
    echo "[migrate] No pattern files generated — skipping patterns upload."
  fi

  cat > /tmp/resync_manifest.json << EOF
{
  "resync_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "canvas_db": "${CANVAS_DB_NAME}",
  "skills_count": $(ls "${SCAFFOLD_OUT}/skills/"*.yaml 2>/dev/null | wc -l),
  "patterns_count": $(ls "${SCAFFOLD_OUT}/patterns/"*.yaml 2>/dev/null | wc -l)
}
EOF
  gsutil cp /tmp/resync_manifest.json "${BUCKET_ROOT}/resync_manifest.json"

  echo "[migrate] Scaffold upload complete."
else
  echo "[migrate] CANVAS_DB_RESYNC=false — skipping scaffold."
fi

echo "[migrate] canvas-migrate job finished successfully."
