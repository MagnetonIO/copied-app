#!/bin/zsh
# scripts/perf-trace.sh — Standard performance scenarios for Copied.
#
# See docs/perf/profiling.md for the full playbook.
#
# Usage:
#   scripts/perf-trace.sh cold-start          Launch + 30s allocations trace
#   scripts/perf-trace.sh capture-loop        200 pbcopy events, RSS curve
#   scripts/perf-trace.sh popover-reopen      Time Profiler over Enter/reopen
#   scripts/perf-trace.sh image-browse        Allocations under thumbnail load
#   scripts/perf-trace.sh heap-diff           Heap snapshot before/after 50 captures
#   scripts/perf-trace.sh leaks               Live leaks against running process
#
# Output: build/traces/<scenario>-<timestamp>.{trace,txt}
# Open .trace files in Instruments.app to inspect.

set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/traces

scenario="${1:-}"
ts=$(date +%Y%m%d-%H%M%S)
APP="${COPIED_APP:-$HOME/Applications/Copied-Debug.app}"

if [[ ! -d "$APP" ]]; then
  echo "App not found at $APP — set COPIED_APP env var or install Debug build first." >&2
  exit 1
fi

find_pid() {
  pgrep -fn "${APP}/Contents/MacOS/Copied" || true
}

case "$scenario" in
  cold-start)
    out="build/traces/cold-start-${ts}.trace"
    echo "▶ Killing existing Copied, recording 30s Allocations on cold launch"
    pkill -f "${APP}/Contents/MacOS/Copied" 2>/dev/null || true
    sleep 1
    xcrun xctrace record \
      --template "Allocations" \
      --output "$out" \
      --launch "$APP" \
      --time-limit 30s
    echo "✓ $out"
    ;;

  capture-loop)
    out="build/traces/capture-loop-${ts}.txt"
    echo "▶ Sampling RSS while triggering 200 pbcopy events"
    PID=$(find_pid)
    if [[ -z "$PID" ]]; then
      echo "Copied not running — launch it first." >&2
      exit 1
    fi
    {
      echo "scenario=capture-loop pid=$PID started=$(date)"
      echo "i\trss_kb"
      for i in {1..200}; do
        echo "test-${ts}-${i}-$RANDOM" | pbcopy
        rss=$(ps -o rss= -p "$PID" | tr -d ' ')
        echo "${i}\t${rss}"
        sleep 0.5
      done
      echo "# wait 30s for sync to drain..."
      sleep 30
      rss_final=$(ps -o rss= -p "$PID" | tr -d ' ')
      echo "final\t${rss_final}"
    } | tee "$out"
    echo "✓ $out"
    ;;

  popover-reopen)
    out="build/traces/popover-reopen-${ts}.trace"
    echo "▶ Recording 30s Time Profiler — open popover, press Enter, reopen quickly"
    PID=$(find_pid)
    if [[ -z "$PID" ]]; then
      echo "Copied not running — launch it first." >&2
      exit 1
    fi
    xcrun xctrace record \
      --template "Time Profiler" \
      --output "$out" \
      --attach "$PID" \
      --time-limit 30s
    echo "✓ $out — open in Instruments and look for finalizeCapture / refreshFreshClippings signposts"
    ;;

  image-browse)
    out="build/traces/image-browse-${ts}.trace"
    echo "▶ Recording 30s Allocations — scroll image-heavy popover"
    PID=$(find_pid)
    if [[ -z "$PID" ]]; then
      echo "Copied not running — launch it first." >&2
      exit 1
    fi
    xcrun xctrace record \
      --template "Allocations" \
      --output "$out" \
      --attach "$PID" \
      --time-limit 30s
    echo "✓ $out"
    ;;

  heap-diff)
    PID=$(find_pid)
    if [[ -z "$PID" ]]; then
      echo "Copied not running — launch it first." >&2
      exit 1
    fi
    before="build/traces/heap-before-${ts}.txt"
    after="build/traces/heap-after-${ts}.txt"
    diff_out="build/traces/heap-diff-${ts}.txt"
    echo "▶ Heap snapshot before"
    heap "$PID" > "$before" 2>&1 || true
    echo "▶ Triggering 50 pbcopy events"
    for i in {1..50}; do
      echo "diff-test-${ts}-${i}" | pbcopy
      sleep 0.4
    done
    sleep 5
    echo "▶ Heap snapshot after"
    heap "$PID" > "$after" 2>&1 || true
    diff "$before" "$after" > "$diff_out" || true
    echo "✓ $before"
    echo "✓ $after"
    echo "✓ $diff_out — grep for class names with growth ≈ 50"
    ;;

  leaks)
    PID=$(find_pid)
    if [[ -z "$PID" ]]; then
      echo "Copied not running — launch it first." >&2
      exit 1
    fi
    out="build/traces/leaks-${ts}.txt"
    echo "▶ Running leaks (may take a minute)"
    leaks "$PID" --groupByType > "$out" 2>&1 || true
    echo "✓ $out"
    ;;

  *)
    sed -n '2,16p' "$0"
    exit 2
    ;;
esac
