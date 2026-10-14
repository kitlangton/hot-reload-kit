import Foundation
import SwiftParser
import SwiftSyntax

package struct Replacement: Equatable, Sendable {
  package let declaration: String
  package let declarations: [String]
  package let source: String

  package init(declaration: String, declarations: [String]? = nil, source: String) {
    let resolvedDeclarations = declarations ?? [declaration]
    self.declaration = resolvedDeclarations.first ?? declaration
    self.declarations = resolvedDeclarations
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
      "The source file does not contain a reloadable computed body or class method"
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

    let baselineCollection = collectUnits(in: baselineSyntax)
    let editedCollection = collectUnits(in: editedSyntax)

    guard !baselineCollection.units.isEmpty else {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The baseline file does not have a single reloadable body")
    }

    guard !editedCollection.units.isEmpty else {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The edited file no longer has exactly one reloadable body")
    }

    let baselineStructBodies = baselineCollection.units.filter { $0.kind == .structBody }
    let editedStructBodies = editedCollection.units.filter { $0.kind == .structBody }
    if baselineStructBodies.count != editedStructBodies.count {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The edited file no longer has exactly one reloadable body")
    }

    guard baselineCollection.units.count == editedCollection.units.count else {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The edited file changes reloadable declarations")
    }

    for (baseUnit, editUnit) in zip(baselineCollection.units, editedCollection.units) {
      guard baseUnit.declaration == editUnit.declaration else {
        if editedSyntax.hasError {
          throw ReplacementPlanningError.syntaxError
        }
        return .rebuild(reason: "The enclosing view declaration changed")
      }
      guard baseUnit.headerKey == editUnit.headerKey else {
        if editedSyntax.hasError {
          throw ReplacementPlanningError.syntaxError
        }
        return .rebuild(reason: "The edit changes code outside the computed body")
      }
    }

    guard
      replacingUnits(in: baseline, units: baselineCollection.units, with: "{}")
        == replacingUnits(in: edited, units: editedCollection.units, with: "{}")
    else {
      if editedSyntax.hasError {
        throw ReplacementPlanningError.syntaxError
      }
      return .rebuild(reason: "The edit changes code outside the computed body")
    }

    if editedSyntax.hasError {
      throw ReplacementPlanningError.syntaxError
    }

    var changedIndices: [Int] = []
    for index in editedCollection.units.indices {
      if baselineCollection.units[index].statements != editedCollection.units[index].statements {
        changedIndices.append(index)
      }
    }
    if changedIndices.isEmpty {
      changedIndices = [0]
    }

    var extensionBlocks: [String] = []
    var changedDeclarations: [String] = []

    for index in changedIndices {
      let baseUnit = baselineCollection.units[index]
      let editUnit = editedCollection.units[index]

      if let unsafetyReason = editUnit.unsafetyReason {
        return .rebuild(reason: unsafetyReason)
      }

      if editUnit.kind == .structBody, isNonErasedOpaqueReturnType(editUnit.returnType) {
        guard
          let baselineReduced = replacingReduceClosureBodies(in: baseUnit.statements),
          let editedReduced = replacingReduceClosureBodies(in: editUnit.statements),
          baselineReduced == editedReduced
        else {
          return .rebuild(reason: "Changing opaque reducer composition requires a rebuild")
        }
      }

      let statements = dedent(editUnit.statements).trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "    \($0)" }
        .joined(separator: "\n")

      switch editUnit.kind {
      case .structBody:
        extensionBlocks.append(
          """
          extension \(editUnit.declaration) {
            @_dynamicReplacement(for: body)
            var __hotReload_body_\(generation): \(editUnit.returnType) {
          \(statements)
            }
          }
          """
        )
      case .classMethod(let method):
        let suffix = changedIndices.count > 1 ? "\(index)_\(generation)" : "\(generation)"
        extensionBlocks.append(
          """
          extension \(editUnit.declaration) {
            @_dynamicReplacement(for: \(method.dynamicReplacementTarget))
            \(method.replacementPrefix)func __hotReload_\(method.baseName)_\(suffix)\(method.cleanedSignature) {
          \(statements)
            }
          }
          """
        )
      case .computedProperty(let property):
        let suffix = changedIndices.count > 1 ? "\(index)_\(generation)" : "\(generation)"
        extensionBlocks.append(
          """
          extension \(editUnit.declaration) {
            @_dynamicReplacement(for: \(property.name))
            \(property.replacementPrefix)var __hotReload_\(property.name)_\(suffix): \(editUnit.returnType) {
          \(statements)
            }
          }
          """
        )
      }

      if !changedDeclarations.contains(editUnit.declaration) {
        changedDeclarations.append(editUnit.declaration)
      }
    }

    let importsBlock = editedCollection.imports.joined(separator: "\n")
    let importSection = importsBlock.isEmpty ? "" : "\n\(importsBlock)"
    let extensionsSource = extensionBlocks.joined(separator: "\n\n")

    return .replace(
      Replacement(
        declaration: changedDeclarations[0],
        declarations: changedDeclarations,
        source: """
          @_private(sourceFile: "\(sourceFile)") import \(module)\(importSection)

          \(extensionsSource)
          """
      ))
  }

  package static func hasReloadableDeclarations(in source: String) -> Bool {
    let collection = collectUnits(in: Parser.parse(source: source))
    return collection.units.contains { $0.unsafetyReason == nil }
  }

  package static func hasSingleReloadableBody(in source: String) -> Bool {
    hasReloadableDeclarations(in: source)
  }

  private static func collectUnits(in syntax: SourceFileSyntax) -> CollectedFile {
    let collector = ReloadableUnitCollector(viewMode: .sourceAccurate)
    collector.walk(syntax)
    return collector.finalize()
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

  private static func replacingUnits(
    in source: String,
    units: [ReloadableUnit],
    with replacement: String
  ) -> String {
    var bytes = Array(source.utf8)
    let sorted = units.sorted { $0.startOffset < $1.startOffset }
    for unit in sorted.reversed() {
      bytes.replaceSubrange(unit.startOffset..<unit.endOffset, with: replacement.utf8)
    }
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

private struct ClassMethodInfo: Equatable {
  let baseName: String
  let dynamicReplacementTarget: String
  let replacementPrefix: String
  let cleanedSignature: String
  let fullOriginalHeader: String
}

private struct ComputedPropertyInfo: Equatable {
  let name: String
  let replacementPrefix: String
  let fullOriginalHeader: String
}

private enum ReloadableUnitKind: Equatable {
  case structBody
  case classMethod(ClassMethodInfo)
  case computedProperty(ComputedPropertyInfo)
}

private struct ReloadableUnit {
  let declaration: String
  let kind: ReloadableUnitKind
  let returnType: String
  let statements: String
  let unsafetyReason: String?
  let startOffset: Int
  let endOffset: Int

  var headerKey: String {
    switch kind {
    case .structBody:
      return "struct:\(declaration):body:\(returnType)"
    case .classMethod(let method):
      return "class:\(declaration):func:\(method.fullOriginalHeader)"
    case .computedProperty(let property):
      return "type:\(declaration):var:\(property.fullOriginalHeader):\(returnType)"
    }
  }
}

private struct CollectedFile {
  let imports: [String]
  let units: [ReloadableUnit]
}

private final class ReloadableUnitCollector: SyntaxVisitor {
  private enum EnclosingContext {
    case structDecl(name: String, isGeneric: Bool)
    case classDecl(name: String, isGeneric: Bool)
    case other
  }

  private var stack: [EnclosingContext] = []
  private var imports: [String] = []
  private var rawUnits: [ReloadableUnit] = []

  func finalize() -> CollectedFile {
    var methodTargetCounts: [String: Int] = [:]
    for unit in rawUnits {
      if case .classMethod(let method) = unit.kind {
        let key = "\(unit.declaration).\(method.dynamicReplacementTarget)"
        methodTargetCounts[key, default: 0] += 1
      }
    }

    let resolved = rawUnits.map { unit -> ReloadableUnit in
      guard unit.unsafetyReason == nil,
        case .classMethod(let method) = unit.kind
      else {
        return unit
      }
      let key = "\(unit.declaration).\(method.dynamicReplacementTarget)"
      if (methodTargetCounts[key] ?? 0) > 1 {
        return ReloadableUnit(
          declaration: unit.declaration,
          kind: unit.kind,
          returnType: unit.returnType,
          statements: unit.statements,
          unsafetyReason: "Overloaded methods with identical argument labels require a rebuild",
          startOffset: unit.startOffset,
          endOffset: unit.endOffset
        )
      }
      return unit
    }

    return CollectedFile(imports: imports, units: resolved)
  }

  override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
    imports.append(node.trimmedDescription)
    return .skipChildren
  }

  override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
    if stack.isEmpty, Self.containsOnlyImports(node) {
      imports.append(node.trimmedDescription)
      return .skipChildren
    }
    return .visitChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    stack.append(.structDecl(name: node.name.text, isGeneric: node.genericParameterClause != nil))
    return .visitChildren
  }

  override func visitPost(_ node: StructDeclSyntax) {
    stack.removeLast()
  }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    stack.append(.classDecl(name: node.name.text, isGeneric: node.genericParameterClause != nil))
    return .visitChildren
  }

  override func visitPost(_ node: ClassDeclSyntax) {
    stack.removeLast()
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    stack.append(.other)
    return .visitChildren
  }

  override func visitPost(_ node: EnumDeclSyntax) {
    stack.removeLast()
  }

  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    stack.append(.other)
    return .visitChildren
  }

  override func visitPost(_ node: ActorDeclSyntax) {
    stack.removeLast()
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    stack.append(.other)
    return .visitChildren
  }

  override func visitPost(_ node: ExtensionDeclSyntax) {
    stack.removeLast()
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    let declaration: String
    let isGenericType: Bool
    let isStruct: Bool
    switch stack.last {
    case .structDecl(let name, let isGeneric):
      (declaration, isGenericType, isStruct) = (name, isGeneric, true)
    case .classDecl(let name, let isGeneric):
      (declaration, isGenericType, isStruct) = (name, isGeneric, false)
    default:
      return .skipChildren
    }
    guard node.bindings.count == 1,
      let binding = node.bindings.first,
      let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
      let returnType = binding.typeAnnotation?.type.trimmedDescription,
      let accessorBlock = binding.accessorBlock
    else { return .skipChildren }

    let isNested = stack.count > 1
    let startOffset = accessorBlock.positionAfterSkippingLeadingTrivia.utf8Offset
    let endOffset = accessorBlock.endPositionBeforeTrailingTrivia.utf8Offset

    if isStruct, name == "body" {
      guard case .getter(let statements) = accessorBlock.accessors else { return .skipChildren }
      rawUnits.append(
        ReloadableUnit(
          declaration: declaration,
          kind: .structBody,
          returnType: returnType,
          statements: statements.description,
          unsafetyReason: isNested ? "Nested declarations are not reloadable yet" : nil,
          startOffset: startOffset,
          endOffset: endOffset
        ))
      return .skipChildren
    }

    // Other get-only computed properties (`var sidebar: some View { ... }`,
    // `var title: String { get { ... } }`) on structs and classes.
    let statements: CodeBlockItemListSyntax
    switch accessorBlock.accessors {
    case .getter(let getter):
      statements = getter
    case .accessors(let accessors):
      guard accessors.count == 1, let getter = accessors.first,
        getter.accessorSpecifier.tokenKind == .keyword(.get),
        getter.effectSpecifiers == nil,
        let body = getter.body
      else { return .skipChildren }
      statements = body.statements
    }

    var prefixParts: [String] = []
    for element in node.attributes {
      if let attr = element.as(AttributeSyntax.self) {
        let attrName = attr.attributeName.trimmedDescription
        if attrName == "MainActor" || attrName == "ViewBuilder" {
          prefixParts.append(attr.trimmedDescription)
        }
      }
    }
    for modifier in node.modifiers {
      switch modifier.name.text {
      case "nonisolated": prefixParts.append("nonisolated")
      case "static", "class": prefixParts.append("static")
      default: break
      }
    }
    let replacementPrefix = prefixParts.isEmpty ? "" : prefixParts.joined(separator: " ") + " "

    var unsafetyReason: String?
    if isNested {
      unsafetyReason = "Nested declarations are not reloadable yet"
    } else if isGenericType {
      unsafetyReason = "Members of generic types require a rebuild"
    } else if (returnType == "some" || returnType.hasPrefix("some "))
      && returnType != "some View" && returnType != "some SwiftUI.View"
    {
      unsafetyReason = "Computed properties with opaque types other than some View require a rebuild"
    } else if Self.hasUnsupportedMethodAttribute(node.attributes) {
      unsafetyReason = "Computed properties with special runtime attributes require a rebuild"
    }

    rawUnits.append(
      ReloadableUnit(
        declaration: declaration,
        kind: .computedProperty(
          ComputedPropertyInfo(
            name: name,
            replacementPrefix: replacementPrefix,
            fullOriginalHeader:
              "\(node.attributes.trimmedDescription)|\(node.modifiers.trimmedDescription)|\(name)"
          )),
        returnType: returnType,
        statements: statements.description,
        unsafetyReason: unsafetyReason,
        startOffset: startOffset,
        endOffset: endOffset
      ))
    return .skipChildren
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    let declaration: String
    let isGenericClass: Bool
    let isStruct: Bool
    switch stack.last {
    case .classDecl(let name, let isGeneric):
      (declaration, isGenericClass, isStruct) = (name, isGeneric, false)
    case .structDecl(let name, let isGeneric):
      (declaration, isGenericClass, isStruct) = (name, isGeneric, true)
    default:
      return .skipChildren
    }
    guard let body = node.body else { return .skipChildren }

    let isNested = stack.count > 1
    let baseName = node.name.text
    let params = node.signature.parameterClause.parameters
    let targetLabels = params.map { "\($0.firstName.text):" }.joined()
    let dynamicTarget = params.isEmpty ? "\(baseName)()" : "\(baseName)(\(targetLabels))"

    let cleanedParams = FunctionParameterListSyntax(
      params.map { param in
        var copy = param
        if copy.defaultValue != nil {
          copy.type = copy.type.trimmed
          copy.defaultValue = nil
        }
        return copy
      }
    )
    var cleanedSig = node.signature
    cleanedSig.parameterClause.parameters = cleanedParams
    let cleanedSignatureText = cleanedSig.trimmedDescription

    let returnType = node.signature.returnClause?.type.trimmedDescription ?? "Void"

    var prefixParts: [String] = []
    for element in node.attributes {
      if let attr = element.as(AttributeSyntax.self) {
        let attrName = attr.attributeName.trimmedDescription
        if attrName == "MainActor" || attrName == "ViewBuilder" || attrName == "discardableResult" {
          prefixParts.append(attr.trimmedDescription)
        }
      }
    }
    for modifier in node.modifiers {
      let modText = modifier.name.text
      if modText == "nonisolated" {
        prefixParts.append("nonisolated")
      } else if modText == "static" || modText == "class" {
        prefixParts.append("static")
      } else if modText == "mutating" {
        prefixParts.append("mutating")
      }
    }
    let replacementPrefix = prefixParts.isEmpty ? "" : prefixParts.joined(separator: " ") + " "

    let fullOriginalHeader =
      "\(node.attributes.trimmedDescription)|\(node.modifiers.trimmedDescription)|\(node.name.text)|\(node.genericParameterClause?.trimmedDescription ?? "")|\(node.signature.trimmedDescription)|\(node.genericWhereClause?.trimmedDescription ?? "")"

    var unsafetyReason: String?
    if isNested {
      unsafetyReason = "Nested declarations are not reloadable yet"
    } else if isGenericClass {
      unsafetyReason = isStruct ? "Members of generic types require a rebuild" : "Generic classes require a rebuild"
    } else if node.genericParameterClause != nil || node.genericWhereClause != nil {
      unsafetyReason = "Generic class methods require a rebuild"
    } else if (returnType == "some" || returnType.hasPrefix("some "))
      && returnType != "some View" && returnType != "some SwiftUI.View"
    {
      unsafetyReason = "Class methods with opaque return types require a rebuild"
    } else if Self.hasUnsupportedMethodAttribute(node.attributes) {
      unsafetyReason = "Class methods with special runtime attributes require a rebuild"
    }

    let methodInfo = ClassMethodInfo(
      baseName: baseName,
      dynamicReplacementTarget: dynamicTarget,
      replacementPrefix: replacementPrefix,
      cleanedSignature: cleanedSignatureText,
      fullOriginalHeader: fullOriginalHeader
    )

    rawUnits.append(
      ReloadableUnit(
        declaration: declaration,
        kind: .classMethod(methodInfo),
        returnType: returnType,
        statements: body.statements.description,
        unsafetyReason: unsafetyReason,
        startOffset: body.positionAfterSkippingLeadingTrivia.utf8Offset,
        endOffset: body.endPositionBeforeTrailingTrivia.utf8Offset
      ))
    return .skipChildren
  }

  private static func hasUnsupportedMethodAttribute(_ attributes: AttributeListSyntax) -> Bool {
    for element in attributes {
      guard let attr = element.as(AttributeSyntax.self) else { continue }
      let name = attr.attributeName.trimmedDescription
      if name == "NSManaged" || name == "cdecl" || name == "_cdecl" {
        return true
      }
    }
    return false
  }

  private static func containsOnlyImports(_ node: IfConfigDeclSyntax) -> Bool {
    for clause in node.clauses {
      guard case .statements(let statements) = clause.elements else { return false }
      for item in statements {
        if item.item.is(ImportDeclSyntax.self) { continue }
        if let nestedIf = item.item.as(IfConfigDeclSyntax.self), containsOnlyImports(nestedIf) {
          continue
        }
        return false
      }
    }
    return true
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
