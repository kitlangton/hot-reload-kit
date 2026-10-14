@_exported import HotReloadRuntime

#if canImport(SwiftUI)
  import SwiftUI
#endif

@attached(member, names: named(__hotReload))
public macro HotReloadable() =
  #externalMacro(
    module: "HotReloadMacros",
    type: "HotReloadableMacro"
  )

#if canImport(SwiftUI)
  extension View {
    /// Recreates this view's whole subtree after every hot reload.
    ///
    /// `@HotReloadable` keeps view state and redraws the annotated view; use
    /// this instead at a root whose descendants aren't annotated, so an edit
    /// to any body or method beneath it shows. The subtree gets a new identity,
    /// so its `@State`, focus, and scroll positions reset (models and stores
    /// held outside it survive). In Release builds it returns the view unchanged.
    public func rebuildsOnHotReload() -> some View {
      #if DEBUG
        modifier(HotReloadRebuildModifier())
      #else
        self
      #endif
    }
  }

  #if DEBUG
    private struct HotReloadRebuildModifier: ViewModifier {
      @ObservedObject private var observer = HotReloadRuntime.everyReload

      func body(content: Content) -> some View {
        content.id(observer.generation)
      }
    }
  #endif
#endif
