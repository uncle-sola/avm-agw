#----------Suite: a named set of routing items upserted into an existing Application Gateway-----------
# An Application Gateway is one ARM resource: its pools, settings, probes, listeners, path maps and
# rules are arrays inside it, with no child-resource API. This module renders its inputs to ARM JSON
# and, at apply time, scripts/agw-suite.sh reads the live gateway, swaps this suite's items in (by
# name) and PUTs it back with If-Match, so other suites' items are kept. Nothing is ever recreated.

locals {
  gw_parts            = split("/", var.application_gateway_id)
  gateway_rg          = local.gw_parts[4]
  gateway_name        = local.gw_parts[8]
  gateway_id          = var.application_gateway_id
  owned_name_prefix   = var.owned_name_prefix == null ? "" : var.owned_name_prefix
  script_path         = "${path.module}/scripts/agw-suite.sh"
  subresource_id_base = "${local.gateway_id}/"

  backend_address_pools = [for k, p in var.backend_address_pools : {
    name = p.name
    properties = {
      backendAddresses = concat(
        [for f in p.fqdns : { fqdn = f }],
        [for ip in p.ip_addresses : { ipAddress = ip }],
      )
    }
  }]

  backend_http_settings = [for k, s in var.backend_http_settings : {
    name = s.name
    properties = {
      port                           = s.port
      protocol                       = s.protocol
      cookieBasedAffinity            = s.cookie_based_affinity
      affinityCookieName             = s.affinity_cookie_name
      hostName                       = s.host_name
      path                           = s.path
      pickHostNameFromBackendAddress = s.pick_host_name_from_backend_address
      requestTimeout                 = s.request_timeout
      probe                          = s.probe_name == null ? null : { id = "${local.subresource_id_base}probes/${s.probe_name}" }
      trustedRootCertificates        = [for c in s.trusted_root_certificate_names : { id = "${local.subresource_id_base}trustedRootCertificates/${c}" }]
    }
  }]

  probes = [for k, p in var.probes : {
    name = p.name
    properties = {
      protocol                            = p.protocol
      path                                = p.path
      interval                            = p.interval
      timeout                             = p.timeout
      unhealthyThreshold                  = p.unhealthy_threshold
      host                                = p.host
      port                                = p.port
      pickHostNameFromBackendHttpSettings = p.pick_host_name_from_backend_http_settings
      minServers                          = p.minimum_servers
      match = p.match == null ? null : {
        body        = p.match.body
        statusCodes = p.match.status_code
      }
    }
  }]

  http_listeners = [for k, l in var.http_listeners : {
    name = l.name
    properties = {
      frontendIPConfiguration     = { id = "${local.subresource_id_base}frontendIPConfigurations/${l.frontend_ip_configuration_name}" }
      frontendPort                = { id = "${local.subresource_id_base}frontendPorts/${l.frontend_port_name}" }
      protocol                    = l.ssl_certificate_name == null ? "Http" : "Https"
      hostName                    = l.host_name
      hostNames                   = l.host_names
      requireServerNameIndication = l.require_sni
      sslCertificate              = l.ssl_certificate_name == null ? null : { id = "${local.subresource_id_base}sslCertificates/${l.ssl_certificate_name}" }
      sslProfile                  = l.ssl_profile_name == null ? null : { id = "${local.subresource_id_base}sslProfiles/${l.ssl_profile_name}" }
      firewallPolicy              = l.firewall_policy_id == null ? null : { id = l.firewall_policy_id }
    }
  }]

  url_path_maps = [for k, m in var.url_path_maps : {
    name = m.name
    properties = {
      defaultBackendAddressPool  = { id = "${local.subresource_id_base}backendAddressPools/${m.default_backend_address_pool_name}" }
      defaultBackendHttpSettings = { id = "${local.subresource_id_base}backendHttpSettingsCollection/${m.default_backend_http_settings_name}" }
      pathRules = [for rk, r in m.path_rules : {
        name = r.name
        properties = {
          paths               = r.paths
          backendAddressPool  = { id = "${local.subresource_id_base}backendAddressPools/${r.backend_address_pool_name}" }
          backendHttpSettings = { id = "${local.subresource_id_base}backendHttpSettingsCollection/${r.backend_http_settings_name}" }
          firewallPolicy      = r.firewall_policy_id == null ? null : { id = r.firewall_policy_id }
        }
      }]
    }
  }]

  request_routing_rules = [for k, r in var.request_routing_rules : {
    name = r.name
    properties = {
      ruleType            = r.rule_type
      priority            = r.priority
      httpListener        = { id = "${local.subresource_id_base}httpListeners/${r.http_listener_name}" }
      urlPathMap          = r.url_path_map_name == null ? null : { id = "${local.subresource_id_base}urlPathMaps/${r.url_path_map_name}" }
      backendAddressPool  = r.backend_address_pool_name == null ? null : { id = "${local.subresource_id_base}backendAddressPools/${r.backend_address_pool_name}" }
      backendHttpSettings = r.backend_http_settings_name == null ? null : { id = "${local.subresource_id_base}backendHttpSettingsCollection/${r.backend_http_settings_name}" }
    }
  }]

  # ARM collection name => items. The script strips nulls before merging.
  desired = {
    backendAddressPools           = local.backend_address_pools
    backendHttpSettingsCollection = local.backend_http_settings
    probes                        = local.probes
    httpListeners                 = local.http_listeners
    urlPathMaps                   = local.url_path_maps
    requestRoutingRules           = local.request_routing_rules
  }
  desired_json = jsonencode(local.desired)

  owned_names = { for coll, items in local.desired : coll => [for i in items : i.name] }

  # Names this suite expects that aren't on the live gateway (someone removed them, or the gateway
  # was rebuilt). Any change here re-runs the upsert, which repairs the drift.
  live_names = {
    backendAddressPools           = [for i in data.azurerm_application_gateway.this.backend_address_pool : i.name]
    backendHttpSettingsCollection = [for i in data.azurerm_application_gateway.this.backend_http_settings : i.name]
    probes                        = [for i in data.azurerm_application_gateway.this.probe : i.name]
    httpListeners                 = [for i in data.azurerm_application_gateway.this.http_listener : i.name]
    urlPathMaps                   = [for i in data.azurerm_application_gateway.this.url_path_map : i.name]
    requestRoutingRules           = [for i in data.azurerm_application_gateway.this.request_routing_rule : i.name]
  }
  missing_names = sort(flatten([
    for coll, names in local.owned_names : [for n in names : "${coll}/${n}" if !contains(local.live_names[coll], n)]
  ]))
}

