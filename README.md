# Task: Implement DynamoUI GCP Deployment Module

**Handoff type:** Implementation task for Claude Code  
**Scope:** Infrastructure-as-code + container plumbing for deploying DynamoUI Canvas on GCP  
**Repos involved:** `dynamoui-backend` (FastAPI), `dynamoui-frontend` (React/Vite/Nginx)  
**New directory created by this task:** `infra/modules/dynamoui/` (lives in the backend repo)

---

## Context

DynamoUI is a schema-first, NL-driven admin UI framework. Canvas (LLD 9) is its conversational UI generator feature — operators chat with an LLM to produce theme CSS, enriched skill YAMLs, layout configs, and domain-seeded NL patterns, all written to `canvas-output/`. Canvas has its own PostgreSQL database (`canvas`) within the existing Cloud SQL instance.

This task implements the GCP deployment unit: a self-contained Terraform module + container entrypoints that any parent GCP Terraform plan can import with a single `module "dynamoui" {}` block.

All files described in this task have already been designed and reviewed. Your job is to place them in the correct locations in the correct repos, fill in the two pieces not yet implemented (Alembic canvas migrations, and the backend `CanvasSettings` Pydantic config), and verify the wiring end-to-end.

---

## File placement map

Every file below is either: (A) copy verbatim from the design artefacts linked per section, or (B) implement from the spec given here. No file requires creative decisions — all architecture choices are locked.

### A. Terraform module — `dynamoui-backend` repo

Create the directory `infra/modules/dynamoui/` with this exact structure:

```
infra/
└── modules/
    └── dynamoui/
        ├── main.tf                   ← copy verbatim (see §1)
        ├── variables.tf              ← copy verbatim (see §1)
        ├── outputs.tf                ← copy verbatim (see §1)
        ├── scripts/
        │   └── migrate_entrypoint.sh ← copy verbatim (see §2)
        └── README.md                 ← copy verbatim (see §1)
```

Also place at the backend repo root:

```
cloudbuild.yaml                       ← copy verbatim (see §3)
```

### B. Backend repo — new files to implement

```
dynamoui-backend/
├── alembic_canvas.ini                ← implement (see §4)
├── alembic/
│   └── versions/
│       └── canvas/
│           └── 0001_canvas_schema.py ← implement (see §4)
├── canvas/
│   └── config.py                     ← implement (see §5)
└── scripts/
    └── migrate_entrypoint.sh         ← already placed via Terraform module above;
                                         also copy here so Docker COPY path works
```

### C. Frontend repo — new files to implement

```
dynamoui-frontend/
├── Dockerfile                        ← copy verbatim (see §6)
└── scripts/
    ├── nginx.conf.template           ← copy verbatim (see §6)
    └── docker_entrypoint.sh          ← copy verbatim (see §6)
```

### D. Backend repo — Dockerfile modification

Modify the **existing** `dynamoui-backend/Dockerfile`. Do not replace it — apply targeted additions (see §7).

---

## §1 — Terraform module files (copy verbatim)

The following four files are the complete Terraform module. Copy them exactly as written — do not alter resource names, variable names, or logic. The module was reviewed and is correct.

### `infra/modules/dynamoui/main.tf`

