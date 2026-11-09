# modules/suite

Upserts a named set of routing items (backend pools, backend HTTP settings, probes, HTTP listeners,
URL path maps, request routing rules) into an **existing** Application Gateway, without touching
items that belong to anyone else. Several state files (repos) can each own a suite on one gateway.

## Why

An Application Gateway is one ARM resource. Its routing items are arrays inside it, with no
child-resource API, so `azurerm_application_gateway` owns all of them: whoever applies last
overwrites everyone else. The root module of this repo (v1.1.0 and later) sets
`ignore_changes` on those arrays after creation, and suites add their items through this module.

## How it works

- The inputs are rendered to ARM JSON. References to items the suite doesn't own (the dead-end
  pool, `app-gateway-cert`, frontend IP configurations, ports, root certificates) are by name.
- `terraform_data.upsert` runs `scripts/agw-suite.sh upsert` at apply time when the desired items
  change or some of them are missing from the live gateway. The script:
  1. waits until the gateway isn't `Updating` and GETs it with its etag
  2. stops if the live items already match (no PUT)
  3. swaps the suite's items into each array (removing items it owns by name, or by
     `owned_name_prefix`, then adding the desired ones)
  4. PUTs the gateway with `If-Match: <etag>`, retrying on 412/409
  5. waits for `Succeeded` and checks the result, retrying if another suite overwrote it
- `terraform_data.registration` removes the suite's items when the suite is destroyed.

Each change is a single in-place PUT: the gateway is never recreated and other suites keep routing.

## Requirements

- `az` signed in (the deploy workflow runs `az login` before `terraform apply`) and `jq`, on the
  machine that runs `terraform apply`/`destroy`. `terraform plan` needs neither.
- Item names and routing-rule priorities must be unique across the gateway: give each suite its
  own prefix and priority range.

## Limits

- A saved plan for the gateway's root module (eob-agw) that changes gateway-level settings PUTs the
  routing arrays from its plan-time refresh; a suite applied between that plan and apply would be
  dropped and is restored by the suite's next run (the drift check sees the missing names).
- Drift is detected by name: an item that exists but was edited by hand is only corrected the next
  time the suite's inputs change.
