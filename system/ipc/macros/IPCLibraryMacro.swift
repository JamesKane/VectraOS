// SPDX-License-Identifier: BSD-3-Clause

// @IPCLibrary: reads an enum holding a library's structs, enums and
// protocols, and generates each protocol's client, handler, server and
// event types, and the coders of its structs, as members of the enum
// (architecture §4, docs/wire-format.md).

import IPCModel
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main struct IPCMacrosPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [IPCLibraryMacro.self, MarkerMacro.self]
}

/// `@oneway`, `@event` and `@since(n)`: read by `@IPCLibrary`; they
/// generate nothing themselves.
public struct MarkerMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] { [] }
}

public struct IPCLibraryMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let library = declaration.as(EnumDeclSyntax.self) else {
      throw ModelError("@IPCLibrary applies to an enum")
    }
    return Generator(library: try LibraryModel(library, attribute: node)).declarations()
  }
}
