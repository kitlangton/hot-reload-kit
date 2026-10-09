import Foundation
import HotReloadCore
import Testing

@Test("a SwiftUI body edit produces a dynamic replacement thunk")
func bodyEditProducesThunk() throws {
  let baseline = """
    import SwiftUI

    struct GreetingView: View {
      var body: some View {
        Text("Before")
      }
    }
    """
  let edited = baseline.replacingOccurrences(of: "Before", with: "After")

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "GreetingView.swift",
    generation: 1
  )

  #expect(
    plan
      == .replace(
        Replacement(
          declaration: "GreetingView",
          source: """
            @_private(sourceFile: "GreetingView.swift") import ExampleApp
            import SwiftUI

            extension GreetingView {
              @_dynamicReplacement(for: body)
              var __hotReload_body_1: some View {
                Text("After")
              }
            }
            """
        )))
}

@Test("a TCA reducer body edit produces a dynamic replacement thunk")
func reducerBodyEditProducesThunk() throws {
  let baseline = """
    import ComposableArchitecture

    @Reducer
    struct CounterFeature {
      @ObservableState
      struct State: Equatable { var count = 0 }
      enum Action { case increment }

      var body: some ReducerOf<Self> {
        Reduce { state, action in
          switch action {
          case .increment:
            state.count += 1
            return .none
          }
        }
      }
    }
    """
  let edited = baseline.replacingOccurrences(of: "state.count += 1", with: "state.count += 2")

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "CounterFeature.swift",
    generation: 3
  )

  guard case .replace(let replacement) = plan else {
    Issue.record("Expected a reducer replacement")
    return
  }
  #expect(replacement.declaration == "CounterFeature")
  #expect(replacement.source.contains("@_dynamicReplacement(for: body)"))
  #expect(replacement.source.contains("var __hotReload_body_3: some ReducerOf<Self>"))
  #expect(replacement.source.contains("state.count += 2"))
  #expect(replacement.source.contains("import ComposableArchitecture"))
  #expect(!replacement.source.contains("import SwiftUI"))
  #expect(!replacement.source.contains("@MainActor"))
}

@Test("a stored property edit requires a rebuild")
func storedPropertyEditRequiresRebuild() throws {
  let baseline = """
    import SwiftUI
    struct GreetingView: View {
      var body: some View { Text("Hello") }
    }
    """
  let edited = baseline.replacingOccurrences(
    of: "struct GreetingView: View {",
    with: "struct GreetingView: View {\n  var name = \"Blob\""
  )

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "GreetingView.swift",
    generation: 1
  )

  #expect(plan == .rebuild(reason: "The edit changes code outside the computed body"))
}

@Test("adding another body requires a rebuild instead of failing the session")
func anotherBodyRequiresRebuild() throws {
  let baseline = """
    import SwiftUI
    struct GreetingView: View {
      var body: some View { Text("Hello") }
    }
    """
  let edited =
    baseline + """

      struct OtherView: View {
        var body: some View { Text("Other") }
      }
      """

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "GreetingView.swift",
    generation: 1
  )

  #expect(plan == .rebuild(reason: "The edited file no longer has exactly one reloadable body"))
}

@Test("changing opaque reducer builder composition requires a rebuild")
func reducerCompositionChangeRequiresRebuild() throws {
  let baseline = """
    import ComposableArchitecture

    @Reducer
    struct CounterFeature {
      @ObservableState
      struct State: Equatable { var count = 0 }
      enum Action { case increment }

      var body: some ReducerOf<Self> {
        Reduce { state, action in
          switch action {
          case .increment:
            state.count += 1
            return .none
          }
        }
      }
    }
    """
  let edited = baseline.replacingOccurrences(
    of: "      }\n    }\n  }",
    with: """
            }
          }
          Reduce { _, _ in .none }
        }
      """
  )

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "CounterFeature.swift",
    generation: 1
  )

  #expect(plan == .rebuild(reason: "Changing opaque reducer composition requires a rebuild"))
}

