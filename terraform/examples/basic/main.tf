terraform {
  required_providers {
    flagsmith = {
      source  = "Flagsmith/flagsmith"
      version = "~> 0.9.0"
    }
  }
}

provider "flagsmith" {
  master_api_key = var.flagsmith_master_api_key
  base_api_url   = var.flagsmith_api_url
}

module "feature_flags" {
  source       = "../../modules/flagsmith-feature-flags"
  project_uuid = var.project_uuid

  flags = {
    enable_new_checkout = {
      description     = "New checkout flow"
      default_enabled = false
    }
    dark_mode = {
      description     = "Dark mode toggle"
      default_enabled = true
      initial_value   = "v2"
    }
    maintenance_mode = {
      description = "Put the application into maintenance mode"
      type        = "STANDARD"
      is_archived = false
    }
  }
}

output "created_flags" {
  description = "Feature flags created by the module"
  value       = module.feature_flags.features
}