check "names_match_prefix" {
  assert {
    condition = local.owned_name_prefix == "" || alltrue(flatten([
      for coll, names in local.owned_names : [for n in names : startswith(n, local.owned_name_prefix)]
    ]))
    error_message = "Every item name in suite ${var.suite_name} must start with owned_name_prefix '${local.owned_name_prefix}'."
  }
}

data "azurerm_application_gateway" "this" {
  name                = local.gateway_name
  resource_group_name = local.gateway_rg
}

# Runs the upsert when the desired items change or some of them are missing from the gateway.
# The script compares the live items with the desired ones first and skips the PUT when they
# already match, so a re-run is cheap.
resource "terraform_data" "upsert" {
  triggers_replace = {
    desired_sha = sha256(local.desired_json)
    prefix      = local.owned_name_prefix
    in_sync     = length(local.missing_names) == 0
  }

  provisioner "local-exec" {
    command = "bash '${local.script_path}' upsert"
    environment = {
      AGW_ID            = local.gateway_id
      SUITE_NAME        = var.suite_name
      OWNED_NAME_PREFIX = local.owned_name_prefix
      DESIRED_JSON      = local.desired_json
    }
  }
}

# Holds what this suite owns so that destroying it (terraform destroy, or removing the module call)
# removes its items from the gateway. Destroy-time provisioners can only read self, so everything
# the script needs is kept in input. Changing input is an in-place update and runs nothing.
resource "terraform_data" "registration" {
  input = {
    agw_id            = local.gateway_id
    suite_name        = var.suite_name
    owned_name_prefix = local.owned_name_prefix
    owned_names_json  = jsonencode(local.owned_names)
    script_path       = local.script_path
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${self.input.script_path}' remove"
    environment = {
      AGW_ID            = self.input.agw_id
      SUITE_NAME        = self.input.suite_name
      OWNED_NAME_PREFIX = self.input.owned_name_prefix
      OWNED_NAMES_JSON  = self.input.owned_names_json
    }
  }

  depends_on = [terraform_data.upsert]
}
