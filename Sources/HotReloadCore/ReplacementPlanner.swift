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

private enum ReplacementPlanningError: Error, Equatable {
  case noReloadableBody
  case multipleReloadableBodies
}

package enum ReplacementPlanner {
  package static func plan(
    baseline: String,
    edited: String,
    module: String,
    sourceFile: String,
    generation: Int
  ) throws -> ReplacementPlan {
    let baselineBody = try viewBody(in: baseline)
    let editedBody: ViewBody
    do {
      editedBody = try viewBody(in: edited)
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
      return .rebuild(reason: "The enclosing view declaration changed")
    }
    guard
      replacingBody(in: baseline, body: baselineBody, with: "{}")
        == replacingBody(in: edited, body: editedBody, with: "{}")
    else {
      return .rebuild(reason: "The edit changes code outside the computed body")
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

  private static func viewBody(in source: String) throws -> ViewBody {
    let collector = ViewBodyCollector(viewMode: .sourceAccurate)
    collector.walk(Parser.parse(source: source))
    guard collector.bodies.count == 1 else {
      if collector.bodies.isEmpty { throw ReplacementPlanningError.noReloadableBody }
      throw ReplacementPlanningError.multipleReloadableBodies
    }
    return collector.bodies[0]
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
  private var imports: [String] = []

  override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
    imports.append(node.trimmedDescription)
    return .skipChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    declarationNames.append(node.name.text)
    return .visitChildren
  }

  override func visitPost(_ node: StructDeclSyntax) {
    declarationNames.removeLast()
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
        isNested: declarationNames.count > 1,
        startOffset: accessorBlock.positionAfterSkippingLeadingTrivia.utf8Offset,
        endOffset: accessorBlock.endPositionBeforeTrailingTrivia.utf8Offset
      ))
    return .skipChildren
  }
}
