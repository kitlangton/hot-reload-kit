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
