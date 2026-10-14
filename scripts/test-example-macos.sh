#!/usr/bin/env bash
# Smoke test for --platform macos: builds Example/Mac, launches it on this Mac,
# hot-reloads a SwiftUI body, a computed helper property, and an AppKit (NSView)
# method, checks the running app drew each edit, then checks a structural edit
# rebuilds and relaunches.
#
# HOTRELOAD_XCODEBUILD names a wrapper for the baseline builds (default xcodebuild);
# HOTRELOAD_BIN uses a prebuilt hotreload instead of building it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
view_file="$root/Example/Mac/App/ContentView.swift"
badge_file="$root/Example/Mac/App/BadgeView.swift"
log_file="${TMPDIR:-/tmp}/hot-reload-kit-macos-example.log"
derived_data="${HOTRELOAD_DERIVED_DATA:-${TMPDIR:-/tmp}/HotReloadKitMacExampleSmoke}"
probe_dir="$(mktemp -d)"
xcodebuild_bin="${HOTRELOAD_XCODEBUILD:-xcodebuild}"
xcodegen_bin="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
if [[ -z "$xcodegen_bin" && -x /opt/homebrew/bin/xcodegen ]]; then
  xcodegen_bin=/opt/homebrew/bin/xcodegen
fi
if [[ -z "$xcodegen_bin" ]]; then
  echo "xcodegen is required (or set XCODEGEN_BIN)" >&2
  exit 1
fi
view_backup="$(mktemp)"
badge_backup="$(mktemp)"
cp "$view_file" "$view_backup"
cp "$badge_file" "$badge_backup"

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
  cp "$badge_backup" "$badge_file"
  rm -f "$view_backup" "$badge_backup"
  rm -rf "$probe_dir"
}
trap cleanup EXIT

wait_for() {
  local description="$1"
  shift
  local attempts=0
  until "$@"; do
    if [[ -n "$daemon_pid" ]] && ! kill -0 "$daemon_pid" 2>/dev/null; then
      cat "$log_file"
      echo "hotreload exited while waiting for: $description" >&2
      return 1
    fi
    attempts=$((attempts + 1))
    if [[ "$attempts" -gt 3000 ]]; then
      cat "$log_file"
      echo "Timed out waiting for: $description" >&2
      return 1
    fi
    sleep 0.1
  done
}
log_has() { grep -Fq "$1" "$log_file"; }
probe_is() { [[ -f "$probe_dir/$1.txt" && "$(cat "$probe_dir/$1.txt")" == "$2" ]]; }

cd "$root/Example/Mac"
"$xcodegen_bin" generate >/dev/null
cd "$root"

hotreload_bin="${HOTRELOAD_BIN:-}"
if [[ -z "$hotreload_bin" ]]; then
  swift build --product hotreload
  hotreload_bin="$root/.build/debug/hotreload"
fi

: >"$log_file"
HOTRELOAD_EXAMPLE_PROBE="$probe_dir" "$hotreload_bin" \
  --platform macos \
  --project Example/Mac/HotReloadMacExample.xcodeproj \
  --scheme HotReloadMacExample \
  --watch Example/Mac/App \
  --derived-data "$derived_data" \
  --xcodebuild "$xcodebuild_bin" \
  --use-project-build-settings \
  >"$log_file" 2>&1 &
daemon_pid=$!

wait_for "baseline" log_has "[hotreload] watching"
wait_for "baseline SwiftUI body drawn" probe_is swiftui "SwiftUI Body"
wait_for "baseline AppKit view drawn" probe_is appkit "AppKit Method"
wait_for "baseline helper drawn" probe_is helper "Helper Property"

perl -0pi -e 's/"SwiftUI Body"/"Hot Reloaded SwiftUI"/' "$view_file"
wait_for "generation 1" log_has "generation 1 visible"
wait_for "SwiftUI body redrawn" probe_is swiftui "Hot Reloaded SwiftUI"
echo "SwiftUI body reloaded in the running Mac app"

perl -0pi -e 's/"Helper Property"/"Hot Reloaded Helper"/' "$view_file"
wait_for "generation 2" log_has "generation 2 visible"
wait_for "helper property redrawn" probe_is helper "Hot Reloaded Helper"
echo "SwiftUI helper property reloaded in the running Mac app"

perl -0pi -e 's/"AppKit Method"/"Hot Reloaded AppKit"/' "$badge_file"
wait_for "generation 3" log_has "generation 3 visible"
wait_for "NSView method rerun" probe_is appkit "Hot Reloaded AppKit"
echo "NSView method reloaded in the running Mac app"

perl -0pi -e 's/  private let label = NSTextField\(labelWithString: ""\)/  private let label = NSTextField(labelWithString: "")\n  private var structuralMarker = 0/' "$badge_file"
wait_for "structural rebuild" log_has "rebuilt and relaunched"
: >"$log_file"
perl -0pi -e 's/"Hot Reloaded AppKit"/"Reloaded After Relaunch"/' "$badge_file"
wait_for "generation 1 after relaunch" log_has "generation 1 visible"
wait_for "NSView method rerun after relaunch" probe_is appkit "Reloaded After Relaunch"

receipt="$(find "$derived_data" -path '*/HotReloadSession-*/receipt.json' -print -quit)"
jq -e '.generation == 1 and .error == null' "$receipt" >/dev/null
echo "HotReloadKit macOS example smoke test passed"
