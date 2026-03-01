variable "flagsmith_master_api_key" {
  description = "Master API key for Flagsmith"
  type        = string
  sensitive   = true
}

variable "project_uuid" {
  description = "UUID of the Flagsmith project"
  type        = string
}

variable "flagsmith_api_url" {
  description = "Base API URL for self-hosted Flagsmith"
  type        = string
  default     = "http://localhost:18080/api/v1"
}
