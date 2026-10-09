# HotReloadKit

HotReloadKit hot-reloads safe Swift `body` and class-method edits in a running iOS Simulator. It uses the Swift runtime's native `@_dynamicReplacement` mechanism—the same underlying facility used by Xcode Previews—rather than symbol interposition or runtime metadata mutation.

- **SwiftUI:** Edit `View.body` in single-view or multi-view files while keeping `@State`, navigation state, and models alive.
- **Composable Architecture:** Edit `Reducer.body` (`Reduce { ... }`) while keeping the running `Store` alive.
- **UIKit & mixed apps:** Edit class method bodies (`UIViewController`, `UIView`, cells, layout helpers), refresh live controllers in place via `HotReloadRefreshing` or `HotReloadRuntime.onReload`, rebuild stateless views/controllers with `HotReloadViewControllerHost` / `HotReloadViewHost`, and resize `UIHostingConfiguration` collection view rows in place.
- **Whole-project & remote watching:** Watch a single file (`--source`) or entire source trees (`--watch`), with automatic batching for multi-file `rsync` saves.
- **Deterministic fallback:** Compile errors leave the running app untouched. Structural edits (stored properties, new types, method signature changes) automatically fall back to `xcodebuild`, install, and relaunch. Release and physical-device builds are completely inert.

## Prior art & credit

HotReloadKit builds on ideas pioneered by:

