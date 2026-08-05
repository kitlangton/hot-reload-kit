import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct HotReloadableMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let declaration = declaration.as(StructDeclSyntax.self) else {
      throw HotReloadMacroError.onlyStructs
    }
    let name = declaration.name.text
    return [
      DeclSyntax(
        stringLiteral: """
          #if DEBUG
          @SwiftUI.ObservedObject private var __hotReload = HotReloadRuntime.observer(for: "\(name)")
          #endif
          """)
    ]
  }
}

private enum HotReloadMacroError: Error, CustomStringConvertible {
  case onlyStructs

  var description: String {
    "@HotReloadable can only be applied to a struct"
  }
}

@main
struct HotReloadPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [HotReloadableMacro.self]
}
