# HotReloadKit

HotReloadKit hot-reloads safe Swift `body` edits in a running iOS Simulator. It uses the Swift runtime's native `@_dynamicReplacement` mechanism—the same underlying facility used by Xcode Previews—rather than symbol interposition or runtime metadata mutation.

Edit a SwiftUI `View.body` and keep `@State`, navigation state, and models alive. Edit a Composable Architecture `Reducer.body` (`Reduce { ... }`) and keep the running `Store` alive. If an edit fails to compile, the running app stays untouched. If an edit changes stored properties, helper functions, or type structure, HotReloadKit automatically falls back to a standard `xcodebuild`, install, and relaunch. Release builds and physical-device builds are completely inert.

## How it works

1. **Baseline build:** `hotreload` builds and launches your app in the iOS Simulator with `-enable-implicit-dynamic`, `-enable-private-imports`, and `-export_dynamic`, passing a per-session manifest and receipt path via `simctl launch` environment variables.
2. **AST diffing (`HotReloadCore`):** On every save of the watched source file, `ReplacementPlanner` parses the baseline and edited source with `SwiftSyntax`. It verifies that the edit is strictly confined to the file's single top-level computed `body` (and, for non-`View` opaque bodies such as TCA reducers, confined to `Reduce { ... }` closure bodies).
3. **Thunk compilation:** Safe edits emit a small replacement source file using `@_private(sourceFile:)` and `@_dynamicReplacement(for: body)`:
   ```swift
   @_private(sourceFile: "ContentView.swift") import ExampleApp
   import SwiftUI

   extension ContentView {
     @_dynamicReplacement(for: body)
     var __hotReload_body_1: some View {
       // edited implementation
     }
   }
   ```
4. **Bundle linking:** The thunk is compiled to an object file with `swiftc -emit-object` and linked as a Mach-O bundle (`clang -bundle -bundle_loader <AppExecutable>`), resolving symbols directly against the baseline app binary without flat-namespace or undefined-symbol linker hacks.
5. **Runtime loading (`HotReloadRuntime`):** The in-app Debug runtime polls the session manifest on the shared simulator filesystem, loads the new bundle with `dlopen(..., RTLD_NOW | RTLD_LOCAL)`, invalidates the `@HotReloadable` observer for that declaration, and writes an atomic receipt back to the CLI.

See [`docs/architecture.md`](docs/architecture.md) for more detail.

## Requirements

- macOS 15+ on Apple silicon
- Xcode 26.6+ (Swift 6.3) or Xcode 27.0+ (Swift 6.4)
- iOS 18.0+ Simulator deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46+ (optional; required only for the `--xcodegen` flag and the included `Example` project)

## Installation

### 1. Build and install the `hotreload` CLI

```bash
git clone https://github.com/kitlangton/HotReloadKit.git
cd HotReloadKit
swift build -c release --product hotreload
install .build/release/hotreload ~/.local/bin/hotreload
```

### 2. Add `HotReloadUI` to your app via SwiftPM

In `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/kitlangton/HotReloadKit.git", from: "0.1.0"),
]
```

And add the `HotReloadUI` product to your application target:

```swift
.product(name: "HotReloadUI", package: "HotReloadKit")
```

Or in Xcode: **File → Add Package Dependencies…**, enter `https://github.com/kitlangton/HotReloadKit.git`, and link `HotReloadUI` to your app target.

## Project setup

### Application code

Start the runtime once at your app's root, and annotate SwiftUI views you want to redraw on reload with `@HotReloadable`:

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

@HotReloadable
struct RootView: View {
  @State private var count = 0

  var body: some View {
    Button("Count: \(count)") {
      count += 1
    }
  }
}
```

`@HotReloadable` expands to a declaration-keyed `@ObservedObject` property inside `#if DEBUG` and expands to nothing in Release builds. Composable Architecture `@Reducer` types do not need `@HotReloadable` because the `Store` invokes the replaced `body` on its next action.

If you keep `HotReloadKit` in an optional local overlay rather than your main project graph, guard the import and macro with `#if DEBUG && canImport(HotReloadUI)`:

```swift
#if DEBUG && canImport(HotReloadUI)
import HotReloadUI
#endif

#if DEBUG && canImport(HotReloadUI)
@HotReloadable
#endif
struct RootView: View {
  ...
}
```

### Plain Xcode project setup

For small projects, no manual build-setting changes are required: `hotreload` automatically passes the required Debug compiler and linker overrides to `xcodebuild`.

