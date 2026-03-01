variable "project_uuid" {
  description = "UUID of the Flagsmith project to create features in"
  type        = string
}

variable "flags" {
  description = "Map of feature flags to create. The map key is used as the feature name."
  type = map(object({
    description     = optional(string, "")
    type            = optional(string, "STANDARD")
    default_enabled = optional(bool, false)
    initial_value   = optional(string, null)
    is_archived     = optional(bool, false)
    tags            = optional(set(number), null)
  }))
}
