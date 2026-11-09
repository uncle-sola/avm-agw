output "owned_names" {
  description = "Names of the items this suite owns, by ARM collection."
  value       = local.owned_names
}

output "missing_names" {
  description = "Owned items that were missing from the live gateway at plan time (collection/name)."
  value       = local.missing_names
}

output "upsert_id" {
  description = "ID of the terraform_data that runs the upsert; changes every time the suite is re-applied to the gateway."
  value       = terraform_data.upsert.id
}

output "desired_json" {
  description = "The suite's items as ARM JSON (before nulls are stripped). Pass it as DESIRED_JSON to scripts/agw-suite.sh diff to compare with the live gateway."
  value       = local.desired_json
}