```hcl
################################################################################
# DynamoUI — Terraform module
#
# Deploys as a self-contained sub-node inside any GCP project/plan.
# Requires an existing Cloud SQL instance and VPC (or creates a connector).
# Provisions:
#   - google_sql_database          canvas DB inside existing instance
#   - google_sql_user              canvas DB user
#   - google_storage_bucket        canvas-output (scaffold + generated files)
#   - google_cloud_run_v2_service  dynamoui-frontend (nginx)
#   - google_cloud_run_v2_service  dynamoui-backend  (FastAPI)
#   - google_cloud_run_v2_job      canvas-migrate    (alembic + optional scaffold)
#   - google_secret_manager_secret ×4
#   - google_service_account       dynamoui-sa
#   - google_vpc_access_connector  (optional — skipped if vpc_connector_id provided)
################################################################################

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix = "dynamoui"
  sql_conn    = var.cloud_sql_instance_connection_name
}

resource "google_service_account" "dynamoui" {
  project      = var.project_id
  account_id   = "${local.name_prefix}-sa"
  display_name = "DynamoUI service account"
}

locals {
  sa_roles = [
    "roles/cloudsql.client",
    "roles/secretmanager.secretAccessor",
    "roles/storage.objectAdmin",
    "roles/run.invoker",
  ]
}

resource "google_project_iam_member" "dynamoui_sa" {
  for_each = toset(local.sa_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.dynamoui.email}"
}

resource "google_vpc_access_connector" "dynamoui" {
  count   = var.vpc_connector_id == "" ? 1 : 0
  project = var.project_id
  region  = var.region
  name    = "${local.name_prefix}-connector"

  subnet {
    name       = var.connector_subnet_name
    project_id = var.project_id
  }

  machine_type  = "e2-micro"
  min_instances = 2
  max_instances = 3
}

locals {
  vpc_connector_id = (
    var.vpc_connector_id != ""
    ? var.vpc_connector_id
    : google_vpc_access_connector.dynamoui[0].id
  )
}

resource "google_sql_database" "canvas" {
  project  = var.project_id
  name     = var.canvas_db_name
  instance = var.cloud_sql_instance_name
}

resource "google_sql_user" "canvas" {
  project  = var.project_id
  name     = var.canvas_db_user
  instance = var.cloud_sql_instance_name
  password = var.canvas_db_password

  depends_on = [google_sql_database.canvas]
}

resource "google_storage_bucket" "canvas_output" {
  project                     = var.project_id
  name                        = "${var.project_id}-${local.name_prefix}-canvas-output"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age        = 90
      with_state = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    managed-by = "terraform"
    module     = local.name_prefix
  }
}

resource "google_secret_manager_secret" "canvas_db_user" {
  project   = var.project_id
  secret_id = "${local.name_prefix}-canvas-db-user"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "canvas_db_user" {
  secret      = google_secret_manager_secret.canvas_db_user.id
  secret_data = var.canvas_db_user
}

resource "google_secret_manager_secret" "canvas_db_password" {
  project   = var.project_id
  secret_id = "${local.name_prefix}-canvas-db-password"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "canvas_db_password" {
  secret      = google_secret_manager_secret.canvas_db_password.id
  secret_data = var.canvas_db_password
}

resource "google_secret_manager_secret" "operator_db_password" {
  project   = var.project_id
  secret_id = "${local.name_prefix}-operator-db-password"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "operator_db_password" {
  secret      = google_secret_manager_secret.operator_db_password.id
  secret_data = var.operator_db_password
}

resource "google_secret_manager_secret" "llm_api_key" {
  project   = var.project_id
  secret_id = "${local.name_prefix}-llm-api-key"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "llm_api_key" {
  secret      = google_secret_manager_secret.llm_api_key.id
  secret_data = var.llm_api_key
}

resource "google_cloud_run_v2_job" "canvas_migrate" {
  project  = var.project_id
  name     = "${local.name_prefix}-canvas-migrate"
  location = var.region

  labels = {
    managed-by = "terraform"
    module     = local.name_prefix
  }

  template {
    labels = {
      job = "canvas-migrate"
    }

    template {
      service_account = google_service_account.dynamoui.email
      max_retries     = 1
      timeout         = "300s"

      vpc_access {
        connector = local.vpc_connector_id
        egress    = "PRIVATE_RANGES_ONLY"
      }

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [local.sql_conn]
        }
      }

      containers {
        name    = "canvas-migrate"
        image   = var.backend_image
        command = ["/bin/sh"]
        args    = ["/scripts/migrate_entrypoint.sh"]

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

        env {
          name  = "CANVAS_DB_HOST"
          value = "/cloudsql/${local.sql_conn}"
        }
        env {
          name  = "CANVAS_DB_NAME"
          value = var.canvas_db_name
        }
        env {
          name = "CANVAS_DB_USER"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.canvas_db_user.secret_id
              version = "latest"
            }
          }
        }
        env {
          name = "CANVAS_DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.canvas_db_password.secret_id
              version = "latest"
            }
          }
        }
        env {
          name  = "CANVAS_DB_RESYNC"
          value = tostring(var.canvas_db_resync)
        }
        env {
          name  = "CANVAS_OUTPUT_BUCKET"
          value = google_storage_bucket.canvas_output.name
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [
    google_sql_database.canvas,
    google_sql_user.canvas,
    google_storage_bucket.canvas_output,
    google_secret_manager_secret_version.canvas_db_user,
    google_secret_manager_secret_version.canvas_db_password,
  ]
}

resource "google_cloud_run_v2_service" "backend" {
  project  = var.project_id
  name     = "${local.name_prefix}-backend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.dynamoui.email

    scaling {
      min_instance_count = var.backend_min_instances
      max_instance_count = var.backend_max_instances
    }

    vpc_access {
      connector = local.vpc_connector_id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [local.sql_conn]
      }
    }

    volumes {
      name = "canvas-output"
      gcs {
        bucket    = google_storage_bucket.canvas_output.name
        read_only = true
      }
    }

    containers {
      name  = "backend"
      image = var.backend_image

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      volume_mounts {
        name       = "canvas-output"
        mount_path = "/app/canvas-output"
      }

      env {
        name  = "OPERATOR_DB_HOST"
        value = "/cloudsql/${local.sql_conn}"
      }
      env {
        name  = "OPERATOR_DB_NAME"
        value = var.operator_db_name
      }
      env {
        name  = "OPERATOR_DB_USER"
        value = var.operator_db_user
      }
      env {
        name = "OPERATOR_DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.operator_db_password.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "CANVAS_DB_HOST"
        value = "/cloudsql/${local.sql_conn}"
      }
      env {
        name  = "CANVAS_DB_NAME"
        value = var.canvas_db_name
      }
      env {
        name = "CANVAS_DB_USER"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.canvas_db_user.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "CANVAS_DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.canvas_db_password.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "DYNAMO_LLM_PROVIDER"
        value = var.llm_provider
      }
      env {
        name = "DYNAMO_LLM_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.llm_api_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "CANVAS_OUTPUT_DIR"
        value = "/app/canvas-output"
      }

      ports {
        container_port = 8080
      }

      startup_probe {
        http_get { path = "/health" }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 10
      }

      liveness_probe {
        http_get { path = "/health" }
        period_seconds    = 30
        failure_threshold = 3
      }

      resources {
        limits = {
          cpu    = var.backend_cpu
          memory = var.backend_memory
        }
        cpu_idle = true
      }
    }

    annotations = {
      "run.googleapis.com/startup-cpu-boost" = "true"
    }
  }

  depends_on = [
    google_project_iam_member.dynamoui_sa,
    google_secret_manager_secret_version.operator_db_password,
    google_secret_manager_secret_version.canvas_db_user,
    google_secret_manager_secret_version.canvas_db_password,
    google_secret_manager_secret_version.llm_api_key,
    google_storage_bucket.canvas_output,
  ]
}

resource "google_cloud_run_v2_service" "frontend" {
  project  = var.project_id
  name     = "${local.name_prefix}-frontend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.dynamoui.email

    scaling {
      min_instance_count = 1
      max_instance_count = var.frontend_max_instances
    }

    containers {
      name  = "frontend"
      image = var.frontend_image

      env {
        name  = "BACKEND_URL"
        value = google_cloud_run_v2_service.backend.uri
      }

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle = true
      }
    }
  }

  depends_on = [google_cloud_run_v2_service.backend]
}

resource "google_cloud_run_v2_service_iam_member" "frontend_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = var.allow_unauthenticated ? "allUsers" : "serviceAccount:${google_service_account.dynamoui.email}"
}

resource "google_cloud_run_v2_service_iam_member" "backend_internal" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.dynamoui.email}"
}
```