For projects with large SwiftPM dependency graphs, command-line `xcodebuild` overrides force SwiftPM package targets to recompile with those flags. Instead, configure these settings on your **application target only** (under **Build Settings → Debug**) and pass `--use-project-build-settings` to `hotreload`:

```text
ENABLE_DEBUG_DYLIB = NO
SWIFT_ENABLE_OPAQUE_TYPE_ERASURE = YES
OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports
OTHER_LDFLAGS = $(inherited) -Xlinker -export_dynamic
```

### XcodeGen setup

In `project.yml`, add the package and scope the hot-reload flags to `Debug`:

```yaml
packages:
  HotReloadKit:
    url: https://github.com/kitlangton/HotReloadKit.git
    from: 0.1.0

targets:
  MyApp:
    type: application
    platform: iOS
    dependencies:
      - package: HotReloadKit
        product: HotReloadUI
    settings:
      configs:
        Debug:
          ENABLE_DEBUG_DYLIB: false
          SWIFT_ENABLE_OPAQUE_TYPE_ERASURE: true
          OTHER_SWIFT_FLAGS: "$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports"
          OTHER_LDFLAGS: "$(inherited) -Xlinker -export_dynamic"
```

## Usage

Boot an iOS Simulator (or pass `--simulator <UDID>`), then point `hotreload` at your project, scheme, and the Swift file you are iterating on:

```bash
hotreload \
  --project MyApp.xcodeproj \
  --scheme MyApp \
  --source MyApp/RootView.swift \
  --use-project-build-settings
```

### CLI options

| Option | Description |
| --- | --- |
| `--project <path>` | Path to the `.xcodeproj` (required). |
| `--scheme <name>` | Xcode scheme and application target to build (required). |
| `--source <path>` | Swift source file containing one reloadable computed `body` (required). |
| `--simulator <udid>` | Simulator UDID. Defaults to a currently booted iOS Simulator. |
| `--derived-data <path>` | DerivedData directory. Defaults to `<user-temp>/HotReloadKitDerivedData`. |
| `--xcodegen` | Run `xcodegen generate` before the initial build and any structural rebuild. |
| `--use-project-build-settings` | Rely on the app target's own Debug build settings instead of passing command-line overrides to `xcodebuild`. |

### Running the included example

Generate and run the included SwiftUI + TCA example:

```bash
cd Example
xcodegen generate
cd ..

# Watch the SwiftUI view (edit Example/App/ContentView.swift):
swift run hotreload \
  --project Example/HotReloadExample.xcodeproj \
  --scheme HotReloadExample \
  --source Example/App/ContentView.swift \
  --xcodegen

# Or watch the TCA reducer (edit Example/App/CounterFeature.swift):
swift run hotreload \
  --project Example/HotReloadExample.xcodeproj \
  --scheme HotReloadExample \
  --source Example/App/CounterFeature.swift \
  --xcodegen
```

To run the automated end-to-end smoke test (which verifies SwiftUI `View.body` reload, TCA `Reducer.body` reload, and structural fallback rebuilds):

```bash
./scripts/test-example.sh
```

## What reloads vs. what rebuilds

| Edit in watched file | Behavior | State preserved? |
| --- | --- | --- |
| SwiftUI `View.body` content, subviews, modifiers, `@ViewBuilder` branches (`if`/`else`, `switch`, `ForEach`), closures | **Hot reloads in place** (~100–300 ms) | Yes (`@State`, `@StateObject`, `@Observable` models, navigation) |
| TCA `Reducer.body` statements inside `Reduce { state, action in ... }` | **Hot reloads in place** (~100–300 ms) | Yes (`Store` state and in-flight effects) |
| Syntax error or type/compiler error inside `body` | **Rejected without publishing** | Yes (running app stays on last good generation) |
| Changing TCA `@ReducerBuilder` composition outside `Reduce { ... }` (e.g., adding `Scope`, `.ifLet`, `.forEach`, `.onChange`) | **Automatic `xcodebuild` + relaunch** | No (clean relaunch) |
| Adding/changing stored properties (`@State`, `let`, `var`), helper methods, types, extensions, imports, or `#if` blocks | **Automatic `xcodebuild` + relaunch** | No (clean relaunch) |
| Adding a second `body` declaration to the watched file | **Automatic `xcodebuild` + relaunch** | No (clean relaunch) |

### Why SwiftUI `View.body` and TCA `Reducer.body` differ on structural builder changes

In the iOS SDK, `SwiftUI.View` is annotated with `@_typeEraser(DebugReplaceableView)`. When compiled with `-Xfrontend -enable-implicit-dynamic`, Swift erases `var body: some View` to `DebugReplaceableView`, so adding or rearranging subviews and `@ViewBuilder` branches inside `View.body` keeps the exact same runtime return type.

