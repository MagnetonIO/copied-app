#!/bin/zsh
# Orchestrates the full local Stripe License test flow so you can go from
# "fresh checkout" to "click Unlock and pay $4.99 test card" in one command.
#
# What it does:
#   1. Fetches your test-mode sk_test_ from `stripe config`.
#   2. Ensures a test-mode product + price exist (creates if needed, otherwise
#      reuses what's recorded in .keys/stripe-test.env).
#   3. Starts `stripe listen --forward-to localhost:3000/webhook` in the
#      background; captures the `whsec_…` it prints.
#   4. Writes webhook-dev/.env.local with all four env vars.
#   5. Starts the webhook-dev Node server in the background.
#   6. Sets the DEBUG UserDefaults override so the app opens localhost for
#      Stripe Checkout instead of getcopied.app.
#   7. Prints next-step instructions.
#
# Stop everything later:   ./scripts/test-license-flow.sh stop

set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd -P)"
WEBHOOK_DIR="/Users/mlong/Documents/Development/getcopied-app/webhook-dev"
STATE_DIR=".keys/stripe-test"
mkdir -p "$STATE_DIR"
PRICE_FILE="$STATE_DIR/price-id"
STRIPE_LISTEN_PID_FILE="$STATE_DIR/stripe-listen.pid"
SERVER_PID_FILE="$STATE_DIR/server.pid"
STRIPE_LISTEN_LOG="$STATE_DIR/stripe-listen.log"
SERVER_LOG="$STATE_DIR/server.log"

cmd="${1:-start}"

stop_procs() {
  for pf in "$STRIPE_LISTEN_PID_FILE" "$SERVER_PID_FILE"; do
    if [ -f "$pf" ]; then
      pid="$(cat "$pf")"
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        echo "Stopped pid $pid"
      fi
      rm -f "$pf"
    fi
  done
}

if [ "$cmd" = "stop" ]; then
  stop_procs
  defaults delete com.magneton.copied CopiedStripeLocalOverride 2>/dev/null || true
  echo "Cleared CopiedStripeLocalOverride default."
  exit 0
fi

# ── prereq checks ────────────────────────────────────────────────────────

command -v stripe >/dev/null || { echo "stripe CLI not found (brew install stripe/stripe-cli/stripe)" >&2; exit 1; }
command -v node   >/dev/null || { echo "node not found" >&2; exit 1; }

if ! stripe whoami >/dev/null 2>&1; then
  echo "stripe CLI is not logged in. Run: stripe login" >&2
  exit 1
fi

PRIV_KEY="$REPO_ROOT/.keys/license/signing.pem"
if [ ! -f "$PRIV_KEY" ]; then
  echo "Missing $PRIV_KEY. Generate with: openssl genpkey -algorithm ed25519 -out $PRIV_KEY" >&2
  exit 1
fi

# ── stripe keys ──────────────────────────────────────────────────────────

STRIPE_SECRET_KEY="$(stripe config --list | awk -F"'" '/^test_mode_api_key = /{print $2; exit}')"
if [ -z "$STRIPE_SECRET_KEY" ]; then
  echo "Could not read test_mode_api_key from stripe config." >&2
  exit 1
fi

# ── price id (cache so reruns are instant) ───────────────────────────────

if [ -s "$PRICE_FILE" ]; then
  STRIPE_PRICE_ID="$(cat "$PRICE_FILE")"
  echo "Reusing cached price id: $STRIPE_PRICE_ID"
else
  echo "Creating Stripe test product + price..."
  product_json="$(stripe products create --name "Copied iCloud Sync" --description "Direct-download license for cross-Mac clipboard sync via iCloud.")"
  product_id="$(printf '%s' "$product_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")"
  price_json="$(stripe prices create --product "$product_id" --currency usd --unit-amount 499)"
  STRIPE_PRICE_ID="$(printf '%s' "$price_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")"
  printf '%s' "$STRIPE_PRICE_ID" > "$PRICE_FILE"
  echo "Created price: $STRIPE_PRICE_ID"
fi

# ── stop any previous run ───────────────────────────────────────────────

stop_procs

# ── stripe webhook secret (deterministic per CLI device) ───────────────

