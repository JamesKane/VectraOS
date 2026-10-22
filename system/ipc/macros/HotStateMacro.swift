// SPDX-License-Identifier: BSD-3-Clause

// @HotState (hotreload(2), D122): a hot reloaded program's state type, kept
// in the state block across reloads. It must be data alone, so it is made
// BitwiseCopyable (the compiler refuses a class, a closure or an
// existential in it), and it gets its size and a layout hash: FNV-1a over
// its name and each stored property's name and type as written, in order.
// The image exports both (`hot_state_size`, `hot_state_hash`), and the host
// refuses an image whose hash differs from the block's.

import SwiftSyntax
import SwiftSyntaxMacros

public struct HotStateMacro: MemberMacro, ExtensionMacro, PeerMacro {
  struct Refusal: Error, CustomStringConvertible {
    let description: String
  }

  /// The struct's name and its layout as text: `Name{a:Int;b:UInt32;}`.
  static func layout(_ declaration: some SyntaxProtocol) throws -> (name: String, text: String) {
    guard let s = declaration.as(StructDeclSyntax.self) else { throw Refusal(description: "@HotState applies to a struct") }
    var text = s.name.text + "{"
    for member in s.memberBlock.members {
      guard let v = member.decl.as(VariableDeclSyntax.self),
        !v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
      else { continue }
      for binding in v.bindings {
        // A computed property holds nothing.
        if let accessors = binding.accessorBlock {
          if case .getter = accessors.accessors { continue }
          if case .accessors(let list) = accessors.accessors,
            list.contains(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) })
          {
            continue
          }
        }
        guard let type = binding.typeAnnotation?.type else {
          throw Refusal(description: "@HotState: '\(binding.pattern.trimmedDescription)' needs its type written")
        }
        text += binding.pattern.trimmedDescription + ":" + type.trimmedDescription + ";"
      }
    }
    return (s.name.text, text + "}")
  }

  public static func fnv(_ text: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in text.utf8 {
      h ^= UInt64(b)
      h = h &* 0x100_0000_01b3
    }
    return h
  }

  public static func expansion(
    of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let l = try layout(declaration)
    return [
      "static var hotStateSize: Int { MemoryLayout<Self>.size }",
      "static var hotStateHash: UInt64 { \(raw: String(fnv(l.text))) }",
    ]
  }

  public static func expansion(
    of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    _ = try layout(declaration)
    return [try ExtensionDeclSyntax("extension \(type.trimmed): BitwiseCopyable {}")]
  }

  public static func expansion(
    of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let l = try layout(declaration)
    return [
      "@c public func hot_state_size() -> Int { \(raw: l.name).hotStateSize }",
      "@c public func hot_state_hash() -> UInt64 { \(raw: l.name).hotStateHash }",
    ]
  }
}
