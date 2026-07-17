#!/bin/zsh
# Sign a license payload with the Ed25519 private key at .keys/license/signing.pem.
# Produces a license string in the format:   <base64url(payload)>.<base64url(sig)>
# that the app's LicenseValidator accepts.
#
# Usage:
#   scripts/sign-license.sh user@example.com      # email only; uses sensible defaults
#   scripts/sign-license.sh user@example.com 3    # email + deviceLimit
#
# For testing only — production license issuance happens in the Stripe webhook
# service on `checkout.session.completed`.

set -euo pipefail
cd "$(dirname "$0")/.."

email="${1:-test@example.com}"
device_limit="${2:-3}"
product="copied-mac-icloud"
purchased_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
priv=".keys/license/signing.pem"

[ -f "$priv" ] || { echo "Missing $priv — generate with: openssl genpkey -algorithm ed25519 -out $priv" >&2; exit 1; }

# Canonical JSON (field order must match what the app's JSONDecoder expects; since
# JSONDecoder is order-insensitive for Codable, order doesn't matter signature-wise,
# but we sign exactly these bytes so the verifier must see the same bytes.)
payload=$(printf '{"product":"%s","email":"%s","purchasedAt":"%s","deviceLimit":%s}' \
  "$product" "$email" "$purchased_at" "$device_limit")

# base64url helper: base64 then -→+ → _→/ swap reversed, strip padding
b64url() {
  base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

payload_b64=$(printf '%s' "$payload" | b64url)

# Sign raw payload bytes with Ed25519. Use a temp file because macOS LibreSSL's
# pkeyutl -rawin requires a seekable input.
tmp=$(mktemp -t sign-license)
printf '%s' "$payload" > "$tmp"
sig_b64=$(openssl pkeyutl -sign -rawin -inkey "$priv" -in "$tmp" | b64url)
rm -f "$tmp"

license="$payload_b64.$sig_b64"

echo "Payload:  $payload"
echo ""
echo "License key:"
echo "$license"
echo ""
echo "Deep-link (paste into browser):"
echo "copied://unlock?key=$license"
