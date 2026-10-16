// SPDX-License-Identifier: BSD-3-Clause

// What @IPCLibrary refuses, and the message it gives.

import IPCMacros
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

let specs: [String: MacroSpec] = [
  "IPCLibrary": MacroSpec(type: IPCLibraryMacro.self),
  "oneway": MacroSpec(type: MarkerMacro.self),
  "event": MacroSpec(type: MarkerMacro.self),
  "since": MacroSpec(type: MarkerMacro.self),
]

/// Expands `members` inside an @IPCLibrary enum and expects one error.
func expectRefusal(_ members: String, _ message: String, header: String = #"id: "t", version: 1"#,
                   sourceLocation: SourceLocation = #_sourceLocation) {
  let source = "@IPCLibrary(\(header))\nenum L {\n\(members)\n}"
  // The marker attributes are macros too, and expand to nothing.
  let markers = #/@(oneway|event|since\(\d+\)) /#
  let expanded = "enum L {\n\(members.replacing(markers, with: ""))\n}"
  assertMacroExpansion(
    source, expandedSource: expanded,
    diagnostics: [DiagnosticSpec(message: message, line: 1, column: 1)],
    macroSpecs: specs, indentationWidth: .spaces(2),
    failureHandler: { Issue.record(Comment(rawValue: $0.message), sourceLocation: sourceLocation) })
}

/// The same, for members of a protocol P in the library.
func expectMethodRefusal(_ body: String, _ message: String, header: String = #"id: "t", version: 1"#,
                         sourceLocation: SourceLocation = #_sourceLocation) {
  expectRefusal("protocol P {\n\(body)\n}", message, header: header, sourceLocation: sourceLocation)
}

@Test func refusesUnsupportedTypes() {
  expectMethodRefusal("func f(_ x: Int)", "'f': parameter 'x': type 'Int' is not supported (declare it in the library)")
  expectMethodRefusal("func f() -> [Float]", "'f': the result: type 'Float' is not supported (declare it in the library)")
  expectMethodRefusal("func f(_ x: UInt8??)", "'f': parameter 'x': an optional of an optional isn't supported")
}

@Test func refusesUntypedThrowsAndAsync() {
  expectMethodRefusal("func f() throws", "'f': a throwing method declares its error type: throws(E)")
  expectMethodRefusal("func f() async", "'f': IPC methods are not async")
  expectMethodRefusal("func f() throws(E)", "'f': error type 'E' isn't an error enum of the library")
}

@Test func refusesBadMarkers() {
  expectMethodRefusal("@since(3) func f()", "'f': @since needs a version from 1 to 1")
  expectMethodRefusal("@oneway func f() -> UInt8", "'f': a one-way method or event has no result and doesn't throw")
  expectMethodRefusal("@event func f(_ h: Handle)", "'f': events can't carry handles yet")
}

@Test func refusesBadArguments() {
  expectMethodRefusal("func f()", "@IPCLibrary needs id: a string literal", header: #"id: "", version: 1"#)
  expectMethodRefusal("func f()", "@IPCLibrary needs version: an integer ≥ 1", header: #"id: "t", version: 0"#)
  expectMethodRefusal("var x: Int { get }", "protocol 'P' holds only methods")
  expectRefusal("typealias T = UInt8", "an IPC library holds only structs, enums and protocols")
}

@Test func refusesBadTypes() {
  expectRefusal("struct S {\n  var h: Handle\n}", "struct 'S' carries handles in 'h', so it must be ~Copyable")
  expectRefusal("struct S: ~Copyable {\n  var h: Handle\n}\nstruct T {\n  var v: [S]\n}",
                "'T.v': a vector's elements can't carry handles")
  expectRefusal("struct S {\n  var x: UInt8\n  init() {\n    x = 0\n  }\n}",
                "struct 'S': decoding uses the memberwise initializer, so declare others in an extension")
  expectRefusal("struct S {\n}", "struct 'S' has no stored properties")
  expectRefusal("enum K {\n  case a\n}", "enum 'K' needs an integer raw type")
  expectRefusal("enum K: UInt8 {\n  case a = 256\n}", "enum 'K': case 'a' doesn't fit in UInt8")
  expectRefusal("enum K: UInt8 {\n  case a(UInt8)\n}", "enum 'K': case 'a' can't carry values")
  expectRefusal("enum E: Int32, IPCErrorCode {\n  case a = 0\n}", "error enum 'E': case 'a' needs a positive code")
}