### `infra/modules/dynamoui/variables.tf`

```hcl
variable "project_id"                          { type = string }
variable "region"                              { type = string; default = "asia-south1" }
variable "vpc_connector_id"                    { type = string; default = "" }
variable "connector_subnet_name"               { type = string; default = "" }
variable "cloud_sql_instance_name"             { type = string }
variable "cloud_sql_instance_connection_name"  { type = string }
variable "operator_db_name"                    { type = string }
variable "operator_db_user"                    { type = string }
variable "operator_db_password"                { type = string; sensitive = true }
variable "canvas_db_name"                      { type = string; default = "canvas" }
variable "canvas_db_user"                      { type = string; default = "canvas_app" }
variable "canvas_db_password"                  { type = string; sensitive = true }
variable "canvas_db_resync"                    { type = bool;   default = false }
variable "backend_image"                       { type = string }
variable "frontend_image"                      { type = string }
variable "llm_provider"                        { type = string; default = "anthropic" }
variable "llm_api_key"                         { type = string; sensitive = true }
variable "backend_min_instances"               { type = number; default = 0 }
variable "backend_max_instances"               { type = number; default = 4 }
variable "frontend_max_instances"              { type = number; default = 4 }
variable "backend_cpu"                         { type = string; default = "2" }
variable "backend_memory"                      { type = string; default = "1Gi" }
variable "allow_unauthenticated"               { type = bool;   default = true }
```

