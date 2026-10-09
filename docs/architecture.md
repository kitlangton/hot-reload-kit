# Architecture

HotReloadKit has one external seam: a developer runs `hotreload` against a project, scheme, and source file. The implementation hides source classification, thunk generation, compilation, linking, artifact publication, loading, invalidation, and fallback builds behind that interface.

## Modules

### HotReloadCore

`ReplacementPlanner` parses baseline and edited source with SwiftSyntax. It compares both files after replacing their `body` accessor blocks with the same marker, and for non-`View` opaque return types (such as TCA reducers) it also verifies that edits remain inside `Reduce { ... }` closure bodies so the underlying opaque return type does not change.

If the remaining source is identical, it emits a source-scoped dynamic replacement thunk. If the edited syntax tree contains unbalanced parse errors, it rejects the edit immediately without triggering a build. Otherwise it returns `.rebuild` with a reason. This conservative comparison means unsupported syntax cannot accidentally be classified as safe.

### hotreload

The host CLI owns the observed build. It:

1. Builds with implicit dynamic replacement, private imports, opaque type erasure, exported symbols, and the conventional executable layout.
2. Reads structured Xcode build settings.
3. Installs and launches the simulator application with per-session manifest paths.
4. Watches the selected source.
5. Compiles safe replacement thunks into objects.
6. Links each object as a uniquely named Mach-O bundle with `-bundle_loader`.
7. Atomically publishes a generation manifest.
8. Waits for the runtime receipt before reporting success.
9. Rebuilds and relaunches when the planner rejects an edit.

Compile or link failures do not publish a generation, so the running process continues using the last successful implementation.

### HotReloadRuntime

The Debug runtime polls one atomic manifest on the simulator's shared host filesystem. For each new generation it:

1. Calls `dlopen` with `RTLD_NOW | RTLD_LOCAL`.
2. Retains the image handle for the process lifetime.
3. Invalidates the observer registered for the affected declaration.
4. Atomically writes a success or error receipt.

The manifest channel is deliberately simulator-specific. It has no listener, open port, discovery protocol, or remote-code path on physical devices.

### HotReloadUI

`@HotReloadable` is an attached member macro. In Debug it adds an `@ObservedObject` obtained from `HotReloadRuntime.observer(for:)`. In Release it adds no member.

SwiftUI reevaluates the affected `body` after the runtime observer publishes. Existing model and `@State` storage remain attached to the same view identity.

## Replacement flow

```text
save source
    |
    v
SwiftSyntax compatibility plan
    |
    +-- structural edit --> xcodebuild --> install --> relaunch
    |
    v
generated @_dynamicReplacement thunk
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
Swift runtime installs replacement
    |
    +-- SwiftUI: keyed observer invalidates body
    |
    +-- TCA: next action invokes replacement reducer
```

## Why not interposition

InjectionLite supports a wider set of edits through fishhook rebinding, direct Swift vtable mutation, metadata layout assumptions, generic allocator hooks, key-path hooks, and live-object sweeping. HotReloadKit intentionally avoids those mechanisms.

The narrower replacement policy produces an explicit result for every save: replace, rebuild, or compiler error. It does not load an artifact after detecting an incompatible declaration shape.

## Evolution

The next safe expansion is multiple independently changed computed properties and functions. It should retain the same rule: generate compiler-supported dynamic replacements only when declaration signatures and enclosing type layouts are unchanged. Physical-device loading and arbitrary runtime interposition are outside the intended scope.
