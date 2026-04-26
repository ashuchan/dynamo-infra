output "frontend_url" {
  value       = google_cloud_run_v2_service.frontend.uri
  description = "Public URL of the DynamoUI frontend Cloud Run service."
}

output "backend_url" {
  value       = google_cloud_run_v2_service.backend.uri
  description = "Internal URL of the DynamoUI backend Cloud Run service."
}

output "service_account_email" {
  value       = google_service_account.dynamoui.email
  description = "Email of the DynamoUI service account used by all Cloud Run services."
}

output "canvas_output_bucket" {
  value       = google_storage_bucket.canvas_output.name
  description = "Name of the GCS bucket storing canvas-output files."
}

output "canvas_migrate_job_name" {
  value       = google_cloud_run_v2_job.canvas_migrate.name
  description = "Name of the canvas-migrate Cloud Run Job."
}

output "canvas_db_name" {
  value       = google_sql_database.canvas.name
  description = "Name of the canvas PostgreSQL database."
}

output "vpc_connector_id" {
  value       = local.vpc_connector_id
  description = "ID of the Serverless VPC Access connector used by Cloud Run services."
}
