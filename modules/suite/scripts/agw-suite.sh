#!/usr/bin/env bash
# Upserts or removes one suite's routing items on an existing Application Gateway.
#
#   agw-suite.sh upsert   needs AGW_ID, SUITE_NAME, DESIRED_JSON, OWNED_NAME_PREFIX (may be empty)
#   agw-suite.sh remove   needs AGW_ID, SUITE_NAME, OWNED_NAMES_JSON, OWNED_NAME_PREFIX (may be empty)
#
# Called by Terraform (modules/suite), not by hand. Needs az (signed in) and jq.
#
# An Application Gateway has no child-resource API, so every change is a PUT of the whole gateway.
# The script:
#   1. waits until the gateway isn't Updating, then GETs it with its etag
#   2. upsert only: if the suite's live items already match DESIRED_JSON, stops (no PUT)
#   3. in each collection, drops the items the suite owns (its names, or names starting with
#      OWNED_NAME_PREFIX) and, for upsert, appends the desired items
#   4. PUTs the gateway with If-Match: <etag>, so a change made by another suite in between is
#      rejected (412) instead of overwritten, then starts again from 1
#   5. waits for Succeeded and checks the result (desired names present, or owned names gone);
#      if another suite's PUT raced past If-Match, the check fails and it starts again from 1
set -euo pipefail

MODE="${1:?usage: agw-suite.sh upsert|remove}"
: "${AGW_ID:?AGW_ID is required}"
: "${SUITE_NAME:?SUITE_NAME is required}"
OWNED_NAME_PREFIX="${OWNED_NAME_PREFIX:-}"

API_VERSION="2024-05-01"
URL="https://management.azure.com${AGW_ID}?api-version=${API_VERSION}"
MAX_ATTEMPTS="${AGW_SUITE_MAX_ATTEMPTS:-10}"
TIMEOUT_SECONDS="${AGW_SUITE_TIMEOUT_SECONDS:-1800}"
POLL_SECONDS=15

log() { echo "[agw-suite:${SUITE_NAME}] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v az >/dev/null || die "az CLI not found"
command -v jq >/dev/null || die "jq not found"
az account show --output none 2>/dev/null || die "az is not signed in (run az login)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

COLLECTIONS='["backendAddressPools","backendHttpSettingsCollection","probes","httpListeners","urlPathMaps","requestRoutingRules"]'
STRIP_NULLS='walk(if type == "object" then with_entries(select(.value != null)) else . end)'

case "$MODE" in
  upsert)
    : "${DESIRED_JSON:?DESIRED_JSON is required for upsert}"
    jq "$STRIP_NULLS" <<<"$DESIRED_JSON" >"$TMP/desired.json"
    jq 'with_entries(.value |= map(.name))' "$TMP/desired.json" >"$TMP/owned.json"
    ;;
  remove)
    : "${OWNED_NAMES_JSON:?OWNED_NAMES_JSON is required for remove}"
    jq . <<<"$OWNED_NAMES_JSON" >"$TMP/owned.json"
    jq --argjson c "$COLLECTIONS" -n '[$c[] | {key: ., value: []}] | from_entries' >"$TMP/desired.json"
    ;;
  *) die "unknown mode '$MODE' (expected upsert or remove)" ;;
esac

# jq helpers shared by the in-sync check, the merge and the verification
JQ_LIB='
def owned($c; $n): (($o[0][$c] // []) | index($n)) != null or ($prefix != "" and ($n | startswith($prefix)));
def proj($d):
  if ($d | type) == "object" then
    . as $l | reduce ($d | keys_unsorted[]) as $k ({}; .[$k] = (($l | if type == "object" then .[$k] else null end) | proj($d[$k])))
  elif ($d | type) == "array" then
    . as $l | [range(0; $d | length) as $i | (($l | if type == "array" then .[$i] else null end) | proj($d[$i]))]
  else . end;
def lc: walk(if type == "string" then ascii_downcase else . end);
def by_name: map({(.name): .}) | add // {};
'

get_gateway() {
  az rest --method get --url "$URL" --output json >"$TMP/live.json"
}

wait_not_updating() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS)) state
  while :; do
    get_gateway
    state="$(jq -r '.properties.provisioningState' "$TMP/live.json")"
    case "$state" in
      Updating|Deleting) ;;
      Failed) die "gateway is in Failed state; fix it before deploying suites" ;;
      *) return 0 ;;
    esac
    ((SECONDS < deadline)) || die "timed out waiting for the gateway to leave $state"
    log "gateway is $state, waiting"
    sleep "$POLL_SECONDS"
  done
}