- **[Inject](https://github.com/krzysztofzablocki/Inject)** by Krzysztof Zabłocki (MIT) — inspired HotReloadKit's ergonomics across SwiftUI and UIKit, including declaration-level observation (`@HotReloadable`, mirroring `@ObserveInjection`), `@autoclosure` wrapper hosts (`HotReloadViewControllerHost` and `HotReloadViewHost`), and instance refresh hooks (`HotReloadRefreshing`).
- **[InjectionIII](https://github.com/johnno1962/InjectionIII) & [InjectionNext](https://github.com/johnno1962/InjectionNext)** by John Holdsworth — pioneered live code injection for Objective-C and Swift on Apple platforms.
- **Xcode Previews (`@_dynamicReplacement` & `@_private(sourceFile:)`)** — the compiler-supported dynamic replacement and source-scoped private import mechanisms in the Swift toolchain that make interposition-free replacement possible.

## How it works

1. **Baseline build:** `hotreload` builds and launches your app in the iOS Simulator with `-enable-implicit-dynamic`, `-enable-private-imports`, and `-export_dynamic`, passing a per-session manifest and receipt path via `simctl launch` environment variables.
2. **AST diffing (`HotReloadCore`):** On every save (or settled `rsync` batch), `ReplacementPlanner` parses the baseline and edited source for each changed file with `SwiftSyntax`. It verifies that edits are confined to `struct` computed `body` getters (any number of views/reducers per file) or `class` method bodies with unchanged signatures.
3. **Thunk compilation:** Safe edits emit a replacement source file per changed file containing only the modified declarations:
   ```swift
   @_private(sourceFile: "SessionView.swift") import MyApp
   import SwiftUI

   extension SessionView {
     @_dynamicReplacement(for: body)
     var __hotReload_body_1: some View {
       // edited implementation
     }
   }
   ```
4. **Bundle linking:** Each thunk is compiled to an object file (`swiftc -emit-object`) and linked into a Mach-O bundle (`clang -bundle -bundle_loader <AppExecutable>`), resolving symbols directly against the baseline app binary.
5. **Runtime loading & notification (`HotReloadRuntime`):** The Debug runtime loads the bundle with `dlopen(..., RTLD_NOW | RTLD_LOCAL)`, invalidates `@HotReloadable` observers, invokes `HotReloadRefreshing.hotReloaded()` on live instances, fires `HotReloadRuntime.onReload` / `reloads()` / `didReloadNotification`, and writes an atomic receipt.

See [`docs/architecture.md`](docs/architecture.md) for more detail.

## Requirements

- macOS 15+ on Apple silicon
- Xcode 26.6+ (Swift 6.3) or Xcode 27.0+ (Swift 6.4)
- iOS 18.0+ Simulator deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46+ (optional; required only for `--xcodegen` and the included `Example` project)

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

### SwiftUI & TCA

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

If you keep `HotReloadKit` in an optional local overlay rather than your main project graph, guard the import and macro with `#if DEBUG && canImport(HotReloadUI)`.

### UIKit & mixed SwiftUI/UIKit apps

HotReloadKit provides four composable primitives for UIKit:

#### 1. Instance refresh hook (`HotReloadRefreshing`)

Conform any `UIViewController` or `UIView` to `HotReloadRefreshing`. When a class method body is hot-reloaded, `HotReloadRuntime` automatically calls `hotReloaded()` on all conforming controllers/views in the active window hierarchy (and any instance registered via `observeHotReload()`), preserving existing instance state:

```swift
import HotReloadUI
import UIKit

final class ProfileViewController: UIViewController, HotReloadRefreshing {
  private let titleLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    observeHotReload()
    applyStyling()
  }

  func hotReloaded() {
    applyStyling()
    view.setNeedsLayout()
  }

  private func applyStyling() {
    titleLabel.text = "Edit me live"
    view.backgroundColor = .systemBackground
  }
}
```

#### 2. View & ViewController hosts (`HotReloadViewControllerHost` / `HotReloadViewHost`)

When building view hierarchies inside `viewDidLoad()` or `init(frame:)`, wrap the creation site in `HotReloadViewControllerHost` or `HotReloadViewHost`. Like Inject's hosts, they capture an `@autoclosure`, rebuild the hosted controller or view on each reload, forward navigation/title/status-bar properties, and compile to an inert wrapper in Release:

```swift
let hostedController = HotReloadViewControllerHost(DetailViewController())
let hostedBanner = HotReloadViewHost(BannerView())
```

#### 3. Reload signals (`onReload`, `reloads()`, `didReloadNotification`)

Subscribe directly to reload events from any coordinator or controller:

```swift
// Closure API:
let subscription = HotReloadRuntime.onReload { generation in
  print("Reloaded generation \(generation)")
}

// AsyncSequence API:
for await event in HotReloadRuntime.reloads() {
  print("Reloaded \(event.declarations) at generation \(event.generation)")
}

// NotificationCenter:
NotificationCenter.default.addObserver(
  forName: HotReloadRuntime.didReloadNotification,
  object: nil,
  queue: .main
) { _ in }
```

#### 4. SwiftUI inside UIKit (`UIHostingConfiguration` cells)

When hosting `@HotReloadable` SwiftUI views inside `UICollectionView` cells via `UIHostingConfiguration`, the owning list should reconfigure its visible items and invalidate layout on reload so self-sizing cell heights update immediately:

```swift
// Built-in helper for UICollectionView or UICollectionViewDiffableDataSource:
collectionView.hotReloadReconfiguresVisibleItems(using: dataSource)
```

Or in a custom list controller with its own scroll-anchor compensation, call your reconfigure/reload path inside `HotReloadRuntime.onReload { [weak self] _ in ... }`.

### Build settings (Plain Xcode & XcodeGen)

For small projects, no manual build-setting changes are required: `hotreload` passes the required Debug compiler and linker overrides to `xcodebuild` automatically.

For projects with large SwiftPM dependency graphs, define these settings on your **application target's `Debug` configuration only** and pass `--use-project-build-settings` to `hotreload` so package targets are not recompiled with command-line overrides:

```text
ENABLE_DEBUG_DYLIB = NO
SWIFT_ENABLE_OPAQUE_TYPE_ERASURE = YES
OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports
OTHER_LDFLAGS = $(inherited) -Xlinker -export_dynamic
```

In XcodeGen (`project.yml`):

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

### Watch an entire directory or project

```bash
hotreload \
  --project MyApp.xcodeproj \
  --scheme MyApp \
  --watch MyApp \
  --use-project-build-settings
```

`--watch` is repeatable (`--watch MyApp --watch SharedUI`) and automatically ignores `.git`, `.build`, `.swiftpm`, `DerivedData`, `Pods`, `Carthage`, `SourcePackages`, and `*Tests` directories. When both `--watch` and `--source` are omitted, `hotreload` watches the project directory by default.

### Watch a single file

```bash
hotreload \
  --project MyApp.xcodeproj \
  --scheme MyApp \
  --source MyApp/SessionView.swift \
  --use-project-build-settings
```

### Remote Mac devbox workflow (`rsync` + `--watch`)

When building and running the Simulator on a remote Mac devbox while editing locally:

1. Start `hotreload --watch MyApp ...` on the remote Mac.
2. Sync saves from your local machine with `rsync`:
   ```bash
   fswatch -o MyApp | xargs -n1 -I{} rsync -az --delete \
     --exclude '.git' --exclude 'DerivedData' --exclude '.build' \
     ./ devbox:~/workspace/MyApp/
   ```
3. `hotreload` automatically coalesces multi-file `rsync` bursts into a single batch: if all changed files are body/method-confined, it compiles their thunks and links them into one Mach-O bundle for a single atomic reload; if any file has a structural change, it performs one rebuild for the entire batch.

### CLI options

| Option | Description |
| --- | --- |
| `--project <path>` | Path to the `.xcodeproj` (required). |
| `--scheme <name>` | Xcode scheme and application target to build (required). |
| `--watch <path>` | Directory or Swift file to watch (repeatable). Defaults to the project directory when `--source` is omitted. |
| `--source <path>` | Single Swift source file to watch. |
| `--simulator <udid>` | Simulator UDID. Defaults to a currently booted iOS Simulator. |
| `--derived-data <path>` | DerivedData directory. Defaults to `<user-temp>/HotReloadKitDerivedData`. |
| `--xcodegen` | Run `xcodegen generate` before the initial build and any structural rebuild. |
| `--use-project-build-settings` | Rely on the app target's own Debug build settings instead of passing command-line overrides to `xcodebuild`. |

### Running the included example

```bash
./scripts/test-example.sh
```

The smoke test generates `Example/HotReloadExample.xcodeproj`, watches `Example/App`, hot-reloads a SwiftUI view (`ContentView.swift`), a TCA reducer (`CounterFeature.swift`), and a UIKit view controller (`UIKitPreviewViewController.swift`), then verifies an automatic structural rebuild.

## What reloads vs. what rebuilds

| Edit in watched file(s) | Behavior | State preserved? |
| --- | --- | --- |
| SwiftUI `View.body` in single-view or multi-view files (subviews, modifiers, `@ViewBuilder` branches, closures) | **Hot reloads in place** (~100–300 ms) | Yes (`@State`, `@StateObject`, `@Observable`, navigation) |
| TCA `Reducer.body` statements inside `Reduce { state, action in ... }` | **Hot reloads in place** (~100–300 ms) | Yes (`Store` state and in-flight effects) |
| Class method bodies (`func`, `private func`, `static func`, `override func`, `@objc func`) on non-generic top-level classes | **Hot reloads in place** (~100–300 ms) | Yes (fires `HotReloadRefreshing` / `onReload`) |
| Syntax error or type/compiler error inside a body or method | **Rejected without publishing** | Yes (running app stays on last good generation) |
| Changing TCA `@ReducerBuilder` composition outside `Reduce { ... }` (e.g., adding `Scope`, `.ifLet`, `.forEach`, `.onChange`) | **Automatic `xcodebuild` + relaunch** | No (clean relaunch) |
| Adding/changing stored properties, method signatures, `@objc` attributes, generic methods/classes, or new files/types | **Automatic `xcodebuild` + relaunch** | No (clean relaunch) |

### What works and what doesn't for UIKit class methods

- **Works:**
  - Instance, `private`, `fileprivate`, `internal`, `public`, `static`, `class`, and `nonisolated` methods on top-level non-generic classes (`UIViewController`, `UIView`, `UICollectionViewCell`, etc.).
  - Methods with default parameter values (HotReloadKit strips default value expressions on the replacement thunk while callers continue using the baseline default argument generators).
  - `override` methods (such as `override func viewDidLoad()` or `override func layoutSubviews()`, including `super` calls) and `@objc` methods: the Swift compiler emits both the dynamic replacement and an Objective-C category entry for the selector when `dlopen` loads the bundle.
- **Requires a rebuild (automatically detected by `ReplacementPlanner`):**
  - Initializers (`init`) and `deinit`.
  - Adding, removing, or changing a method signature, parameter types, return type, or `@objc` attribute.
  - Generic classes (`class Box<T>: UIViewController`) and generic methods (`func render<T>(_ value: T)`).
  - Overloaded methods on the same class that share identical argument labels (`func apply(_ x: Int)` and `func apply(_ x: String)`).
  - Methods returning non-`View` opaque types (`func make() -> some Protocol`).

## How HotReloadKit compares to Inject & InjectionIII / InjectionNext

| Dimension | HotReloadKit | Inject + InjectionIII / InjectionNext |
| --- | --- | --- |
| **Replacement mechanism** | Swift compiler's native `@_dynamicReplacement(for:)` + Mach-O `-bundle_loader` | `fishhook` symbol rebinding, direct Swift vtable/metadata patching, and live-object sweeping |
| **Incompatible / structural edits** | Detected ahead of time with `SwiftSyntax`; automatically falls back to `xcodebuild` + relaunch | Attempts in-place injection; adding stored properties or changing vtable/generic layout can crash the process |
| **SwiftUI & UIKit ergonomics** | `@HotReloadable`, `HotReloadViewControllerHost`, `HotReloadViewHost`, `HotReloadRefreshing`, `onReload` | `@ObserveInjection`, `Inject.ViewControllerHost`, `Inject.ViewHost`, `@objc func injected()` |
| **Build & transport** | Single CLI (`hotreload`) owns `xcodebuild`, `swiftc`, directory watching, and simulator file manifest (no network ports) | Separate macOS app/daemon parsing `xcactivitylog` build logs and communicating over a localhost TCP socket |

## Limitations

- **Top-level declarations only:** `struct` `body` properties and `class` methods must belong to top-level declarations (not types nested inside another `struct`, `enum`, or `class`). Editing a nested type falls back to a full rebuild.
- **iOS Simulator only:** Physical iOS devices do not share the host filesystem or permit arbitrary unsigned `dlopen` bundles; the runtime is compiled out on device targets.
- **Resident replacement images:** The Swift runtime does not support unloading images (`dlclose`) that register Swift metadata or dynamic replacements. `hotreload` automatically performs a clean rebuild every 50 generations to reclaim loaded bundles.
- **Underscored Swift features:** Dynamic replacement relies on `-Xfrontend -enable-implicit-dynamic`, `-Xfrontend -enable-private-imports`, `@_private(sourceFile:)`, and `@_dynamicReplacement(for:)`.

## Troubleshooting

- **CLI prints `generation N visible`, but the UI does not update:**
  - **SwiftUI:** Ensure the view (or an ancestor view) is annotated with `@HotReloadable` and `HotReloadRuntime.start()` is called once at launch.
  - **UIKit:** Ensure your controller/view conforms to `HotReloadRefreshing`, is wrapped in `HotReloadViewControllerHost` / `HotReloadViewHost`, or subscribes to `HotReloadRuntime.onReload` to re-run the updated method.
  - **`UIHostingConfiguration` cells:** Ensure the owning `UICollectionView` reconfigures/reloads visible items and invalidates layout on reload (e.g. via `collectionView.hotReloadReconfiguresVisibleItems(using: dataSource)`).
- **`Timed out waiting for generation N to load`:**
  - Verify that `HotReloadRuntime.start()` runs at launch and the app is not paused in LLDB or terminated.
- **Baseline build recompiles all SwiftPM packages:**
  - Add the Debug build settings directly to your application target's Debug configuration and pass `--use-project-build-settings`.

## License

MIT License. Copyright (c) 2026 Kit Langton. See [`LICENSE`](LICENSE).