Composable Architecture's `Reducer` protocol does not use `@_typeEraser`, so the Swift runtime caches the concrete associated `Body` type metadata for `var body: some ReducerOf<Self>` on first execution. Edits inside `Reduce { state, action in ... }` keep the concrete `Reduce<State, Action>` return type unchanged and hot-reload safely. Edits that alter the outer `@ReducerBuilder` type (such as adding `Scope` or `.onChange`) change the underlying opaque return type, so `ReplacementPlanner` automatically routes them to a full rebuild rather than risking a witness-table mismatch.

## How HotReloadKit compares to InjectionIII / InjectionNext

| Dimension | HotReloadKit | InjectionIII / InjectionNext |
| --- | --- | --- |
| **Replacement mechanism** | Swift compiler's native `@_dynamicReplacement(for: body)` + Mach-O `-bundle_loader` | `fishhook` symbol rebinding, direct Swift vtable/metadata patching, and live-object sweeping |
| **Edit scope** | One watched file's top-level `struct` `body` per session | Arbitrary methods, functions, classes, structs, and multiple files |
| **Incompatible / structural edits** | Detected ahead of time with `SwiftSyntax`; automatically falls back to `xcodebuild` + relaunch | Attempts in-place injection; adding stored properties or changing vtable/generic layout can crash the process |
| **SwiftUI invalidation** | Targeted `@HotReloadable` macro (`#if DEBUG` only, keyed by declaration name) | Global `@ObserveInjection` + `-interposable` linker flags |
| **Build & transport** | Single CLI (`hotreload`) owns `xcodebuild`, `swiftc`, and simulator file manifest (no network sockets) | Helper macOS app or daemon watching `xcactivitylog` / build logs and communicating over localhost TCP socket |

Use **InjectionIII / InjectionNext** if you want broad, opportunistic method swizzling across many files and classes at once. Use **HotReloadKit** if you want a deterministic, crash-free loop for SwiftUI views and TCA reducers that either hot-reloads safely via the compiler's own dynamic-replacement machinery or cleanly rebuilds.

## Limitations

- **One file, one `body` per session:** `ReplacementPlanner` only emits a dynamic replacement when the watched file has exactly one reloadable computed `body` on a top-level `struct`. Files containing multiple `View` or `Reducer` declarations fall back to full rebuilds; extract the view or reducer you are actively iterating on into its own file for the fast path.
- **iOS Simulator only:** Physical iOS devices do not share the host filesystem or permit arbitrary unsigned `dlopen` bundles; the runtime is compiled out on device targets.
- **Resident replacement images:** The Swift runtime does not support unloading images (`dlclose`) that register Swift metadata or dynamic replacements. Each reload keeps its tiny Mach-O bundle resident in memory, and `hotreload` automatically performs a clean rebuild every 50 generations to reclaim them.
- **Underscored Swift features:** Dynamic replacement relies on `-Xfrontend -enable-implicit-dynamic`, `-Xfrontend -enable-private-imports`, `@_private(sourceFile:)`, and `@_dynamicReplacement(for:)`. These are the same compiler flags used by Xcode Previews, but they are underscored compiler features that may evolve across future Swift releases.

## Troubleshooting

- **CLI prints `generation N visible`, but the SwiftUI view does not update:**
  1. Ensure the edited view struct is annotated with `@HotReloadable`.
  2. Ensure `HotReloadRuntime.start()` is called once at launch (for example, in `.task { HotReloadRuntime.start() }` on your root view).
- **`Timed out waiting for generation N to load`:**
  - Verify that `HotReloadRuntime.start()` is executed when the app launches and that the app process is not paused at a debugger breakpoint or terminated in the Simulator.
- **Every save triggers `rebuilding: ...`:**
  - Check the printed reason. The watched file must contain exactly one top-level `struct` with one computed `body`, must not contain `#if` conditional compilation blocks, and your edit must stay inside `body` (or inside `Reduce { ... }` for a TCA reducer).
- **Baseline build recompiles all SwiftPM packages:**
  - Add the Debug build settings (`ENABLE_DEBUG_DYLIB=NO`, `SWIFT_ENABLE_OPAQUE_TYPE_ERASURE=YES`, `OTHER_SWIFT_FLAGS`, `OTHER_LDFLAGS`) directly to your application target's Debug configuration and pass `--use-project-build-settings`.

## License

MIT License. Copyright (c) 2026 Kit Langton. See [`LICENSE`](LICENSE).
