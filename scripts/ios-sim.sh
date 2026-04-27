#!/bin/zsh
# Copied iOS Simulator harness.
#
# Thin wrapper around `xcrun simctl` so the simulator-tester agent doesn't
# need to re-learn the incantations every time. All commands operate on
# the "booted" device, which defaults to COPIED_SIM_NAME if nothing is
# already booted.
#
# Usage:
#   ./scripts/ios-sim.sh boot           # boot COPIED_SIM_NAME (iPhone 17 Pro)
#   ./scripts/ios-sim.sh install        # install build/ios-sim/Copied.app on booted sim
#   ./scripts/ios-sim.sh launch         # launch com.magneton.copied on booted sim
#   ./scripts/ios-sim.sh run            # boot + install + launch in one shot
#   ./scripts/ios-sim.sh shot PATH      # screenshot booted sim to PATH (default build/ios-sim/shot.png)
#   ./scripts/ios-sim.sh pbcopy "TEXT"  # push TEXT onto the simulator clipboard
#   ./scripts/ios-sim.sh reset          # shutdown + erase booted sim
#   ./scripts/ios-sim.sh uninstall      # remove com.magneton.copied from booted sim

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.magneton.copied"
APP_PATH="${COPIED_IOS_APP_PATH:-build/ios-sim/Copied.app}"
SIM_NAME="${COPIED_SIM_NAME:-iPhone 17 Pro}"

booted_id() {
  xcrun simctl list devices booted 2>/dev/null | awk -F'[()]' '/Booted/ {print $2; exit}'
}

ensure_booted() {
  local id
  id="$(booted_id)"
  if [ -z "$id" ]; then
    echo "→ No booted simulator. Booting '$SIM_NAME'…"
    # `simctl boot` returns non-zero if the named device is already Booting;
    # swallow that — we poll below to confirm it reaches Booted either way.
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    open -a Simulator
    until xcrun simctl list devices booted 2>/dev/null | grep -q Booted; do sleep 1; done
    id="$(booted_id)"
  fi
  echo "$id"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  boot)
    ensure_booted >/dev/null
    echo "✓ Booted: $(booted_id)"
    ;;
  install)
    ensure_booted >/dev/null
    [ -d "$APP_PATH" ] || { echo "✗ No app at $APP_PATH — run ./scripts/build.sh ios first"; exit 1; }
    xcrun simctl install booted "$APP_PATH"
    echo "✓ Installed $APP_PATH"
    ;;
  launch)
    ensure_booted >/dev/null
    xcrun simctl launch booted "$BUNDLE_ID"
    echo "✓ Launched $BUNDLE_ID"
    ;;
  run)
    ensure_booted >/dev/null
    [ -d "$APP_PATH" ] || { echo "✗ No app at $APP_PATH — run ./scripts/build.sh ios first"; exit 1; }
    xcrun simctl install booted "$APP_PATH"
    xcrun simctl launch booted "$BUNDLE_ID"
    echo "✓ Running $BUNDLE_ID on booted sim"
    ;;
  shot)
    ensure_booted >/dev/null
    out="${1:-build/ios-sim/shot.png}"
    # simctl rejects relative paths — resolve to absolute before calling.
    case "$out" in /*) : ;; *) out="$PWD/$out" ;; esac
    mkdir -p "$(dirname "$out")"
    xcrun simctl io booted screenshot "$out"
    echo "✓ Screenshot → $out"
    ;;
  pbcopy)
    ensure_booted >/dev/null
    text="${1:-}"
    [ -n "$text" ] || { echo "✗ pbcopy needs a string argument"; exit 1; }
    echo -n "$text" | xcrun simctl pbcopy booted
    echo "✓ Pushed to simulator clipboard: $text"
    ;;
  uninstall)
    ensure_booted >/dev/null
    xcrun simctl uninstall booted "$BUNDLE_ID" || true
    echo "✓ Uninstalled $BUNDLE_ID"
    ;;
  reset)
    id="$(booted_id)"
    if [ -n "$id" ]; then
      xcrun simctl shutdown "$id" || true
      xcrun simctl erase "$id"
      echo "✓ Reset $id"
    else
      echo "(no booted sim to reset)"
    fi
    ;;
  *)
    echo "Usage: $0 {boot|install|launch|run|shot [path]|pbcopy TEXT|uninstall|reset}"
    echo ""
    echo "  COPIED_SIM_NAME       simulator name to boot (default: iPhone 17 Pro)"
    echo "  COPIED_IOS_APP_PATH   path to .app to install (default: build/ios-sim/Copied.app)"
    exit 1
    ;;
esac