> **Note:** The full variable descriptions are in the reviewed `variables.tf`. Paste the full file (not this abbreviated version) — the abbreviated form here is for readability only.

### `infra/modules/dynamoui/outputs.tf`

```hcl
output "frontend_url"            { value = google_cloud_run_v2_service.frontend.uri }
output "backend_url"             { value = google_cloud_run_v2_service.backend.uri }
output "service_account_email"   { value = google_service_account.dynamoui.email }
output "canvas_output_bucket"    { value = google_storage_bucket.canvas_output.name }
output "canvas_migrate_job_name" { value = google_cloud_run_v2_job.canvas_migrate.name }
output "canvas_db_name"          { value = google_sql_database.canvas.name }
output "vpc_connector_id"        { value = local.vpc_connector_id }
```

---

## §2 — migrate_entrypoint.sh (copy verbatim)

Place at **two** locations:

- `infra/modules/dynamoui/scripts/migrate_entrypoint.sh`
- `scripts/migrate_entrypoint.sh` ← this is the path the backend Dockerfile copies into the image at `/scripts/migrate_entrypoint.sh`

```sh
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

set -e

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
```

---

## §3 — cloudbuild.yaml (copy verbatim, place at backend repo root)

```yaml
substitutions:
  _REGION: asia-south1
  _CANVAS_DB_RESYNC: "false"
  _FRONTEND_IMAGE_TAG: latest

steps:
  - id: build-backend
    name: gcr.io/cloud-builders/docker
    args:
      - build
      - -t
      - gcr.io/$PROJECT_ID/dynamoui-backend:$COMMIT_SHA
      - -t
      - gcr.io/$PROJECT_ID/dynamoui-backend:latest
      - --cache-from
      - gcr.io/$PROJECT_ID/dynamoui-backend:latest
      - .

  - id: push-backend
    name: gcr.io/cloud-builders/docker
    args: [push, --all-tags, gcr.io/$PROJECT_ID/dynamoui-backend]
    waitFor: [build-backend]

  - id: update-migrate-job
    name: gcr.io/google.com/cloudsdktool/cloud-sdk:slim
    entrypoint: gcloud
    args:
      - run
      - jobs
      - update
      - dynamoui-canvas-migrate
      - --image=gcr.io/$PROJECT_ID/dynamoui-backend:$COMMIT_SHA
      - --region=$_REGION
    waitFor: [push-backend]

  - id: canvas-migrate
    name: gcr.io/google.com/cloudsdktool/cloud-sdk:slim
    entrypoint: gcloud
    args:
      - run
      - jobs
      - execute
      - dynamoui-canvas-migrate
      - --region=$_REGION
      - --wait
      - --update-env-vars=CANVAS_DB_RESYNC=$_CANVAS_DB_RESYNC
    waitFor: [update-migrate-job]

  - id: deploy-backend
    name: gcr.io/google.com/cloudsdktool/cloud-sdk:slim
    entrypoint: gcloud
    args:
      - run
      - deploy
      - dynamoui-backend
      - --image=gcr.io/$PROJECT_ID/dynamoui-backend:$COMMIT_SHA
      - --region=$_REGION
      - --no-traffic
    waitFor: [canvas-migrate]

  - id: route-backend-traffic
    name: gcr.io/google.com/cloudsdktool/cloud-sdk:slim
    entrypoint: gcloud
    args:
      - run
      - services
      - update-traffic
      - dynamoui-backend
      - --to-latest
      - --region=$_REGION
    waitFor: [deploy-backend]

  - id: deploy-frontend
    name: gcr.io/google.com/cloudsdktool/cloud-sdk:slim
    entrypoint: gcloud
    args:
      - run
      - deploy
      - dynamoui-frontend
      - --image=gcr.io/$PROJECT_ID/dynamoui-frontend:$_FRONTEND_IMAGE_TAG
      - --region=$_REGION
      - --to-latest
    waitFor: [route-backend-traffic]

images:
  - gcr.io/$PROJECT_ID/dynamoui-backend:$COMMIT_SHA
  - gcr.io/$PROJECT_ID/dynamoui-backend:latest

options:
  logging: CLOUD_LOGGING_ONLY
  machineType: E2_HIGHCPU_8

timeout: 1200s
```

---

## §4 — Alembic canvas migrations (implement)

### `alembic_canvas.ini`

