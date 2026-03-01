output "features" {
  description = "Map of feature flag key to its id, uuid, and feature_name"
  value = {
    for key, feature in flagsmith_feature.this : key => {
      id           = feature.id
      uuid         = feature.uuid
      feature_name = feature.feature_name
    }
  }
}
