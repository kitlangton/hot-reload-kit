# HotReloadKit

HotReloadKit replaces safe Swift declaration-body edits in a running iOS Simulator. It uses the Swift runtime's dynamic replacement mechanism, the same underlying facility used by Xcode Previews, rather than rebinding symbols or mutating Swift metadata.

The current release targets Xcode 26.6, Swift 6.3, iOS 18+, and Apple silicon simulators.

Prerequisites: macOS with Xcode 26.6, Swift 6.3, a booted iOS Simulator, and XcodeGen for the included example. The smoke test also uses `jq`, Perl, and `stdbuf`.

## What works

- SwiftUI `View.body` edits while preserving `@State` and application models.
- Composable Architecture `Reducer.body` edits while preserving the existing `Store`.
- Compile failures leave the running application untouched.
- Stored-property and other structural edits automatically perform a normal build, install, and relaunch.
- Release builds contain no observer property and the runtime is inert.

## Example

Generate the included SwiftUI and TCA example:

```bash
cd Example
xcodegen generate
cd ..
```

Boot an iOS Simulator, then watch the SwiftUI view:

```bash
swift run hotreload \
  --project Example/HotReloadExample.xcodeproj \
  --scheme HotReloadExample \
  --source Example/App/ContentView.swift \
  --xcodegen
```

Edit the contents of `ContentView.body`. The updated body appears without relaunching and the counter remains unchanged.

To reload TCA reducer logic instead:

```bash
swift run hotreload \
  --project Example/HotReloadExample.xcodeproj \
  --scheme HotReloadExample \
  --source Example/App/CounterFeature.swift \
  --xcodegen
```

Change `state.count += 1` to `state.count += 2`. The next action uses the replacement reducer while the current count remains alive.

Run the automated simulator smoke test with:

```bash
./scripts/test-example.sh
```

## Project integration

Build and install the CLI somewhere on `PATH`:

```bash
swift build -c release --product hotreload
install .build/release/hotreload ~/.local/bin/hotreload
```

Add the package's `HotReloadUI` product to the application target. Start the runtime once from the application root:

```swift
import HotReloadUI
import SwiftUI

@main
struct ExampleApp: App {
  var body: some Scene {
    WindowGroup {
      RootView()
        .task { HotReloadRuntime.start() }
    }
  }
}
```

Annotate SwiftUI views that should redraw after their `body` is replaced:

```swift
@HotReloadable
struct RootView: View {
  var body: some View {
    Text("Edit me")
  }
}
```

The macro adds a declaration-keyed observer only under `#if DEBUG`. TCA reducers do not need the annotation because the store naturally invokes the replaced reducer on its next action.

The `hotreload` command owns the baseline build and supplies these Debug overrides automatically:

```text
-Xfrontend -enable-implicit-dynamic
-Xfrontend -enable-private-imports
SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES
ENABLE_DEBUG_DYLIB=NO
-Xlinker -export_dynamic
```

If the application target already defines all of these settings, pass
`--use-project-build-settings` to avoid applying command-line overrides to every
Swift package target. This keeps the baseline build incremental in projects
with substantial package dependency graphs.

Use `hotreload --help` for all options, including an explicit simulator UDID and DerivedData directory.

## Safety model

HotReloadKit parses the last successfully built source and each edit with SwiftSyntax. It emits a dynamic replacement only when the edit is confined to the single computed `body` in the watched file. Every other source change triggers the fallback build.

Generated replacements use a source-scoped private import:

```swift
@_private(sourceFile: "ContentView.swift") import ExampleApp

extension ContentView {
  @_dynamicReplacement(for: body)
  var __hotReload_body_1: some View {
    // edited implementation
  }
}
```

The thunk is compiled to an object and linked as a Mach-O bundle with `-bundle_loader` against the baseline executable. This avoids deprecated flat-namespace and undefined-symbol linker modes. The simulator runtime loads the finished bundle with `dlopen` and invalidates only the affected annotated view.

## Current limits

- One watched source file and one computed `body` per session.
- iOS Simulator only; physical devices are intentionally unsupported.
- The watched declaration must already exist in the baseline build.
- Adding declarations, stored properties, conformances, or files requires rebuilding.
- Build-setting, dependency, and macro-shape changes require rebuilding.
- Loaded Swift bundles remain resident until relaunch; the CLI periodically rebuilds to reclaim them.
- Dynamic replacement and private imports are underscored Swift features and may require adaptation for future toolchains.

See [`docs/architecture.md`](docs/architecture.md) for the implementation design.
