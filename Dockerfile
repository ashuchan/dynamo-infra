FROM python:3.11-slim

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# gcsfuse — needed for local development outside Cloud Run
# (Cloud Run handles the GCS volume mount natively; gcsfuse is a fallback)
RUN apt-get update && apt-get install -y --no-install-recommends \
    fuse \
    && export GCSFUSE_REPO="gcsfuse-$(. /etc/os-release && echo ${VERSION_CODENAME})" \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt ${GCSFUSE_REPO} main" \
       > /etc/apt/sources.list.d/gcsfuse.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
       -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y gcsfuse \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# migrate entrypoint script (invoked by Cloud Run Job — not by normal uvicorn startup)
COPY scripts/migrate_entrypoint.sh /scripts/migrate_entrypoint.sh
RUN chmod +x /scripts/migrate_entrypoint.sh

# Alembic config for the canvas DB (separate from operator DB alembic.ini)
COPY alembic_canvas.ini .

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
