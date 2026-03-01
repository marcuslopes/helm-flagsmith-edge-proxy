terraform {
  required_providers {
    flagsmith = {
      source  = "Flagsmith/flagsmith"
      version = "~> 0.9.0"
    }
  }
}

resource "flagsmith_feature" "this" {
  for_each = var.flags

  feature_name    = each.key
  project_uuid    = var.project_uuid
  description     = each.value.description
  type            = each.value.type
  default_enabled = each.value.default_enabled
  initial_value   = each.value.initial_value
  is_archived     = each.value.is_archived
  tags            = each.value.tags
}