WEBHOOK_SECRET="$(stripe listen --print-secret 2>/dev/null | head -1)"
if [ -z "$WEBHOOK_SECRET" ]; then
  echo "Could not get webhook secret from stripe CLI. Try: stripe login" >&2
  exit 1
fi
echo "Webhook secret: ${WEBHOOK_SECRET:0:12}…"

echo "Starting stripe listen forwarder..."
: > "$STRIPE_LISTEN_LOG"
nohup stripe listen --forward-to localhost:3000/webhook > "$STRIPE_LISTEN_LOG" 2>&1 &
echo $! > "$STRIPE_LISTEN_PID_FILE"
disown %1 2>/dev/null || true

# ── write .env.local ─────────────────────────────────────────────────────
# Stripe config is generated from `stripe config` + `stripe listen`; EmailJS
# config (optional) comes from .keys/emailjs.env which the user populates
# once. Both files are gitignored via the .keys/ root entry.

EMAILJS_BLOCK=""
if [ -f "$REPO_ROOT/.keys/emailjs.env" ]; then
  # Copy the EmailJS lines verbatim so we don't have to care about variable
  # naming; assumes the file uses EMAILJS_SERVICE_ID, EMAILJS_TEMPLATE_ID,
  # EMAILJS_PUBLIC_KEY, EMAILJS_PRIVATE_KEY.
  EMAILJS_BLOCK="$(grep -E '^EMAILJS_' "$REPO_ROOT/.keys/emailjs.env")"
  echo "Loaded EmailJS config from .keys/emailjs.env"
else
  echo "No .keys/emailjs.env — emails will be skipped. See .keys/emailjs.env.example"
fi

{
  echo "STRIPE_SECRET_KEY=$STRIPE_SECRET_KEY"
  echo "STRIPE_PRICE_ID=$STRIPE_PRICE_ID"
  echo "STRIPE_WEBHOOK_SECRET=$WEBHOOK_SECRET"
  echo "LICENSE_PRIVATE_KEY_PATH=$PRIV_KEY"
  [ -n "$EMAILJS_BLOCK" ] && echo "$EMAILJS_BLOCK"
} > "$WEBHOOK_DIR/.env.local"
chmod 600 "$WEBHOOK_DIR/.env.local"

# ── launch webhook-dev ──────────────────────────────────────────────────

echo "Starting webhook-dev server on :3000..."
: > "$SERVER_LOG"
(
  cd "$WEBHOOK_DIR"
  set -a; . ./.env.local; set +a
  export PORT=3000
  nohup node server.js > "$REPO_ROOT/$SERVER_LOG" 2>&1 &
  echo $! > "$REPO_ROOT/$SERVER_PID_FILE"
)

for i in {1..30}; do
  if grep -q "listening on" "$SERVER_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.3
done
if ! grep -q "listening on" "$SERVER_LOG" 2>/dev/null; then
  echo "webhook-dev server didn't come up. Log:" >&2
  tail -15 "$SERVER_LOG" >&2
  stop_procs
  exit 1
fi

# ── point DEBUG app at localhost ────────────────────────────────────────

defaults write com.magneton.copied CopiedStripeLocalOverride "http://localhost:3000/buy?app=mac"

cat <<EOF

✅ Stripe test harness ready.

  stripe listen    → pid $(cat "$STRIPE_LISTEN_PID_FILE") (log: $STRIPE_LISTEN_LOG)
  webhook server   → pid $(cat "$SERVER_PID_FILE")        (log: $SERVER_LOG)
  price            → $STRIPE_PRICE_ID
  DEBUG override   → http://localhost:3000/buy?app=mac

Next steps:
  1. ./scripts/build.sh paid-license    # builds + installs a DEBUG License PKG
  2. Launch Copied, ⌘, → Sync → Unlock iCloud Sync — \$4.99
  3. In the Stripe Checkout page, pay with 4242 4242 4242 4242, any future exp, any CVC
  4. Browser redirects to localhost:3000/unlock → deep-links copied://unlock?key=…
  5. App catches it → Keychain → restart → Sync is active.

Stop everything:
  ./scripts/test-license-flow.sh stop

Tail logs:
  tail -f $STRIPE_LISTEN_LOG $SERVER_LOG
EOF
