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