in_sync() {
  jq -e --slurpfile d "$TMP/desired.json" --slurpfile o "$TMP/owned.json" --arg prefix "$OWNED_NAME_PREFIX" \
    "$JQ_LIB"'
    $d[0] as $desired | $o[0] as $owned | . as $live |
    [ $desired | to_entries[] | .key as $c |
      ([$live.properties[$c][]? | select(owned($c; .name))] | by_name) as $l |
      (.value | by_name) as $w |
      (($l | keys) == ($w | keys)) and all($w | to_entries[]; .value as $v | ($l[.key] | proj($v) | lc) == ($v | lc))
    ] | all' "$TMP/live.json" >/dev/null
}

merge() {
  jq --slurpfile d "$TMP/desired.json" --slurpfile o "$TMP/owned.json" --arg prefix "$OWNED_NAME_PREFIX" \
    "$JQ_LIB"'
    $d[0] as $desired | $o[0] as $owned |
    reduce ($desired | keys[]) as $c (.;
      .properties[$c] = ([(.properties[$c] // [])[] | . as $i | select(owned($c; $i.name) | not)] + $desired[$c]))
    ' "$TMP/live.json" >"$TMP/body.json"
}

verify() {
  jq -e --slurpfile d "$TMP/desired.json" --slurpfile o "$TMP/owned.json" --arg prefix "$OWNED_NAME_PREFIX" --arg mode "$MODE" \
    "$JQ_LIB"'
    $d[0] as $desired | $o[0] as $owned | . as $live |
    if $mode == "upsert" then
      [$desired | to_entries[] | .key as $c | .value[] | .name as $n | any($live.properties[$c][]?; .name == $n)] | all
    else
      [$owned | keys[] as $c | $live.properties[$c][]? | select(owned($c; .name))] | length == 0
    end' "$TMP/live.json" >/dev/null
}

wait_succeeded() {
  local deadline=$((SECONDS + TIMEOUT_SECONDS)) state
  while :; do
    get_gateway
    state="$(jq -r '.properties.provisioningState' "$TMP/live.json")"
    case "$state" in
      Succeeded) return 0 ;;
      Failed) die "gateway update failed; see the gateway's activity log" ;;
    esac
    ((SECONDS < deadline)) || die "timed out waiting for the gateway update (state $state)"
    sleep "$POLL_SECONDS"
  done
}

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
  wait_not_updating

  if [[ "$MODE" == "upsert" ]] && in_sync; then
    log "live items already match, nothing to do"
    exit 0
  fi
  if [[ "$MODE" == "remove" ]] && verify; then
    log "no items owned by this suite on the gateway, nothing to do"
    exit 0
  fi

  merge
  etag="$(jq -r '.etag' "$TMP/live.json")"
  headers="$(jq -nc --arg e "$etag" '{"If-Match": $e, "Content-Type": "application/json"}')"

  log "attempt $attempt: ${MODE} (PUT with If-Match $etag)"
  if ! az rest --method put --url "$URL" --headers "$headers" --body "@$TMP/body.json" --output none 2>"$TMP/err.txt"; then
    if grep -qiE 'PreconditionFailed|412' "$TMP/err.txt"; then
      log "gateway changed since it was read (412), retrying"
    elif grep -qiE 'AnotherOperationInProgress|Conflict|409|RetryableError|429|TooManyRequests' "$TMP/err.txt"; then
      log "gateway busy, retrying: $(head -c 300 "$TMP/err.txt")"
      sleep $((POLL_SECONDS * attempt))
    else
      cat "$TMP/err.txt" >&2
      die "PUT failed"
    fi
    continue
  fi

  wait_succeeded
  if verify; then
    log "${MODE} done"
    exit 0
  fi
  log "result check failed (another suite's update may have overwritten this one), retrying"
done

die "gave up after $MAX_ATTEMPTS attempts"
