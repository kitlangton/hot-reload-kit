# Architecture

HotReloadKit has one external seam: a developer runs `hotreload` against a project, scheme, and watched source file or directory. The implementation hides source classification, thunk generation, compilation, linking, artifact publication, loading, invalidation, and fallback builds behind that interface.

## Modules

### HotReloadCore

`ReplacementPlanner` parses baseline and edited source with `SwiftSyntax`. It collects all reloadable units in the file:
- computed `body` getters on `struct` declarations (supporting files with dozens of `View` or `Reducer` types), and
- method bodies on top-level `class` declarations (`UIViewController`, `UIView`, etc.).

It compares baseline and edited files after replacing all reloadable unit bodies with `{}`. For non-`View` opaque return types (such as TCA reducers), it also verifies that edits remain inside `Reduce { ... }` closure bodies so the underlying opaque return type does not change.

If the outer source is identical and every changed unit passes safety checks, it emits a source-scoped `@_private(sourceFile:)` dynamic replacement thunk containing only the declarations that changed. If the edited syntax tree contains unbalanced parse errors, it rejects the edit immediately without triggering a build. Otherwise it returns `.rebuild` with a reason.

### hotreload (HotReloadCLI)

The host CLI owns the observed build and file watcher. It:

1. Builds with implicit dynamic replacement, private imports, opaque type erasure, exported symbols, and the conventional executable layout (or uses the project's existing Debug settings with `--use-project-build-settings`).
2. Reads structured Xcode build settings.
3. Installs and launches the simulator application with per-session manifest paths.
4. Watches a single file (`--source`) or one or more directory trees (`--watch`), coalescing multi-file saves (such as `rsync` batches) over a settle window.
5. Compiles safe replacement thunks into `.o` object files and links them into a single Mach-O bundle with `-bundle_loader`.
6. Atomically publishes a generation manifest listing all changed declarations.
7. Waits for the runtime receipt before reporting success.
8. Rebuilds and relaunches once per batch when any file is added, removed, or rejected by the planner.

Compile or link failures do not publish a generation, so the running process continues using the last successful implementation.

### HotReloadRuntime

The Debug simulator runtime polls one atomic manifest on the simulator's shared host filesystem. For each new generation it:

1. Calls `dlopen` with `RTLD_NOW | RTLD_LOCAL`.
2. Retains the image handle for the process lifetime.
3. Invalidates the `@HotReloadable` observers registered for the affected declarations (or all active observers when a child helper without its own observer is replaced).
4. Invokes `hotReloaded()` on registered and window-hierarchy `HotReloadRefreshing` objects, fires `HotReloadRuntime.onReload` closures, yields to `HotReloadRuntime.reloads()` streams, and posts `HotReloadRuntime.didReloadNotification`.
5. Atomically writes a success or error receipt.

The manifest channel is deliberately simulator-specific. It has no listener, open port, discovery protocol, or remote-code path on physical devices.

### HotReloadUI

- `@HotReloadable` is an attached member macro. In Debug it adds an `@ObservedObject` obtained from `HotReloadRuntime.observer(for:)`. In Release it adds no member.
- `HotReloadViewControllerHost` and `HotReloadViewHost` wrap `@autoclosure` builders to recreate UIKit/AppKit controllers and views on reload while forwarding navigation and status-bar properties.
- `UICollectionView.hotReloadReconfiguresVisibleItems` reconfigures visible items and invalidates self-sizing cell layouts after each reload.

## Replacement flow

```text
save file(s) / rsync batch
    |
    v
SwiftSyntax compatibility plan (per changed file)
    |
    +-- structural edit --> xcodebuild --> install --> relaunch
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
dlopen in simulator process
    |
    v
Swift / ObjC runtime installs replacement(s)
    |
    +-- SwiftUI: keyed @HotReloadable observer invalidates body
    +-- TCA: next action invokes replacement reducer
    +-- UIKit: HotReloadRefreshing.hotReloaded(), hosts, and onReload fire
```
