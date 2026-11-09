#----------Business suite: one business's routing on a shared Application Gateway-----------
# Creates, all named <business>-...: a backend pool (APIM), backend settings, a health probe, a WAF
# policy, three listeners (public HTTPS, private HTTPS, public HTTP for Front Door), public and
# private path maps built from var.path_map, and three path-based routing rules. The gateway items
# are upserted through ../suite, which owns everything named <business>-* and leaves every other
# item on the gateway alone. Optional: a private DNS record and a Front Door origin group and route.

locals {
  b      = var.business
  prefix = "${var.business}-"
  names  = var.gateway_item_names

  host_public  = "${var.environment_prefix}-agw-${var.business}-ext.${var.domain}"
  host_private = "${var.environment_prefix}-agw-${var.business}.${var.domain}"
  host_http    = "${var.environment_prefix}-agw-${var.business}-http.${var.domain}"

  pool_name     = "${local.b}-backend-pool"
  settings_name = "${local.b}-backend-http-settings"
  probe_name    = "${local.b}-probe"

  listener_public  = "${local.b}-listener-public"
  listener_private = "${local.b}-listener-private"
  listener_http    = "${local.b}-listener-public-http"

  path_map_public  = "${local.b}-public-path-map"
  path_map_private = "${local.b}-private-path-map"

  path_rules = { for k, r in var.path_map.path_rules : k => {
    name                       = "${local.b}-${k}"
    paths                      = r.paths
    backend_address_pool_name  = coalesce(r.backend_address_pool_name, local.pool_name)
    backend_http_settings_name = coalesce(r.backend_http_settings_name, local.settings_name)
    firewall_policy_id         = r.firewall_policy_id
  } }

  path_map_defaults = {
    default_backend_address_pool_name  = var.path_map.default_backend_address_pool_name
    default_backend_http_settings_name = var.path_map.default_backend_http_settings_name
    path_rules                         = local.path_rules
  }
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "${local.b}-agw-waf"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = var.waf.owasp_version

      # Same overrides as the gateway's own policy (eob-agw waf.tf)
      rule_group_override {
        rule_group_name = "REQUEST-920-PROTOCOL-ENFORCEMENT"

        rule {
          id      = "920300"
          action  = "Log"
          enabled = true
        }
        rule {
          id      = "920440"
          action  = "Block"
          enabled = true
        }
      }
    }
  }

  dynamic "custom_rules" {
    for_each = var.waf.custom_rules

    content {
      name      = custom_rules.value.name
      priority  = custom_rules.value.priority
      action    = custom_rules.value.action
      rule_type = custom_rules.value.rule_type

      dynamic "match_conditions" {
        for_each = custom_rules.value.match_conditions

        content {
          operator           = match_conditions.value.operator
          match_values       = match_conditions.value.match_values
          negation_condition = match_conditions.value.negation_condition

          dynamic "match_variables" {
            for_each = match_conditions.value.match_variables

            content {
              variable_name = match_variables.value.variable_name
              selector      = match_variables.value.selector
            }
          }
        }
      }
    }
  }

  policy_settings {
    enabled                     = true
    mode                        = var.waf.mode
    request_body_check          = var.waf.request_body_check
    max_request_body_size_in_kb = var.waf.max_request_body_size_in_kb
    file_upload_limit_in_mb     = var.waf.file_upload_limit_in_mb
  }
}

module "suite" {
  source = "../suite"

  application_gateway_id = var.application_gateway_id
  suite_name             = var.business
  owned_name_prefix      = local.prefix

  backend_address_pools = {
    pool = {
      name  = local.pool_name
      fqdns = [var.apim_fqdn]
    }
  }

  backend_http_settings = {
    settings = {
      name                                = local.settings_name
      port                                = 443
      protocol                            = "Https"
      cookie_based_affinity               = "Disabled"
      pick_host_name_from_backend_address = true
      request_timeout                     = var.request_timeout
      probe_name                          = local.probe_name
      trusted_root_certificate_names      = [local.names.trusted_root_certificate]
    }
  }

  probes = {
    probe = {
      name                                      = local.probe_name
      protocol                                  = "Https"
      port                                      = 443
      path                                      = var.probe.path
      interval                                  = var.probe.interval
      timeout                                   = var.probe.timeout
      unhealthy_threshold                       = var.probe.unhealthy_threshold
      pick_host_name_from_backend_http_settings = true
      match = {
        status_code = var.probe.status_codes
      }
    }
  }

