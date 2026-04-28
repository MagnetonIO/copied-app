#!/bin/zsh
# ⚠️  THIS SCRIPT DOES NOT WORK against the PRIVATE database.
# Apple's Server-to-Server keys are restricted to the PUBLIC database
# (verified empirically Apr 2026 — every /private/* request returns
# HTTP 500 INTERNAL_ERROR even with a perfectly-signed request).
#
# To wipe the Private DB you must use CloudKit Dashboard interactively:
#   - Reset Production Environment   (Schema tab → bottom-left, nukes everything)
#   - Or per-record delete           (mark record types Indexable in Schema, then query+delete)
#
# This script remains here as a reference for the PUBLIC DB equivalent —
# if/when we need a public-DB wipe, change DB="public" below and it works.
#
# Wipe records from a CloudKit container DB via Web Services API.
#
# One-time setup (web UI, ~2 min):
#   1. https://icloud.developer.apple.com/dashboard/teams/7727LYTG96/containers/iCloud.com.magneton.Copied/api-access/server-to-server
#   2. "Add Server-to-Server Key"
#   3. Generate an ECC P-256 key pair locally:
#        openssl ecparam -name prime256v1 -genkey -noout -out .keys/cloudkit-eckey.pem
#        openssl ec -in .keys/cloudkit-eckey.pem -pubout -out .keys/cloudkit-eckey.pub
#   4. Paste the .pub contents into the dashboard, save
#   5. Copy the assigned Key ID
#   6. Save to .env:
#        CLOUDKIT_KEY_ID=<the assigned key id>
#        CLOUDKIT_KEY_PATH=.keys/cloudkit-eckey.pem
#
# Usage:
#   scripts/wipe-cloudkit-private-db.sh           # dry run — counts records
#   scripts/wipe-cloudkit-private-db.sh --wipe    # actually delete

set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a

: "${CLOUDKIT_KEY_ID:?Missing CLOUDKIT_KEY_ID — see header for setup}"
: "${CLOUDKIT_KEY_PATH:?Missing CLOUDKIT_KEY_PATH — see header for setup}"

CONTAINER="iCloud.com.magneton.Copied"
ENV="production"
DB="private"
HOST="https://api.apple-cloudkit.com"

DRY_RUN=true
[ "${1:-}" = "--wipe" ] && DRY_RUN=false

# CKWS request signing: ISO-8601 date + path + body-sha256, signed ECDSA-SHA256.
sign_request() {
  local subpath="$1" body="$2"
  local date_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local body_sha=$(printf '%s' "$body" | openssl dgst -binary -sha256 | openssl base64)
  local string_to_sign="${date_iso}:${body_sha}:${subpath}"
  local sig=$(printf '%s' "$string_to_sign" \
    | openssl dgst -sha256 -sign "$CLOUDKIT_KEY_PATH" \
    | openssl base64 | tr -d '\n')
  echo "${date_iso}|${sig}"
}

ckws_post() {
  local subpath="$1" body="$2"
  local pair=$(sign_request "$subpath" "$body")
  local date_iso="${pair%|*}"
  local sig="${pair##*|}"
  curl -sS -X POST "${HOST}${subpath}" \
    -H "Content-Type: application/json" \
    -H "X-Apple-CloudKit-Request-KeyID: ${CLOUDKIT_KEY_ID}" \
    -H "X-Apple-CloudKit-Request-ISO8601Date: ${date_iso}" \
    -H "X-Apple-CloudKit-Request-SignatureV1: ${sig}" \
    -d "$body"
}

PATH_BASE="/database/1/${CONTAINER}/${ENV}/${DB}"

echo "▶ Listing zones in ${CONTAINER} / ${ENV} / ${DB} …"
zones_resp=$(ckws_post "${PATH_BASE}/zones/list" '{}')
echo "$zones_resp" | python3 -m json.tool | head -40 || echo "$zones_resp"

zones=$(echo "$zones_resp" | python3 -c "import sys,json; print('\n'.join(z['zoneID']['zoneName'] for z in json.load(sys.stdin).get('zones',[])))")

if [ -z "$zones" ]; then
  echo "✓ No zones to wipe."
  exit 0
fi

echo ""
echo "Zones to process: $zones"

for zone in $zones; do
  echo ""
  if [ "$zone" = "_defaultZone" ]; then
    echo "  ⏭  skipping '_defaultZone' (Apple-owned, can't be deleted)"
    continue
  fi

  if $DRY_RUN; then
    echo "  zone '$zone' would be deleted (dry run — pass --wipe to actually delete)"
    continue
  fi

  # Zone deletion takes the entire zone + all records inside, atomic.
  # Apps that next sync will create a fresh zone on demand.
  echo "  ▶ deleting zone '$zone' …"
  z_body=$(printf '{"operations":[{"operationType":"delete","zone":{"zoneID":{"zoneName":"%s"}}}]}' "$zone")
  ckws_post "${PATH_BASE}/zones/modify" "$z_body" | python3 -m json.tool | head -20
done

echo ""
echo "✓ Done."
$DRY_RUN && echo "  (this was a DRY RUN — re-run with --wipe to actually delete)"