@Test("a syntax error with unbalanced braces throws syntaxError instead of rebuilding")
func unbalancedBraceThrowsSyntaxError() {
  let baseline = """
    import SwiftUI

    struct GreetingView: View {
      var body: some View {
        VStack {
          Text("Before")
        }
      }
    }
    """
  let edited = """
    import SwiftUI

    struct GreetingView: View {
      var body: some View {
        VStack {
          Text("After")
      }
    }
    """

  #expect(throws: ReplacementPlanningError.syntaxError) {
    try ReplacementPlanner.plan(
      baseline: baseline,
      edited: edited,
      module: "ExampleApp",
      sourceFile: "GreetingView.swift",
      generation: 1
    )
  }
}

@Test("a view nested inside an enum requires a rebuild")
func nestedInEnumRequiresRebuild() throws {
  let baseline = """
    import SwiftUI

    enum Namespace {
      struct GreetingView: View {
        var body: some View { Text("Before") }
      }
    }
    """
  let edited = baseline.replacingOccurrences(of: "Before", with: "After")

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "GreetingView.swift",
    generation: 1
  )

  #expect(plan == .rebuild(reason: "Nested declarations are not reloadable yet"))
}

@Test("a local variable named body inside a helper method does not block view reload")
func localBodyVariableInMethodIsIgnored() throws {
  let baseline = """
    import SwiftUI

    struct GreetingView: View {
      func format() -> String {
        var body: String { "helper" }
        return body
      }

      var body: some View {
        Text("Before")
      }
    }
    """
  let edited = baseline.replacingOccurrences(of: "Before", with: "After")

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "GreetingView.swift",
    generation: 1
  )

  guard case .replace(let replacement) = plan else {
    Issue.record("Expected a replacement thunk")
    return
  }
  #expect(replacement.declaration == "GreetingView")
  #expect(replacement.source.contains("Text(\"After\")"))
}

@Test("editing one view in a multi-view file emits a replacement for only that view")
func multiBodyFileSingleEditProducesTargetedThunk() throws {
  let baseline = """
    import SwiftUI

    private struct HeaderBadge: View {
      var body: some View {
        Text("Badge v1")
      }
    }

    struct SessionScreen: View {
      var body: some View {
        VStack {
          HeaderBadge()
          Text("Session v1")
        }
      }
    }
    """
  let edited = baseline.replacingOccurrences(of: "Session v1", with: "Session v2")

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "SessionView.swift",
    generation: 2
  )

  guard case .replace(let replacement) = plan else {
    Issue.record("Expected a targeted replacement thunk, got \(plan)")
    return
  }
  #expect(replacement.declaration == "SessionScreen")
  #expect(replacement.declarations == ["SessionScreen"])
  #expect(replacement.source.contains("extension SessionScreen"))
  #expect(!replacement.source.contains("extension HeaderBadge"))
  #expect(replacement.source.contains("Text(\"Session v2\")"))
}

@Test("editing multiple views in a single file emits replacements for each changed view")
func multiBodyFileMultipleEditsProduceCombinedThunk() throws {
  let baseline = """
    import SwiftUI

    struct HeaderView: View {
      var body: some View {
        Text("Header 1")
      }
    }

    struct FooterView: View {
      var body: some View {
        Text("Footer 1")
      }
    }
    """
  let edited =
    baseline
    .replacingOccurrences(of: "Header 1", with: "Header 2")
    .replacingOccurrences(of: "Footer 1", with: "Footer 2")

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "ExampleApp",
    sourceFile: "ChromeViews.swift",
    generation: 4
  )

  guard case .replace(let replacement) = plan else {
    Issue.record("Expected combined replacement thunk")
    return
  }
  #expect(replacement.declarations == ["HeaderView", "FooterView"])
  #expect(replacement.source.contains("extension HeaderView"))
  #expect(replacement.source.contains("extension FooterView"))
}