Create at backend repo root. This is a standard Alembic config pointing at a separate migration tree for the canvas DB. The key difference from the existing `alembic.ini` is the `script_location` and the `sqlalchemy.url` which reads from the `CANVAS_DATABASE_URL` env var (set by `migrate_entrypoint.sh` at Job runtime).

```ini
[alembic]
script_location = alembic/versions/canvas
sqlalchemy.url =

[loggers]
keys = root,sqlalchemy,alembic

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = WARN
handlers = console
qualname =

[logger_sqlalchemy]
level = WARN
handlers =
qualname = sqlalchemy.engine

[logger_alembic]
level = INFO
handlers =
qualname = alembic

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %(levelname)-5.5s [%(name)s] %(message)s
datefmt = %H:%M:%S
```

You must also create `alembic/versions/canvas/env.py`. Model it identically to the existing `alembic/env.py` but read `CANVAS_DATABASE_URL` from the environment instead of the operator DB URL:

```python
# alembic/versions/canvas/env.py
import os
from logging.config import fileConfig
from sqlalchemy import engine_from_config, pool
from alembic import context

config = context.config
fileConfig(config.config_file_name)

# Read canvas DB URL from env — set by migrate_entrypoint.sh
canvas_url = os.environ["CANVAS_DATABASE_URL"]
config.set_main_option("sqlalchemy.url", canvas_url)

target_metadata = None  # canvas tables are managed purely by Alembic DDL, not ORM models

def run_migrations_offline():
    context.configure(url=canvas_url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()

def run_migrations_online():
    connectable = engine_from_config(
        config.get_section(config.config_ini_section),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
```

Also create `alembic/versions/canvas/script.py.mako` — copy it verbatim from `alembic/script.py.mako` (the existing one in the repo).

### `alembic/versions/canvas/0001_canvas_schema.py`

This is the initial migration that creates all 7 canvas tables. Implement it exactly per the schema below — column names, types, constraints, and indexes are not negotiable:

```python
"""canvas initial schema

Revision ID: 0001
Revises:
Create Date: 2025-01-01 00:00:00.000000
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID
import uuid

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # ── canvas_sessions ───────────────────────────────────────────────────────
    # One row per Canvas operator session. Tracks lifecycle from created → complete.
    op.create_table(
        "canvas_sessions",
        sa.Column("session_id",   UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("operator_id",  sa.String(255), nullable=False),
        sa.Column("domain_hint",  sa.Text,        nullable=True),   # e.g. "HR management system"
        sa.Column("state",        sa.String(50),  nullable=False, server_default="active"),
                                                                     # active | complete | abandoned
        sa.Column("created_at",   sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_canvas_sessions_operator_id", "canvas_sessions", ["operator_id"])
    op.create_index("ix_canvas_sessions_state",       "canvas_sessions", ["state"])

    # ── canvas_turns ──────────────────────────────────────────────────────────
    # Ordered conversation turns within a session.
    op.create_table(
        "canvas_turns",
        sa.Column("turn_id",       UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",    UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("role",          sa.String(20),  nullable=False),  # user | assistant
        sa.Column("message",       sa.Text,        nullable=False),
        sa.Column("intent_parsed", JSONB,          nullable=True),   # structured intent extracted from user turn
        sa.Column("created_at",    sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_turns_session_id",  "canvas_turns", ["session_id"])
    op.create_index("ix_canvas_turns_created_at",  "canvas_turns", ["created_at"])

    # ── canvas_themes ─────────────────────────────────────────────────────────
    # Generated theme CSS output per session. Validated before persistence.
    op.create_table(
        "canvas_themes",
        sa.Column("theme_id",       UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",     UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("name",           sa.String(255), nullable=False),
        sa.Column("aesthetic_mood", sa.String(50),  nullable=True),   # AestheticMood enum value
        sa.Column("css_content",    sa.Text,        nullable=False),   # full CSS file content
        sa.Column("validated",      sa.Boolean,     nullable=False, server_default="false"),
        sa.Column("created_at",     sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_themes_session_id", "canvas_themes", ["session_id"])

    # ── canvas_layouts ────────────────────────────────────────────────────────
    # Generated layout.config.yaml content per session.
    op.create_table(
        "canvas_layouts",
        sa.Column("layout_id",   UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",  UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("archetype",   sa.String(50),  nullable=True),   # layout archetype name
        sa.Column("config_json", JSONB,          nullable=False),   # parsed layout config
        sa.Column("created_at",  sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_layouts_session_id", "canvas_layouts", ["session_id"])

    # ── canvas_enriched_skills ────────────────────────────────────────────────
    # Enriched *.skill.yaml content produced by SkillEnricher, stored per session.
    op.create_table(
        "canvas_enriched_skills",
        sa.Column("skill_id",     UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",   UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("entity",       sa.String(255), nullable=False),   # PascalCase entity name
        sa.Column("yaml_content", sa.Text,        nullable=False),   # full enriched YAML
        sa.Column("validated",    sa.Boolean,     nullable=False, server_default="false"),
        sa.Column("created_at",   sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_enriched_skills_session_id", "canvas_enriched_skills", ["session_id"])
    op.create_index("ix_canvas_enriched_skills_entity",     "canvas_enriched_skills", ["entity"])

    # ── canvas_domain_patterns ────────────────────────────────────────────────
    # Domain-seeded NL patterns produced by DomainPatternSeeder, stored per session.
    op.create_table(
        "canvas_domain_patterns",
        sa.Column("pattern_id",   UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",   UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("entity",       sa.String(255), nullable=False),
        sa.Column("yaml_content", sa.Text,        nullable=False),
        sa.Column("created_at",   sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_domain_patterns_session_id", "canvas_domain_patterns", ["session_id"])
    op.create_index("ix_canvas_domain_patterns_entity",     "canvas_domain_patterns", ["entity"])

    # ── canvas_output_files ───────────────────────────────────────────────────
    # Manifest of files committed to canvas-output/ (GCS or local) per session.
    op.create_table(
        "canvas_output_files",
        sa.Column("file_id",     UUID(as_uuid=True), primary_key=True, default=uuid.uuid4),
        sa.Column("session_id",  UUID(as_uuid=True),
                  sa.ForeignKey("canvas_sessions.session_id", ondelete="CASCADE"), nullable=False),
        sa.Column("file_type",   sa.String(50),  nullable=False),   # theme | skill | pattern | layout | readme
        sa.Column("path",        sa.Text,        nullable=False),   # GCS path or local relative path
        sa.Column("committed",   sa.Boolean,     nullable=False, server_default="false"),
        sa.Column("created_at",  sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_canvas_output_files_session_id", "canvas_output_files", ["session_id"])
    op.create_index("ix_canvas_output_files_file_type",  "canvas_output_files", ["file_type"])


def downgrade() -> None:
    # Drop in reverse FK dependency order
    op.drop_table("canvas_output_files")
    op.drop_table("canvas_domain_patterns")
    op.drop_table("canvas_enriched_skills")
    op.drop_table("canvas_layouts")
    op.drop_table("canvas_themes")
    op.drop_table("canvas_turns")
    op.drop_table("canvas_sessions")
```

