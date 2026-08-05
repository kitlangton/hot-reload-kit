import HotReloadMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

@Test("HotReloadable observes runtime generations")
func hotReloadableAddsObserver() {
  assertMacroExpansion(
    """
    @HotReloadable
    struct GreetingView: View {}
    """,
    expandedSource: """
      struct GreetingView: View {

          #if DEBUG
          @SwiftUI.ObservedObject private var __hotReload = HotReloadRuntime.observer(for: "GreetingView")
          #endif
      }
      """,
    macros: ["HotReloadable": HotReloadableMacro.self]
  )
}
