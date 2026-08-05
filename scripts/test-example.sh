#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$root/Example/App/CounterFeature.swift"
log_file="${TMPDIR:-/tmp}/hot-reload-kit-example.log"
derived_data="${TMPDIR:-/tmp}/HotReloadKitExampleSmoke"
xcodegen_bin="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$xcodegen_bin" && -x /opt/homebrew/bin/xcodegen ]]; then
  xcodegen_bin=/opt/homebrew/bin/xcodegen
fi
if [[ -z "$xcodegen_bin" ]]; then
  echo "xcodegen is required (or set XCODEGEN_BIN)" >&2
  exit 1
fi
backup="$(mktemp)"
cp "$source_file" "$backup"
rm -rf "$derived_data"

daemon_pid=""
cleanup() {
  if [[ -n "$daemon_pid" ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  cp "$backup" "$source_file"
  rm -f "$backup"
}
trap cleanup EXIT

wait_for_log() {
  local text="$1"
  local attempts=0
  until grep -Fq "$text" "$log_file"; do
    if [[ -n "$daemon_pid" ]] && ! kill -0 "$daemon_pid" 2>/dev/null; then
      cat "$log_file"
      return 1
    fi
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 3000 ]]; then
      cat "$log_file"
      echo "Timed out waiting for: $text" >&2
      return 1
    fi
    sleep 0.1
  done
}

cd "$root/Example"
"$xcodegen_bin" generate >/dev/null
cd "$root"

device_id="$(xcrun simctl list devices available -j | jq -r '
  [.devices | to_entries[] | select(.key | contains("iOS")) | .value[]][0].udid
')"
if [[ -z "$device_id" || "$device_id" == "null" ]]; then
  echo "No available iOS Simulator" >&2
  exit 1
fi
xcrun simctl boot "$device_id" 2>/dev/null || true
xcrun simctl bootstatus "$device_id" -b >/dev/null

stdbuf -oL swift run hotreload \
  --project Example/HotReloadExample.xcodeproj \
  --scheme HotReloadExample \
  --source Example/App/CounterFeature.swift \
  --simulator "$device_id" \
  --derived-data "$derived_data" \
  >"$log_file" 2>&1 &
daemon_pid=$!

wait_for_log "[hotreload] watching"
perl -0pi -e 's/state\.count \+= 1/state.count += 2/' "$source_file"
wait_for_log "generation 1 visible"

printf '\n// Structural rebuild smoke marker.\n' >>"$source_file"
wait_for_log "rebuilt and relaunched"
: >"$log_file"
perl -0pi -e 's/state\.count \+= 2/state.count += 3/' "$source_file"
wait_for_log "generation 1 visible"

receipt="$(find "$derived_data" -path '*/HotReloadSession-*/receipt.json' -print -quit)"
jq -e '.generation == 1 and .error == null' "$receipt" >/dev/null
echo "HotReloadKit example smoke test passed"
