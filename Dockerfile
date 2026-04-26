# ── builder ───────────────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# gcc + libpq-dev cover any packages that lack pre-built wheels for the target arch
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── runtime ───────────────────────────────────────────────────────────────────
FROM python:3.11-slim

WORKDIR /app

# Copy installed packages from builder — no build tools in the final image
COPY --from=builder /install /usr/local

COPY . .

# migrate entrypoint script (invoked by Cloud Run Job — not by normal uvicorn startup)
COPY scripts/migrate_entrypoint.sh /scripts/migrate_entrypoint.sh
RUN chmod +x /scripts/migrate_entrypoint.sh

# Alembic config for the canvas DB (separate from operator DB alembic.ini)
COPY alembic_canvas.ini .

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