@Test("a class method body edit produces a dynamic replacement thunk stripping default arguments")
func classMethodBodyEditProducesThunk() throws {
  let baseline = """
    import UIKit

    final class TranscriptListViewController: UIViewController {
      private var headerHeight: CGFloat = 44

      private func configureHeader(animated: Bool = false, inset: CGFloat) -> CGFloat {
        headerHeight = inset + (animated ? 8 : 0)
        return headerHeight
      }

      nonisolated private static func clamp(_ value: CGFloat) -> CGFloat {
        max(0, value)
      }
    }
    """
  let edited = baseline.replacingOccurrences(
    of: "headerHeight = inset + (animated ? 8 : 0)",
    with: "headerHeight = inset + (animated ? 16 : 4)"
  )

  let plan = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: edited,
    module: "OpenCode",
    sourceFile: "TranscriptListViewController.swift",
    generation: 5
  )

  guard case .replace(let replacement) = plan else {
    Issue.record("Expected class method replacement, got \(plan)")
    return
  }
  #expect(replacement.declaration == "TranscriptListViewController")
  #expect(replacement.source.contains("@_dynamicReplacement(for: configureHeader(animated:inset:))"))
  #expect(
    replacement.source.contains(
      "func __hotReload_configureHeader_5(animated: Bool, inset: CGFloat) -> CGFloat"
    ))
  #expect(replacement.source.contains("headerHeight = inset + (animated ? 16 : 4)"))
}

@Test("changing a class method signature or @objc attribute requires a rebuild")
func classMethodSignatureOrObjcChangeRequiresRebuild() throws {
  let baseline = """
    import UIKit

    final class CardView: UIView {
      func refreshLayout() {
        setNeedsLayout()
      }
    }
    """
  let withObjc = baseline.replacingOccurrences(
    of: "func refreshLayout()",
    with: "@objc func refreshLayout()"
  )
  let planObjc = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: withObjc,
    module: "ExampleApp",
    sourceFile: "CardView.swift",
    generation: 1
  )
  #expect(planObjc == .rebuild(reason: "The edit changes code outside the computed body"))

  let withParam = baseline.replacingOccurrences(
    of: "func refreshLayout()",
    with: "func refreshLayout(force: Bool)"
  )
  let planParam = try ReplacementPlanner.plan(
    baseline: baseline,
    edited: withParam,
    module: "ExampleApp",
    sourceFile: "CardView.swift",
    generation: 1
  )
  #expect(planParam == .rebuild(reason: "The edit changes code outside the computed body"))
}

@Test("generic classes, generic class methods, and ambiguous overloads require a rebuild")
func unsafeClassMethodFormsRequireRebuild() throws {
  let genericClassBase = """
    import UIKit
    final class BoxController<T>: UIViewController {
      func configure() { view.alpha = 1 }
    }
    """
  let genericClassEdit = genericClassBase.replacingOccurrences(of: "alpha = 1", with: "alpha = 0.5")
  #expect(
    try ReplacementPlanner.plan(
      baseline: genericClassBase,
      edited: genericClassEdit,
      module: "ExampleApp",
      sourceFile: "BoxController.swift",
      generation: 1
    ) == .rebuild(reason: "Generic classes require a rebuild")
  )

  let genericMethodBase = """
    import UIKit
    final class ListController: UIViewController {
      func render<T>(_ item: T) -> String { "\\(item)" }
    }
    """
  let genericMethodEdit = genericMethodBase.replacingOccurrences(
    of: "\"\\(item)\"", with: "\"item:\\(item)\"")
  #expect(
    try ReplacementPlanner.plan(
      baseline: genericMethodBase,
      edited: genericMethodEdit,
      module: "ExampleApp",
      sourceFile: "ListController.swift",
      generation: 1
    ) == .rebuild(reason: "Generic class methods require a rebuild")
  )

  let overloadedBase = """
    import UIKit
    final class ListController: UIViewController {
      func apply(_ value: Int) -> Int { value + 1 }
      func apply(_ value: String) -> String { value }
    }
    """
  let overloadedEdit = overloadedBase.replacingOccurrences(of: "value + 1", with: "value + 2")
  #expect(
    try ReplacementPlanner.plan(
      baseline: overloadedBase,
      edited: overloadedEdit,
      module: "ExampleApp",
      sourceFile: "ListController.swift",
      generation: 1
    ) == .rebuild(reason: "Overloaded methods with identical argument labels require a rebuild")
  )
}
