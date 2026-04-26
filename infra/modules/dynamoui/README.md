# DynamoUI Terraform Module

Self-contained GCP deployment module for DynamoUI Canvas. Import with a single `module "dynamoui" {}` block.

## Resources provisioned

| Resource | Purpose |
|---|---|
| `google_service_account` | DynamoUI service account with least-privilege roles |
| `google_vpc_access_connector` | Serverless VPC connector (created if `vpc_connector_id` not provided) |
| `google_sql_database` | Canvas PostgreSQL database within existing Cloud SQL instance |
| `google_sql_user` | Canvas database user |
| `google_storage_bucket` | `canvas-output` GCS bucket (versioned, 90-day archive lifecycle) |
| `google_secret_manager_secret` ×4 | canvas DB user/password, operator DB password, LLM API key |
| `google_cloud_run_v2_job` | `canvas-migrate` — Alembic migrations + optional scaffold resync |
| `google_cloud_run_v2_service` | `dynamoui-backend` (FastAPI, internal LB ingress) |
| `google_cloud_run_v2_service` | `dynamoui-frontend` (nginx, public ingress) |

## Usage

```hcl
module "dynamoui" {
  source = "./infra/modules/dynamoui"

  project_id                         = var.project_id
  region                             = "asia-south1"
  cloud_sql_instance_name            = google_sql_database_instance.main.name
  cloud_sql_instance_connection_name = google_sql_database_instance.main.connection_name
  operator_db_name                   = "operator"
  operator_db_user                   = "operator_app"
  operator_db_password               = var.operator_db_password
  canvas_db_password                 = var.canvas_db_password
  backend_image                      = "gcr.io/${var.project_id}/dynamoui-backend:latest"
  frontend_image                     = "gcr.io/${var.project_id}/dynamoui-frontend:latest"
  llm_api_key                        = var.llm_api_key
  vpc_connector_id                   = ""          # leave empty to auto-create
  connector_subnet_name              = "default"
}
```

## Inputs

See `variables.tf` for the full list of 20 variables with descriptions and defaults.

## Outputs

| Output | Description |
|---|---|
| `frontend_url` | Public URL of the frontend Cloud Run service |
| `backend_url` | Internal URL of the backend Cloud Run service |
| `service_account_email` | DynamoUI service account email |
| `canvas_output_bucket` | GCS bucket name for canvas-output files |
| `canvas_migrate_job_name` | Cloud Run Job name for canvas migrations |
| `canvas_db_name` | Canvas PostgreSQL database name |
| `vpc_connector_id` | VPC Access connector ID in use |

## Canvas migration

The `canvas-migrate` Cloud Run Job runs on every Cloud Build deployment (see `cloudbuild.yaml`). To trigger a full scaffold resync:

```bash
gcloud run jobs execute dynamoui-canvas-migrate \
  --region=asia-south1 \
  --update-env-vars=CANVAS_DB_RESYNC=true \
  --wait
```
