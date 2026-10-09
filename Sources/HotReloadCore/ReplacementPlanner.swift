import Foundation
import SwiftParser
import SwiftSyntax

package struct Replacement: Equatable, Sendable {
  package let declaration: String
  package let source: String

  package init(declaration: String, source: String) {
    self.declaration = declaration
    self.source = source
  }
}

package enum ReplacementPlan: Equatable, Sendable {
  case replace(Replacement)
  case rebuild(reason: String)
}

package enum ReplacementPlanningError: Error, Equatable, CustomStringConvertible {
  case noReloadableBody
  case multipleReloadableBodies
  case syntaxError

  public var description: String {
    switch self {
    case .noReloadableBody:
      "The source file does not contain a reloadable computed body"
    case .multipleReloadableBodies:
      "The source file contains multiple computed bodies"
    case .syntaxError:
      "Syntax error in edited source; fix syntax before reloading"
    }
  }
}

package enum ReplacementPlanner {
  package static func plan(
    baseline: String,
    edited: String,
    module: String,
    sourceFile: String,
    generation: Int
  ) throws -> ReplacementPlan {
    let baselineSyntax = Parser.parse(source: baseline)
    let editedSyntax = Parser.parse(source: edited)

    let baselineBody: ViewBody
    do {
      baselineBody = try viewBody(in: baselineSyntax)
    } catch {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The baseline file does not have a single reloadable body")
    }

    let editedBody: ViewBody
    do {
      editedBody = try viewBody(in: editedSyntax)
    } catch ReplacementPlanningError.noReloadableBody where editedSyntax.hasError {
      throw ReplacementPlanningError.syntaxError
    } catch {
      return .rebuild(reason: "The edited file no longer has exactly one reloadable body")
    }

    guard !editedBody.isNested else {
      return .rebuild(reason: "Nested declarations are not reloadable yet")
    }
    guard !edited.contains("#if") else {
      return .rebuild(reason: "Conditional compilation requires a rebuild")
    }

    guard baselineBody.declaration == editedBody.declaration else {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The enclosing view declaration changed")
    }
    guard
      replacingBody(in: baseline, body: baselineBody, with: "{}")
        == replacingBody(in: edited, body: editedBody, with: "{}")
    else {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The edit changes code outside the computed body")
    }

    if isNonErasedOpaqueReturnType(editedBody.returnType) {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      guard
        let baselineReduced = replacingReduceClosureBodies(in: baselineBody.statements),
        let editedReduced = replacingReduceClosureBodies(in: editedBody.statements),
        baselineReduced == editedReduced
      else {
        return .rebuild(reason: "Changing opaque reducer composition requires a rebuild")
      }
    }

    let statements = dedent(editedBody.statements).trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "    \($0)" }
      .joined(separator: "\n")
    let imports = editedBody.imports.joined(separator: "\n")

    return .replace(
      Replacement(
        declaration: editedBody.declaration,
        source: """
          @_private(sourceFile: "\(sourceFile)") import \(module)
          \(imports)

          extension \(editedBody.declaration) {
            @_dynamicReplacement(for: body)
            var __hotReload_body_\(generation): \(editedBody.returnType) {
          \(statements)
            }
          }
          """
      ))
  }

  package static func hasSingleReloadableBody(in source: String) -> Bool {
    (try? viewBody(in: Parser.parse(source: source))) != nil
  }

  private static func viewBody(in syntax: SourceFileSyntax) throws -> ViewBody {
    let collector = ViewBodyCollector(viewMode: .sourceAccurate)
    collector.walk(syntax)
    guard collector.bodies.count == 1 else {
      if collector.bodies.isEmpty { throw ReplacementPlanningError.noReloadableBody }
      throw ReplacementPlanningError.multipleReloadableBodies
    }
    return collector.bodies[0]
  }

  private static func isNonErasedOpaqueReturnType(_ returnType: String) -> Bool {
    guard returnType == "some" || returnType.hasPrefix("some ") else { return false }
    return returnType != "some View" && returnType != "some SwiftUI.View"
  }

  private static func replacingReduceClosureBodies(in statementsSource: String) -> String? {
    let syntax = Parser.parse(source: statementsSource)
    let collector = ReduceClosureCollector(viewMode: .sourceAccurate)
    collector.walk(syntax)
    guard !collector.bodyRanges.isEmpty else { return nil }
    var bytes = Array(statementsSource.utf8)
    for range in collector.bodyRanges.reversed() {
      bytes.replaceSubrange(range, with: [])
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func replacingBody(in source: String, body: ViewBody, with replacement: String)
    -> String
  {
    var bytes = Array(source.utf8)
    bytes.replaceSubrange(body.startOffset..<body.endOffset, with: replacement.utf8)
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func dedent(_ source: String) -> String {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let indentation =
      lines
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
      .min() ?? 0
    return lines.map { String($0.dropFirst(min(indentation, $0.count))) }.joined(separator: "\n")
  }
}

private struct ViewBody {
  let declaration: String
  let returnType: String
  let statements: String
  let imports: [String]
  let isNested: Bool
  let startOffset: Int
  let endOffset: Int
}

private final class ViewBodyCollector: SyntaxVisitor {
  var bodies: [ViewBody] = []
  private var declarationNames: [String] = []
  private var nestingDepth = 0
  private var imports: [String] = []

  override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
    imports.append(node.trimmedDescription)
    return .skipChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    declarationNames.append(node.name.text)
    nestingDepth += 1
    return .visitChildren
  }

  override func visitPost(_ node: StructDeclSyntax) {
    declarationNames.removeLast()
    nestingDepth -= 1
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    nestingDepth += 1
    return .visitChildren
  }

  override func visitPost(_ node: EnumDeclSyntax) {
    nestingDepth -= 1
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    nestingDepth += 1
    return .visitChildren
  }

  override func visitPost(_ node: ClassDeclSyntax) {
    nestingDepth -= 1
  }

  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    nestingDepth += 1
    return .visitChildren
  }

  override func visitPost(_ node: ActorDeclSyntax) {
    nestingDepth -= 1
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    nestingDepth += 1
    return .visitChildren
  }

  override func visitPost(_ node: ExtensionDeclSyntax) {
    nestingDepth -= 1
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let declaration = declarationNames.last,
      node.bindings.count == 1,
      let binding = node.bindings.first,
      binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body",
      let returnType = binding.typeAnnotation?.type.trimmedDescription,
      let accessorBlock = binding.accessorBlock,
      case .getter(let statements) = accessorBlock.accessors
    else { return .skipChildren }

    bodies.append(
      ViewBody(
        declaration: declaration,
        returnType: returnType,
        statements: statements.description,
        imports: imports,
        isNested: nestingDepth > 1 || declarationNames.count != 1,
        startOffset: accessorBlock.positionAfterSkippingLeadingTrivia.utf8Offset,
        endOffset: accessorBlock.endPositionBeforeTrailingTrivia.utf8Offset
      ))
    return .skipChildren
  }
}

private final class ReduceClosureCollector: SyntaxVisitor {
  var bodyRanges: [Range<Int>] = []

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard Self.isReduceCall(node.calledExpression),
      let closure = node.trailingClosure ?? Self.argumentClosure(in: node.arguments)
    else {
      return .visitChildren
    }
    let start = closure.leftBrace.endPosition.utf8Offset
    let end = closure.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset
    if start <= end {
      bodyRanges.append(start..<end)
    }
    return .skipChildren
  }

  private static func isReduceCall(_ expr: ExprSyntax) -> Bool {
    if let declRef = expr.as(DeclReferenceExprSyntax.self) {
      return declRef.baseName.text == "Reduce"
    }
    if let generic = expr.as(GenericSpecializationExprSyntax.self) {
      return isReduceCall(generic.expression)
    }
    if let member = expr.as(MemberAccessExprSyntax.self) {
      return member.declName.baseName.text == "Reduce"
    }
    return false
  }

  private static func argumentClosure(in arguments: LabeledExprListSyntax) -> ClosureExprSyntax? {
    guard arguments.count == 1, let first = arguments.first else { return nil }
    return first.expression.as(ClosureExprSyntax.self)
  }
}