---

## §5 — CanvasSettings Pydantic config (implement)

Create `canvas/config.py`. This integrates the canvas DB and canvas output dir env vars into the existing Pydantic Settings pattern used throughout the backend (see `config/settings.py` for the existing pattern — match the style exactly).

```python
# canvas/config.py
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field, computed_field
from pathlib import Path


class CanvasSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CANVAS_")

    # ── Database ──────────────────────────────────────────────────────────────
    db_host: str = Field(
        default="localhost",
        description="Canvas DB host or Unix socket path (/cloudsql/... in Cloud Run).",
    )
    db_name: str = Field(default="canvas")
    db_user: str = Field(default="canvas_app")
    db_password: str = Field(default="", repr=False)
    db_port: int = Field(default=5432)

    @computed_field  # type: ignore[misc]
    @property
    def database_url(self) -> str:
        """
        Async URL for the FastAPI runtime (asyncpg).
        Unix socket: postgresql+asyncpg://user:pass@/dbname?host=/cloudsql/...
        TCP:         postgresql+asyncpg://user:pass@host:port/dbname
        """
        if self.db_host.startswith("/"):
            # Cloud SQL Auth Proxy via Unix domain socket
            return (
                f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
                f"@/{self.db_name}?host={self.db_host}"
            )
        return (
            f"postgresql+asyncpg://{self.db_user}:{self.db_password}"
            f"@{self.db_host}:{self.db_port}/{self.db_name}"
        )

    # ── Output directory (GCS mount in Cloud Run, local path in dev) ──────────
    output_dir: Path = Field(
        default=Path("canvas-output"),
        description=(
            "Path where Canvas writes generated files. "
            "In Cloud Run this is /app/canvas-output (GCS bucket mount). "
            "In local dev this defaults to ./canvas-output."
        ),
    )

    # ── Session ───────────────────────────────────────────────────────────────
    session_ttl_hours: int = Field(
        default=24,
        description="Hours after which an inactive canvas session is marked abandoned.",
    )

    # ── Resync flag (read-only at runtime — only used by migrate job) ─────────
    db_resync: bool = Field(
        default=False,
        description="Internal flag. Read by migrate_entrypoint.sh only — not consumed by FastAPI.",
    )


# Module-level singleton — import this everywhere in the canvas package
canvas_settings = CanvasSettings()
```

