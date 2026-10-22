// SPDX-License-Identifier: BSD-3-Clause

// @HotState's expansion (hotreload(2)): its size, its layout's hash, the
// image's exports and BitwiseCopyable.

import IPCMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

let hotSpecs: [String: MacroSpec] = ["HotState": MacroSpec(type: HotStateMacro.self, conformances: ["BitwiseCopyable"])]

@Test func hotStateExpands() {
  assertMacroExpansion(
    """
    @HotState
    struct S {
      var frame: Int
      var colour: UInt32 = 0
      var twice: Int { frame * 2 }
      static var shared = 0
    }
    """,
    expandedSource: """
      struct S {
        var frame: Int
        var colour: UInt32 = 0
        var twice: Int { frame * 2 }
        static var shared = 0

        static var hotStateSize: Int {
          MemoryLayout<Self>.size
        }

        static var hotStateHash: UInt64 {
          \(HotStateMacro.fnv("S{frame:Int;colour:UInt32;}"))
        }
      }

      @c public func hot_state_size() -> Int {
        S.hotStateSize
      }

      @c public func hot_state_hash() -> UInt64 {
        S.hotStateHash
      }

      extension S: BitwiseCopyable {
      }
      """,
    macroSpecs: hotSpecs, indentationWidth: .spaces(2),
    failureHandler: { Issue.record(Comment(rawValue: $0.message)) })
}

/// A field's type changed, or two fields swapped: another hash.
@Test func hotStateHashFollowsTheLayout() {
  let a = HotStateMacro.fnv("S{frame:Int;colour:UInt32;}")
  #expect(a != HotStateMacro.fnv("S{frame:Int;colour:UInt64;}"))
  #expect(a != HotStateMacro.fnv("S{colour:UInt32;frame:Int;}"))
}

@Test func hotStateRefusesAClass() {
  assertMacroExpansion(
    "@HotState\nclass C {}", expandedSource: "class C {}",
    diagnostics: [
      DiagnosticSpec(message: "@HotState applies to a struct", line: 1, column: 1),
      DiagnosticSpec(message: "@HotState applies to a struct", line: 1, column: 1),
      DiagnosticSpec(message: "@HotState applies to a struct", line: 1, column: 1),
    ],
    macroSpecs: hotSpecs, indentationWidth: .spaces(2),
    failureHandler: { Issue.record(Comment(rawValue: $0.message)) })
}
