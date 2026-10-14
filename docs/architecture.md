# Architecture

HotReloadKit has one external seam: a developer runs `hotreload` against a project, scheme, and watched source file or directory. The implementation hides source classification, thunk generation, compilation, linking, artifact publication, loading, invalidation, and fallback builds behind that interface.

## Modules

### HotReloadCore

`ReplacementPlanner` parses baseline and edited source with `SwiftSyntax`. It collects all reloadable units in the file:
- computed `body` getters on `struct` declarations (supporting files with dozens of `View` or `Reducer` types),
- other get-only computed properties on top-level structs and classes (SwiftUI helpers such as `private var sidebar: some View`; non-`View` opaque types rebuild), and
- method bodies on top-level `class` declarations (`UIViewController`, `NSView`, etc.) and `struct` declarations (including `mutating`).

It compares baseline and edited files after replacing all reloadable unit bodies with `{}`. For non-`View` opaque return types (such as TCA reducers), it also verifies that edits remain inside `Reduce { ... }` closure bodies so the underlying opaque return type does not change.

If the outer source is identical and every changed unit passes safety checks, it emits a source-scoped `@_private(sourceFile:)` dynamic replacement thunk containing only the declarations that changed. If the edited syntax tree contains unbalanced parse errors, it rejects the edit immediately without triggering a build. Otherwise it returns `.rebuild` with a reason.

### hotreload (HotReloadCLI)

The host CLI owns the observed build and file watcher. It:

1. Builds with implicit dynamic replacement, private imports, opaque type erasure, exported symbols, and the conventional executable layout (or uses the project's existing Debug settings with `--use-project-build-settings`).
2. Reads structured Xcode build settings.
3. Installs and launches the simulator application with per-session manifest paths (`--platform ios`), or launches the built Mac app's executable directly with them in its environment (`--platform macos`). `TargetPlatform` (in `HotReloadCore`) owns every platform-specific value: destination, SDK, deployment-target setting, thunk target triple, clang minimum-version flag, and Swift runtime library directory.
4. Watches a single file (`--source`) or one or more directory trees (`--watch`), coalescing multi-file saves (such as `rsync` batches) over a settle window.
5. Compiles safe replacement thunks into `.o` object files and links them into a single Mach-O bundle with `-bundle_loader`.
6. Atomically publishes a generation manifest listing all changed declarations.
7. Waits for the runtime receipt before reporting success.
8. Rebuilds and relaunches once per batch when any file is added, removed, or rejected by the planner.

Compile or link failures do not publish a generation, so the running process continues using the last successful implementation.

### HotReloadRuntime

The Debug runtime (iOS Simulator or macOS) polls one atomic manifest on the host filesystem the simulator shares. For each new generation it:

1. Calls `dlopen` with `RTLD_NOW | RTLD_LOCAL`.
2. Retains the image handle for the process lifetime.
3. Invalidates the `@HotReloadable` observers registered for the affected declarations (or all active observers when a child helper without its own observer is replaced).
4. Invokes `hotReloaded()` on registered and window-hierarchy `HotReloadRefreshing` objects (on macOS also window controllers and windows, and it marks every window view as needing layout and display), fires `HotReloadRuntime.onReload` closures, yields to `HotReloadRuntime.reloads()` streams, and posts `HotReloadRuntime.didReloadNotification`.
5. Atomically writes a success or error receipt.

The manifest channel is deliberately limited to the simulator and Debug Mac builds. It has no listener, open port, discovery protocol, or remote-code path on physical devices, and Release builds compile it out.

### HotReloadUI

- `@HotReloadable` is an attached member macro. In Debug it adds an `@ObservedObject` obtained from `HotReloadRuntime.observer(for:)`. In Release it adds no member.
- `HotReloadViewControllerHost` and `HotReloadViewHost` wrap `@autoclosure` builders to recreate UIKit/AppKit controllers and views on reload while forwarding navigation and status-bar properties.
- `UICollectionView.hotReloadReconfiguresVisibleItems` reconfigures visible items and invalidates self-sizing cell layouts after each reload; `UITableView.hotReloadReloadsVisibleRows` reloads visible rows.
- On AppKit, `NSTableView.hotReloadReloadsVisibleRows` re-requests visible cell views and their heights, and `NSCollectionView.hotReloadReconfiguresVisibleItems` reloads visible items and invalidates the layout.
- `View.rebuildsOnHotReload()` gives a SwiftUI subtree a new identity on every reload, for roots whose descendants aren't annotated.

## Replacement flow

```text
save file(s) / rsync batch
    |
    v
SwiftSyntax compatibility plan (per changed file)
    |
    +-- structural edit --> xcodebuild --> install --> relaunch (macOS: terminate --> relaunch)
    |
    v
generated @_dynamicReplacement thunk(s)
    |
    v
swiftc -emit-object
    |
    v
clang -bundle -bundle_loader <app executable>
    |
    v
atomic manifest publication
    |
    v
dlopen in the simulator or Mac app process
    |
    v
Swift / ObjC runtime installs replacement(s)
    |
    +-- SwiftUI: keyed @HotReloadable observer invalidates body
    +-- TCA: next action invokes replacement reducer
    +-- UIKit/AppKit: HotReloadRefreshing.hotReloaded(), hosts, and onReload fire
    +-- AppKit: window views marked as needing layout and display
```