**Wire it in:** In `canvas/router.py` (and any other canvas module that needs DB access or output dir), replace any hardcoded path or connection string references with `from canvas.config import canvas_settings` and use `canvas_settings.database_url` / `canvas_settings.output_dir`.

---

## §6 — Frontend container files (copy verbatim)

### `dynamoui-frontend/Dockerfile`

```dockerfile
FROM node:20-alpine AS build

WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline
COPY . .
ENV VITE_API_BASE_URL=/api/v1
RUN npm run build

FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
COPY scripts/nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY scripts/docker_entrypoint.sh /docker_entrypoint.sh
RUN chmod +x /docker_entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/docker_entrypoint.sh"]
```

### `dynamoui-frontend/scripts/nginx.conf.template`

```nginx
server {
    listen       8080;
    server_name  _;

    root   /usr/share/nginx/html;
    index  index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass          ${BACKEND_URL}/api/;
        proxy_http_version  1.1;
        proxy_set_header    Host                $host;
        proxy_set_header    X-Real-IP           $remote_addr;
        proxy_set_header    X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto   $scheme;
        proxy_set_header    Authorization       "";
        proxy_connect_timeout  10s;
        proxy_read_timeout     120s;
        proxy_send_timeout     30s;
    }

    location /ws/ {
        proxy_pass          ${BACKEND_URL}/ws/;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    $http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_read_timeout  3600s;
    }

    location /nginx-health {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2|woff|ttf)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    add_header X-Frame-Options         "SAMEORIGIN"  always;
    add_header X-Content-Type-Options  "nosniff"     always;
    add_header Referrer-Policy         "strict-origin-when-cross-origin" always;
    server_tokens off;
}
```

### `dynamoui-frontend/scripts/docker_entrypoint.sh`

```sh
#!/bin/sh
set -e
: "${BACKEND_URL:?ERROR: BACKEND_URL environment variable is required}"
echo "[entrypoint] Substituting BACKEND_URL into nginx config..."
envsubst '$BACKEND_URL' \
  < /etc/nginx/templates/nginx.conf.template \
  > /etc/nginx/conf.d/default.conf
echo "[entrypoint] Starting nginx..."
exec nginx -g "daemon off;"
```

---

## §7 — Backend Dockerfile modifications

The existing `dynamoui-backend/Dockerfile` needs four additions. **Do not replace the file** — apply these changes surgically using `str_replace`:

**Addition 1:** After the `apt-get install` block (wherever system packages are installed), add `fuse` and the `gcsfuse` apt source. If the existing Dockerfile already installs packages, append to that block:

```dockerfile
# gcsfuse — needed for local development outside Cloud Run
# (Cloud Run handles the GCS volume mount natively; gcsfuse is a fallback)
RUN apt-get update && apt-get install -y --no-install-recommends \
    fuse \
    && export GCSFUSE_REPO="gcsfuse-$(. /etc/os-release && echo ${VERSION_CODENAME})" \
    && echo "deb https://packages.cloud.google.com/apt ${GCSFUSE_REPO} main" \
       > /etc/apt/sources.list.d/gcsfuse.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - \
    && apt-get update && apt-get install -y gcsfuse \
    && rm -rf /var/lib/apt/lists/*
```

**Addition 2:** After `COPY . .`, add:

```dockerfile
# migrate entrypoint script (invoked by Cloud Run Job — not by normal uvicorn startup)
COPY scripts/migrate_entrypoint.sh /scripts/migrate_entrypoint.sh
RUN chmod +x /scripts/migrate_entrypoint.sh

# Alembic config for the canvas DB (separate from operator DB alembic.ini)
COPY alembic_canvas.ini .
```

**Addition 3:** Verify the existing `CMD` uses port 8080 and `--host 0.0.0.0`. If not, correct it:

```dockerfile
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
```

**Addition 4:** Add `psycopg2-binary` to `requirements.txt` if not already present. The migrate job uses `postgresql+psycopg2` (asyncpg does not support Unix sockets). The runtime FastAPI uses asyncpg. Both drivers must be installed.