  http_listeners = {
    public = {
      name                           = local.listener_public
      frontend_ip_configuration_name = local.names.public_frontend_ip_configuration
      frontend_port_name             = local.names.https_frontend_port
      ssl_certificate_name           = local.names.ssl_certificate
      host_name                      = local.host_public
      firewall_policy_id             = azurerm_web_application_firewall_policy.this.id
    }
    private = {
      name                           = local.listener_private
      frontend_ip_configuration_name = local.names.private_frontend_ip_configuration
      frontend_port_name             = local.names.https_frontend_port
      ssl_certificate_name           = local.names.ssl_certificate
      host_name                      = local.host_private
      firewall_policy_id             = azurerm_web_application_firewall_policy.this.id
    }
    # Plain HTTP, for Azure Front Door only (the gateway's NSG allows port 80 from AzureFrontDoor.Backend)
    public_http = {
      name                           = local.listener_http
      frontend_ip_configuration_name = local.names.public_frontend_ip_configuration
      frontend_port_name             = local.names.http_frontend_port
      host_name                      = local.host_http
      firewall_policy_id             = azurerm_web_application_firewall_policy.this.id
    }
  }

  url_path_maps = {
    public  = merge(local.path_map_defaults, { name = local.path_map_public })
    private = merge(local.path_map_defaults, { name = local.path_map_private })
  }

  request_routing_rules = {
    public = {
      name               = "${local.b}-routing-rule-public"
      rule_type          = "PathBasedRouting"
      http_listener_name = local.listener_public
      url_path_map_name  = local.path_map_public
      priority           = var.priority_base
    }
    private = {
      name               = "${local.b}-routing-rule-private"
      rule_type          = "PathBasedRouting"
      http_listener_name = local.listener_private
      url_path_map_name  = local.path_map_private
      priority           = var.priority_base + 1
    }
    public_http = {
      name               = "${local.b}-routing-rule-public-http"
      rule_type          = "PathBasedRouting"
      http_listener_name = local.listener_http
      url_path_map_name  = local.path_map_public
      priority           = var.priority_base + 2
    }
  }
}

resource "azurerm_private_dns_a_record" "private_listener" {
  count = var.private_dns == null ? 0 : 1

  name                = "${var.environment_prefix}-agw-${var.business}"
  zone_name           = var.private_dns.zone_name
  resource_group_name = var.private_dns.resource_group_name
  ttl                 = 300
  records             = [var.private_dns.ip_address]
}

#----------Front Door (optional): send this business's paths to its HTTP listener-----------
resource "azurerm_cdn_frontdoor_origin_group" "this" {
  count = var.front_door == null ? 0 : 1

  name                     = "agw-${var.business}-origin-group"
  cdn_frontdoor_profile_id = var.front_door.profile_id
  session_affinity_enabled = false

  health_probe {
    interval_in_seconds = var.front_door.probe_interval
    path                = var.front_door.probe_path
    protocol            = "Http"
    request_type        = "GET"
  }

  load_balancing {
    additional_latency_in_milliseconds = 1000
    sample_size                        = 1
    successful_samples_required        = 1
  }
}

resource "azurerm_cdn_frontdoor_origin" "this" {
  count = var.front_door == null ? 0 : 1

  name                           = "agw-${var.business}-origin"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.this[0].id
  enabled                        = true
  host_name                      = var.front_door.origin_ip_address
  origin_host_header             = local.host_http
  http_port                      = 80
  https_port                     = 443
  certificate_name_check_enabled = false # HTTP only to the gateway; see eob-afd's README
  priority                       = 1
  weight                         = 1000
}

resource "azurerm_cdn_frontdoor_route" "this" {
  count = var.front_door == null ? 0 : 1

  name                          = "${var.business}-route"
  cdn_frontdoor_endpoint_id     = var.front_door.endpoint_id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this[0].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.this[0].id]
  patterns_to_match             = var.front_door.patterns_to_match
  supported_protocols           = var.front_door.supported_protocol
  forwarding_protocol           = "HttpOnly"
  https_redirect_enabled        = false
  link_to_default_domain        = true
  # No cache block: API responses are not cached at the edge

  # The listener must exist before Front Door sends traffic to it
  depends_on = [module.suite]
}
