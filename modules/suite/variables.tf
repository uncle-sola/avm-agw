variable "application_gateway_id" {
  type        = string
  description = "Resource ID of the existing Application Gateway the suite's items are upserted into."
  nullable    = false
}

variable "suite_name" {
  type        = string
  description = "Name of the suite, used in log messages (for example `platform`, `echo`, `delta`)."
  nullable    = false
}

variable "owned_name_prefix" {
  type        = string
  default     = null
  description = <<-DESCRIPTION
Optional name prefix (for example `echo-`). When set, every item on the gateway whose name starts
with it is treated as owned by this suite: items that are no longer in the inputs (renamed or
deleted) are removed on the next upsert. Every item in the inputs must then start with the prefix.
When null, the suite owns exactly the names in its inputs.
DESCRIPTION
}

variable "backend_address_pools" {
  type = map(object({
    name         = string
    fqdns        = optional(list(string), [])
    ip_addresses = optional(list(string), [])
  }))
  default     = {}
  description = "Backend address pools, same shape as the root module's `backend_address_pools`."
  nullable    = false
}

variable "backend_http_settings" {
  type = map(object({
    name                                = string
    port                                = number
    protocol                            = string
    cookie_based_affinity               = optional(string, "Disabled")
    affinity_cookie_name                = optional(string)
    host_name                           = optional(string)
    path                                = optional(string)
    pick_host_name_from_backend_address = optional(bool)
    probe_name                          = optional(string)
    request_timeout                     = optional(number)
    trusted_root_certificate_names      = optional(list(string), [])
  }))
  default     = {}
  description = "Backend HTTP settings, same shape as the root module's `backend_http_settings`. `probe_name` and `trusted_root_certificate_names` may name items owned elsewhere."
  nullable    = false
}

variable "probes" {
  type = map(object({
    name                                      = string
    protocol                                  = string
    path                                      = string
    interval                                  = number
    timeout                                   = number
    unhealthy_threshold                       = number
    host                                      = optional(string)
    port                                      = optional(number)
    pick_host_name_from_backend_http_settings = optional(bool)
    minimum_servers                           = optional(number)
    match = optional(object({
      body        = optional(string)
      status_code = optional(list(string))
    }))
  }))
  default     = {}
  description = "Health probes, same shape as the root module's `probe_configurations`."
  nullable    = false
}

variable "http_listeners" {
  type = map(object({
    name                           = string
    frontend_ip_configuration_name = string
    frontend_port_name             = string
    host_name                      = optional(string)
    host_names                     = optional(list(string))
    require_sni                    = optional(bool)
    ssl_certificate_name           = optional(string)
    ssl_profile_name               = optional(string)
    firewall_policy_id             = optional(string)
  }))
  default     = {}
  description = <<-DESCRIPTION
HTTP listeners. The protocol is `Https` when `ssl_certificate_name` is set, otherwise `Http`.
Frontend IP configurations, frontend ports, SSL certificates and SSL profiles are gateway-level
items owned by the root module; refer to them by name. `firewall_policy_id` attaches a WAF policy to
this listener only.
DESCRIPTION
  nullable    = false
}

variable "url_path_maps" {
  type = map(object({
    name                               = string
    default_backend_address_pool_name  = string
    default_backend_http_settings_name = string
    path_rules = map(object({
      name                       = string
      paths                      = list(string)
      backend_address_pool_name  = string
      backend_http_settings_name = string
      firewall_policy_id         = optional(string)
    }))
  }))
  default     = {}
  description = "URL path maps, same shape as the root module's `url_path_map_configurations` (redirects and rewrites aren't supported). A path map is owned as a whole: its path rules are always replaced together."
  nullable    = false
}

variable "request_routing_rules" {
  type = map(object({
    name                       = string
    rule_type                  = string
    http_listener_name         = string
    priority                   = number
    url_path_map_name          = optional(string)
    backend_address_pool_name  = optional(string)
    backend_http_settings_name = optional(string)
  }))
  default     = {}
  description = <<-DESCRIPTION
Request routing rules. For `PathBasedRouting` set `url_path_map_name`; for `Basic` set
`backend_address_pool_name` and `backend_http_settings_name`. Priorities must be unique across the
whole gateway, so give each suite its own range.
DESCRIPTION
  nullable    = false
}
