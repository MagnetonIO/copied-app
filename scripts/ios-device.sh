#!/bin/zsh
# Copied iOS physical-device harness.
#
# Parallel to scripts/ios-sim.sh, but targets a paired iPhone/iPad over
# Xcode's CoreDevice pipeline (`xcrun devicectl`). `-allowProvisioningUpdates`
# delegates device registration + profile generation to Xcode, so there
# is no manual provisioning profile to build.
#
# Prereqs (one-time):
#   - iPhone plugged in (USB or wireless pair), unlocked, "Trust this Mac"
#   - iPhone Settings → Privacy & Security → Developer Mode → On (+ reboot)
#   - Xcode → Settings → Accounts: the paid Apple Developer team 7727LYTG96
#     is signed in
#
# Usage:
#   ./scripts/ios-device.sh list                 # list paired devices
#   ./scripts/ios-device.sh id                   # echo first connected UDID
#   ./scripts/ios-device.sh build                # xcodebuild, signed, DDI-compatible
#   ./scripts/ios-device.sh install              # install built .app on device
#   ./scripts/ios-device.sh launch               # launch com.mlong.copied
#   ./scripts/ios-device.sh run                  # build + install + launch
#   ./scripts/ios-device.sh logs                 # tail device log for Copied
#   ./scripts/ios-device.sh uninstall            # remove app from device
#
# Override the target device: `COPIED_DEVICE_ID=<UDID> ./scripts/ios-device.sh …`

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.mlong.copied"
SCHEME="CopiedIOS"
CONFIG="Debug"
DERIVED="build/ios-device"
APP_PATH="${DERIVED}/Build/Products/${CONFIG}-iphoneos/Copied.app"

# Pick the first device in the connected state that's NOT a simulator.
# `devicectl list devices` prefixes output with a harmless "No provider
# was found" warning — we skip that and parse the table.
device_id() {
  if [ -n "${COPIED_DEVICE_ID:-}" ]; then
    echo "$COPIED_DEVICE_ID"
    return
  fi
  xcrun devicectl list devices 2>/dev/null | awk '
    /^-+/ { in_table=1; next }
    in_table && /connected/ {
      # Identifier column is the 3rd-to-last whitespace field ahead of State+Model.
      # Line format: Name  Hostname  Identifier  State  Model
      # Columns vary in width, so grab the UDID-looking token (36-char UUID).
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) {
          print $i
          exit
        }
      }
    }
  '
}

require_device() {
  local id
  id="$(device_id)"
  if [ -z "$id" ]; then
    echo "✘ No connected iOS device found." >&2
    echo "  Make sure the phone is plugged in, unlocked, trusts the Mac," >&2
    echo "  and has Developer Mode enabled (Settings → Privacy & Security)." >&2
    exit 1
  fi
  echo "$id"
}

cmd="${1:-run}"
shift || true

case "$cmd" in
  list)
    xcrun devicectl list devices
    ;;

  id)
    require_device
    ;;

  build)
    DEV_ID="$(require_device)"
    echo "→ Building ${SCHEME} for device ${DEV_ID}…"
    xcodebuild \
      -project Copied.xcodeproj \
      -scheme "${SCHEME}" \
      -configuration "${CONFIG}" \
      -destination "platform=iOS,id=${DEV_ID}" \
      -derivedDataPath "${DERIVED}" \
      -allowProvisioningUpdates \
      build
    ;;

  install)
    DEV_ID="$(require_device)"
    if [ ! -d "${APP_PATH}" ]; then
      echo "✘ ${APP_PATH} not found — run './scripts/ios-device.sh build' first." >&2
      exit 1
    fi
    echo "→ Installing ${APP_PATH} on ${DEV_ID}…"
    xcrun devicectl device install app --device "${DEV_ID}" "${APP_PATH}"
    ;;

  launch)
    DEV_ID="$(require_device)"
    echo "→ Launching ${BUNDLE_ID} on ${DEV_ID}…"
    xcrun devicectl device process launch --device "${DEV_ID}" "${BUNDLE_ID}"
    ;;

  run)
    "$0" build
    "$0" install
    "$0" launch
    ;;

  uninstall)
    DEV_ID="$(require_device)"
    echo "→ Uninstalling ${BUNDLE_ID} from ${DEV_ID}…"
    xcrun devicectl device uninstall app --device "${DEV_ID}" --bundle-identifier "${BUNDLE_ID}"
    ;;

  logs)
    DEV_ID="$(require_device)"
    echo "→ Streaming logs for ${BUNDLE_ID} on ${DEV_ID} (⌃C to stop)…"
    # macOS' `log stream` talks to a paired device over CoreDevice — no
    # third-party tooling required.
    log stream \
      --device "${DEV_ID}" \
      --style compact \
      --predicate "process CONTAINS[c] \"Copied\" OR subsystem CONTAINS \"${BUNDLE_ID}\""
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Usage: $0 {list|id|build|install|launch|run|uninstall|logs}" >&2
    exit 2
    ;;
esac
