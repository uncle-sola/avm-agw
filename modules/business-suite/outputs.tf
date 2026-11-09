output "host_names" {
  description = "Listener host names: public HTTPS, private HTTPS and public HTTP (Front Door)."
  value = {
    public  = local.host_public
    private = local.host_private
    http    = local.host_http
  }
}

output "gateway_item_names" {
  description = "Names of the gateway items this business owns, by ARM collection."
  value       = module.suite.owned_names
}

output "waf_policy_id" {
  description = "ID of the business's WAF policy."
  value       = azurerm_web_application_firewall_policy.this.id
}

output "routing_rule_priorities" {
  description = "Priorities used by the three routing rules."
  value       = [var.priority_base, var.priority_base + 1, var.priority_base + 2]
}

output "front_door_route_id" {
  description = "ID of the Front Door route, or null when front_door isn't set."
  value       = var.front_door == null ? null : azurerm_cdn_frontdoor_route.this[0].id
}