```
psycopg2-binary>=2.9
```

---

## §8 — Requirements checklist

Before marking this task complete, verify each item:

- [ ] `infra/modules/dynamoui/main.tf` exists and passes `terraform validate` (you can mock provider credentials with `TF_ACC=0`)
- [ ] `infra/modules/dynamoui/variables.tf` exists — all 20 variables present
- [ ] `infra/modules/dynamoui/outputs.tf` exists — all 7 outputs present
- [ ] `scripts/migrate_entrypoint.sh` exists at backend repo root and is `chmod +x`
- [ ] `alembic_canvas.ini` exists at backend repo root and references `alembic/versions/canvas`
- [ ] `alembic/versions/canvas/env.py` exists and reads `CANVAS_DATABASE_URL` from env
- [ ] `alembic/versions/canvas/script.py.mako` exists (copied from existing mako)
- [ ] `alembic/versions/canvas/0001_canvas_schema.py` exists — all 7 tables, all indexes
- [ ] `canvas/config.py` exists — `CanvasSettings` with `database_url` computed field
- [ ] `canvas/config.py` is imported in `canvas/router.py` — no hardcoded DB strings remain in canvas package
- [ ] `dynamoui-frontend/Dockerfile` exists (multi-stage, node → nginx)
- [ ] `dynamoui-frontend/scripts/nginx.conf.template` exists — `${BACKEND_URL}` present as envsubst variable
- [ ] `dynamoui-frontend/scripts/docker_entrypoint.sh` exists and is `chmod +x`
- [ ] Backend `Dockerfile` includes `COPY scripts/migrate_entrypoint.sh /scripts/migrate_entrypoint.sh`
- [ ] Backend `Dockerfile` includes `COPY alembic_canvas.ini .`
- [ ] `psycopg2-binary` is in `requirements.txt`
- [ ] `cloudbuild.yaml` exists at backend repo root — 7 steps in correct order
- [ ] `infra/modules/dynamoui/scripts/migrate_entrypoint.sh` exists (duplicate of backend root version — this is intentional; the module ships its own copy for documentation completeness)

---

## §9 — What this task does NOT include

Do not implement the following — they are out of scope for this task:

- **`example_parent_plan.tf`** — this is for operator use when importing the module into their own plan; do not place it in the repo
- **Cloud Build trigger configuration** — the trigger is created by the parent Terraform plan, not by this module
- **Canvas API routes** — `canvas/router.py` and all canvas business logic already exist from the Canvas LLD 9 implementation tasks; this task only adds the config and DB wiring
- **Frontend `src/` changes** — `VITE_API_BASE_URL=/api/v1` is already the correct value from existing frontend implementation; no src changes needed
- **GCS bucket lifecycle or IAM** — fully managed by the Terraform module
- **Pattern cache or skill loader changes** — the skill loader already reads from `DYNAMO_CANVAS_OUTPUT_DIR` equivalent; updating the env var name to `CANVAS_OUTPUT_DIR` (if it differs) is in scope, but no logic changes

---

## §10 — Known constraints and decisions already made

These are not up for re-evaluation in this task:

- **asyncpg for FastAPI runtime, psycopg2 for the migrate Job.** asyncpg does not support Unix domain sockets; psycopg2 does. Both are needed.
- **Cloud Run GCS volume mount (not gcsfuse in-process).** Cloud Run v2 natively mounts GCS buckets as volumes — the backend container does not need to call `gcsfuse` itself in production. The Dockerfile includes gcsfuse only for local dev fallback.
- **`alembic_canvas.ini` separate from `alembic.ini`.** Canvas migrations must never run against the operator DB. Two configs, two separate Alembic trees.
- **`CANVAS_DATABASE_URL` set by `migrate_entrypoint.sh`, not Terraform.** The Job container receives `CANVAS_DB_HOST`, `CANVAS_DB_USER`, `CANVAS_DB_PASSWORD`, `CANVAS_DB_NAME` individually from Terraform/Secret Manager; the shell script assembles them into `CANVAS_DATABASE_URL` before invoking Alembic. Do not change this — it avoids putting a constructed URL with a password into a Terraform variable.
- **Backend ingress is `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`.** The backend is not publicly reachable. The frontend nginx proxies to it.
- **`canvas_db_resync` default is `false`.** Terraform manages the Job definition; Cloud Build passes `--update-env-vars=CANVAS_DB_RESYNC=true` when a resync is needed. Do not make scaffold run on every deploy.
