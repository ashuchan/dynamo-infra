variable "project_id" {
  type        = string
  description = "GCP project ID where DynamoUI resources are deployed."
}

variable "region" {
  type        = string
  default     = "asia-south1"
  description = "GCP region for all regional resources (Cloud Run, VPC connector, GCS bucket)."
}

variable "vpc_connector_id" {
  type        = string
  default     = ""
  description = "Existing Serverless VPC Access connector ID. If empty, a new connector is created using connector_subnet_name."
}

variable "connector_subnet_name" {
  type        = string
  default     = ""
  description = "Subnet name for a new VPC Access connector. Required when vpc_connector_id is empty."
}

variable "cloud_sql_instance_name" {
  type        = string
  description = "Name of the existing Cloud SQL instance (short name, not connection name)."
}

variable "cloud_sql_instance_connection_name" {
  type        = string
  description = "Full Cloud SQL instance connection name: project:region:instance."
}

variable "operator_db_name" {
  type        = string
  description = "Name of the existing operator PostgreSQL database within the Cloud SQL instance."
}

variable "operator_db_user" {
  type        = string
  description = "Username for connecting to the operator database."
}

variable "operator_db_password" {
  type        = string
  sensitive   = true
  description = "Password for the operator database user. Stored in Secret Manager."
}

variable "canvas_db_name" {
  type        = string
  default     = "canvas"
  description = "Name of the canvas PostgreSQL database to create within the Cloud SQL instance."
}

variable "canvas_db_user" {
  type        = string
  default     = "canvas_app"
  description = "Username for the canvas database. Created by this module."
}

variable "canvas_db_password" {
  type        = string
  sensitive   = true
  description = "Password for the canvas database user. Stored in Secret Manager."
}

variable "canvas_db_resync" {
  type        = bool
  default     = false
  description = "When true, the migrate job runs dynamoui scaffold and uploads output to GCS. Set via Cloud Build substitution, not in Terraform state."
}

variable "backend_image" {
  type        = string
  description = "Full container image URL for the DynamoUI backend (dynamoui-backend). e.g. gcr.io/my-project/dynamoui-backend:latest"
}

variable "frontend_image" {
  type        = string
  description = "Full container image URL for the DynamoUI frontend (dynamoui-frontend). e.g. gcr.io/my-project/dynamoui-frontend:latest"
}

variable "llm_provider" {
  type        = string
  default     = "anthropic"
  description = "LLM provider identifier passed to the backend as DYNAMO_LLM_PROVIDER."
}

variable "llm_api_key" {
  type        = string
  sensitive   = true
  description = "API key for the LLM provider. Stored in Secret Manager."
}

variable "backend_min_instances" {
  type        = number
  default     = 0
  description = "Minimum number of backend Cloud Run instances. Set to 1+ to avoid cold starts."
}

variable "backend_max_instances" {
  type        = number
  default     = 4
  description = "Maximum number of backend Cloud Run instances."
}

variable "frontend_max_instances" {
  type        = number
  default     = 4
  description = "Maximum number of frontend Cloud Run instances."
}

variable "backend_cpu" {
  type        = string
  default     = "2"
  description = "CPU limit for the backend Cloud Run container (e.g. '1', '2')."
}

variable "backend_memory" {
  type        = string
  default     = "1Gi"
  description = "Memory limit for the backend Cloud Run container (e.g. '512Mi', '1Gi')."
}

variable "allow_unauthenticated" {
  type        = bool
  default     = true
  description = "When true, the frontend Cloud Run service allows unauthenticated (public) invocations."
}
