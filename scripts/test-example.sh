#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
view_file="$root/Example/App/ContentView.swift"
reducer_file="$root/Example/App/CounterFeature.swift"
uikit_file="$root/Example/App/UIKitPreviewViewController.swift"
log_file="${TMPDIR:-/tmp}/hot-reload-kit-example.log"
derived_data="${HOTRELOAD_DERIVED_DATA:-${TMPDIR:-/tmp}/HotReloadKitExampleSmoke}"
xcodegen_bin="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$xcodegen_bin" && -x /opt/homebrew/bin/xcodegen ]]; then
  xcodegen_bin=/opt/homebrew/bin/xcodegen
fi
if [[ -z "$xcodegen_bin" ]]; then
  echo "xcodegen is required (or set XCODEGEN_BIN)" >&2
  exit 1
fi
view_backup="$(mktemp)"
reducer_backup="$(mktemp)"
uikit_backup="$(mktemp)"
cp "$view_file" "$view_backup"
cp "$reducer_file" "$reducer_backup"
cp "$uikit_file" "$uikit_backup"
rm -rf "$derived_data"

daemon_pid=""
stop_daemon() {
  if [[ -n "$daemon_pid" ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=""
  fi
}

cleanup() {
  stop_daemon
  cp "$view_backup" "$view_file"
  cp "$reducer_backup" "$reducer_file"
  cp "$uikit_backup" "$uikit_file"
  rm -f "$view_backup" "$reducer_backup" "$uikit_backup"
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

device_id="${SIM_UDID:-${HOTRELOAD_SIMULATOR:-}}"
if [[ -z "$device_id" ]]; then
  device_id="$(xcrun simctl list devices booted -j | jq -r '
    [.devices | to_entries | sort_by(.key) | reverse[] | select(.key | contains("iOS")) | .value[] | select(.state == "Booted")][0].udid // empty
  ')"
fi
if [[ -z "$device_id" ]]; then
  device_id="$(xcrun simctl list devices available -j | jq -r '
    [.devices | to_entries | sort_by(.key) | reverse[] | select(.key | contains("iOS")) | .value[]][0].udid // empty
  ')"
fi
if [[ -z "$device_id" || "$device_id" == "null" ]]; then
  echo "No available iOS Simulator" >&2
  exit 1
fi
xcrun simctl boot "$device_id" 2>/dev/null || true
xcrun simctl bootstatus "$device_id" -b >/dev/null

swift build --product hotreload
hotreload_bin="$root/.build/debug/hotreload"

: >"$log_file"
"$hotreload_bin" \
  --project Example/HotReloadExample.xcodeproj \
  --scheme HotReloadExample \
  --watch Example/App \
  --simulator "$device_id" \
  --derived-data "$derived_data" \
  --use-project-build-settings \
  >"$log_file" 2>&1 &
daemon_pid=$!

wait_for_log "[hotreload] watching"
perl -0pi -e 's/Text\("SwiftUI and TCA"\)/Text("Hot Reloaded SwiftUI")/' "$view_file"
wait_for_log "generation 1 visible"

perl -0pi -e 's/state\.count \+= 1/state.count += 2/' "$reducer_file"
wait_for_log "generation 2 visible"

perl -0pi -e 's/UIKit Hook Active/UIKit Hook Reloaded/' "$uikit_file"
wait_for_log "generation 3 visible"

printf '\n// Structural rebuild smoke marker.\n' >>"$reducer_file"
wait_for_log "rebuilt and relaunched"
: >"$log_file"
perl -0pi -e 's/state\.count \+= 2/state.count += 3/' "$reducer_file"
wait_for_log "generation 1 visible"

receipt="$(find "$derived_data" -path '*/HotReloadSession-*/receipt.json' -print -quit)"
jq -e '.generation == 1 and .error == null' "$receipt" >/dev/null
echo "HotReloadKit example smoke test passed"
