variable "business" {
  type        = string
  description = "Short business name (for example `echo`, `delta`). Every gateway item this module creates is named `<business>-...` and owned by prefix."
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,20}$", var.business))
    error_message = "business must be lower-case letters and digits, starting with a letter (2-21 characters)."
  }
}

variable "application_gateway_id" {
  type        = string
  description = "Resource ID of the existing Application Gateway."
  nullable    = false
}

variable "environment_prefix" {
  type        = string
  description = "Lower-case environment name used in host names (`dev`, `pre`, `prd`). Hosts are `<env>-agw-<business>-ext`, `<env>-agw-<business>` and `<env>-agw-<business>-http` under `domain`."
  nullable    = false
}

variable "domain" {
  type        = string
  description = "DNS domain of the listener host names, for example `delta.com`."
  nullable    = false
}

variable "apim_fqdn" {
  type        = string
  description = "FQDN of the APIM gateway the backend pool points at, for example `dev-apim.delta.com`."
  nullable    = false
}

variable "path_map" {
  type = object({
    default_backend_address_pool_name  = optional(string, "deadEndPool")
    default_backend_http_settings_name = optional(string, "null-backend-http-settings")
    path_rules = map(object({
      paths                      = list(string)
      backend_address_pool_name  = optional(string) # defaults to this business's pool
      backend_http_settings_name = optional(string) # defaults to this business's settings
      firewall_policy_id         = optional(string) # per-path WAF override
    }))
  })
  description = <<-DESCRIPTION
The business's path map. It is rendered twice, as `<business>-public-path-map` (public HTTPS and
Front Door HTTP listeners) and `<business>-private-path-map` (private listener). Each path rule is
named `<business>-<key>`. Requests that match no path go to the default pool (the gateway's dead-end
pool unless set).
DESCRIPTION
  nullable    = false
}

variable "priority_base" {
  type        = number
  description = "First of three consecutive routing-rule priorities (public, private, public HTTP). Must not overlap any other suite on the gateway."
  nullable    = false
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the business's WAF policy (normally the gateway's)."
  nullable    = false
}

variable "location" {
  type        = string
  description = "Azure region for the WAF policy."
  nullable    = false
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags for the WAF policy."
}

variable "gateway_item_names" {
  type = object({
    public_frontend_ip_configuration  = optional(string, "appGwPublicFrontendIp")
    private_frontend_ip_configuration = optional(string, "appGwPrivateFrontendIp")
    https_frontend_port               = optional(string, "port_443")
    http_frontend_port                = optional(string, "port_80")
    ssl_certificate                   = optional(string, "app-gateway-cert")
    trusted_root_certificate          = optional(string, "root-cert")
  })
  default     = {}
  description = "Names of the gateway-level items (owned by the gateway's root module) that the listeners and settings refer to."
  nullable    = false
}

variable "probe" {
  type = object({
    path                = optional(string, "/status-0123456789abcdef")
    interval            = optional(number, 30)
    timeout             = optional(number, 30)
    unhealthy_threshold = optional(number, 8)
    status_codes        = optional(list(string), ["200-399"])
  })
  default     = {}
  description = "Health probe for the business's backend settings. The default path is APIM's status endpoint."
  nullable    = false
}

variable "request_timeout" {
  type        = number
  default     = 300
  description = "Backend request timeout in seconds."
}

variable "waf" {
  type = object({
    mode                        = optional(string, "Prevention")
    owasp_version               = optional(string, "3.2")
    request_body_check          = optional(bool, true)
    max_request_body_size_in_kb = optional(number, 128)
    file_upload_limit_in_mb     = optional(number, 100)
    custom_rules = optional(list(object({
      name      = string
      priority  = number
      action    = string
      rule_type = optional(string, "MatchRule")
      match_conditions = list(object({
        operator           = string
        match_values       = list(string)
        negation_condition = optional(bool, false)
        match_variables = list(object({
          variable_name = string
          selector      = optional(string)
        }))
      }))
    })), [])
  })
  default     = {}
  description = "The business's WAF policy, attached to its three listeners. Managed rules are OWASP with the same overrides as the gateway's own policy."
  nullable    = false
}

variable "private_dns" {
  type = object({
    zone_name           = string
    resource_group_name = string
    ip_address          = string
  })
  default     = null
  description = "When set, an A record `<env>-agw-<business>` pointing at the gateway's private IP is created in this private DNS zone."
}

variable "front_door" {
  type = object({
    profile_id         = string
    endpoint_id        = string
    origin_ip_address  = string
    patterns_to_match  = list(string)
    probe_path         = optional(string, "/status-0123456789abcdef")
    probe_interval     = optional(number, 250)
    supported_protocol = optional(list(string), ["Http", "Https"])
  })
  default     = null
  description = <<-DESCRIPTION
When set, adds a Front Door origin group `agw-<business>-origin-group`, origin (the gateway's public
IP with host header `<env>-agw-<business>-http.<domain>`) and route `<business>-route` on an existing
endpoint. `patterns_to_match` must not overlap another route on the endpoint (the endpoint's `/*`
default route is fine: the more specific pattern wins).
DESCRIPTION
}
