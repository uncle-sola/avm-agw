# modules/business-suite

One business's routing on a shared Application Gateway, built on [`../suite`](../suite). Called once
per business repo (for example eob-agw-echo, eob-agw-delta) with `business` and its `path_map`.

Creates, all named `<business>-...` and owned by that prefix:

| Item | Name |
|---|---|
| Backend pool (APIM gateway FQDN) | `<b>-backend-pool` |
| Backend HTTPS settings, probe | `<b>-backend-http-settings`, `<b>-probe` |
| WAF policy (attached to the three listeners) | `<b>-agw-waf` |
| Listeners | `<b>-listener-public` (`<env>-agw-<b>-ext.<domain>`, 443), `<b>-listener-private` (`<env>-agw-<b>.<domain>`, 443), `<b>-listener-public-http` (`<env>-agw-<b>-http.<domain>`, 80, Front Door only) |
| Path maps from `path_map` | `<b>-public-path-map`, `<b>-private-path-map`, rules `<b>-<key>` |
| Routing rules | `<b>-routing-rule-public`, `-private`, `-public-http` at `priority_base`, `+1`, `+2` |

Optional: a private DNS A record `<env>-agw-<b>` (`private_dns`), and a Front Door origin group,
origin and route on an existing endpoint (`front_door`).

```hcl
module "suite" {
  source = "git::https://github.com/uncle-sola/avm-agw.git//modules/business-suite?ref=<sha>"

  business               = "echo"
  application_gateway_id = data.azurerm_application_gateway.agw.id
  environment_prefix     = "dev"
  domain                 = "delta.com"
  apim_fqdn              = "dev-apim.delta.com"
  priority_base          = 200
  resource_group_name    = "dev-eob-uks-rg-agw"
  location               = "uksouth"

  path_map = {
    path_rules = {
      apiPathRule           = { paths = ["/echotest/v1/*", "/echotest/v2/*", "/echotest/v3/*"] }
      serviceStatusPathRule = { paths = ["/status-0123456789abcdef"] }
    }
  }
}
```
