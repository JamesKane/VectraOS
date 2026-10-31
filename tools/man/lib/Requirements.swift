// SPDX-License-Identifier: BSD-3-Clause

// What needs a page (D86), found in the tree: bootfs's programs (from
// built images), vx's commands and SwiftPM's executables, the syscalls,
// Sys's public declarations, libc's functions, the IDL protocols, the
// services and drivers the manifests name, the formats, and the intros.

import HostSystem
import SwiftParser
import SwiftSyntax

/// The boot's own tests: programs, services and drivers that check the
/// system rather than serve it. They need no page.
public let tests = [
  "m2", "sys-test", "dl-test", "link-test", "link-stale", "trace-test", "ipc-test", "node-test", "acpi-test", "irq-test", "pci-test", "launch-service",
  "launch-test", "a", "b", "edu", "floor-hello", "cxx-hello", "swift-hello", "swift-start", "swift-async",
  "foundation-test", "node-test-t1", "fdio-test", "spawn-test", "warmboot-test", "desktop-test", "sdk-test", "minimal", "kit-test",
  "rio-test", "vt-test", "tracker-test", "peer-bench", "hello-static", "hello-linked",
]

/// A format with a directive table: its page must define every directive.
public struct DirectiveFormat: Sendable {
  public var name: String
  /// The file whose `static let directives` is the table.
  public var source: String
}

public let directiveFormats = [
  DirectiveFormat(name: "manifest", source: "system/launch/lib/Manifest.swift"),
  DirectiveFormat(name: "driver", source: "drivers/devmgr/lib/Index.swift"),
  DirectiveFormat(name: "guide", source: "system/guide/lib/Page.swift"),
]

/// Formats with no directive table: the wire format, the trace format,
/// the boot image.
public let otherFormats = ["wire", "trace", "bootfs"]

public enum Requirements {
  /// Everything that needs a page. `files` are the tree's tracked paths,
  /// `bootfs` the file names of each built boot image (none: programs
  /// aren't required).
  public static func all(root: String, files: [String], bootfs: [[String]]) -> [Requirement] {
    var out: [Requirement] = []
    func add(_ r: Requirement) {
      if !tests.contains(r.name) && !out.contains(r) { out.append(r) }
    }
    for names in bootfs {
      for n in names where n.hasPrefix("bin/") { add(Requirement(.program, String(n.dropFirst(4)))) }
    }
    for n in hostTools(root: root) { add(Requirement(.host, n)) }
    for n in syscalls(read(root, "user/include/croi/syscall.h")) { add(Requirement(.syscall, n)) }
    for f in files where f.hasPrefix("system/sys/api/") && f.hasSuffix(".swift") {
      // A top-level function or variable is named as `Sys.close`: libc's
      // close shares section 2.
      for n in publicNames(read(root, f)) {
        let top = !n.contains(".") && n.first.map { $0.isLowercase } == true
        add(Requirement(.sys, top ? "Sys." + n : n))
      }
    }
    for f in files where f.hasPrefix("system/libc/include/") && f.hasSuffix(".h") {
      for n in cFunctions(read(root, f)) { add(Requirement(.libc, n)) }
    }
    for f in files where f.hasSuffix(".api") {
      for line in read(root, f).split(separator: "\n") where line.hasPrefix("protocol ") {
        let id = line.split(separator: " ")[1]
        if !id.contains(".test.") { add(Requirement(.protocol, String(id))) }
      }
    }
    for f in files where f.hasSuffix(".manifest") || f.hasSuffix(".manifest.in") {
      let directive = f.hasSuffix("driver.manifest") ? "driver" : "service"
      for line in read(root, f).split(separator: "\n") {
        let w = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if w.count >= 2, w[0] == directive {
          add(Requirement(directive == "driver" ? .driver : .service, String(w[1])))
        }
      }
    }
    for f in directiveFormats { add(Requirement(.format, f.name)) }
    for f in otherFormats { add(Requirement(.format, f)) }
    for s in 1...8 { add(Requirement(.intro, "\(s)")) }
    return out
  }

  /// A file of the tree, as text; empty if it can't be read.
  public static func read(_ root: String, _ path: String) -> String {
    FileManager.default.contents(atPath: "\(root)/\(path)").map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  /// vx, its commands (`vx-NAME`, from main.swift's `case "NAME":`) and
  /// SwiftPM's other executables.
  static func hostTools(root: String) -> [String] {
    var out = ["vx"]
    for line in read(root, "tools/vx/main.swift").split(separator: "\n") where line.hasPrefix("case \"") {
      for c in line.dropFirst(5).split(separator: ",") {
        let name = trimmed(c)
        guard name.hasPrefix("\""), let end = name.dropFirst().firstIndex(of: "\"") else { continue }
        out.append("vx-" + name[name.index(after: name.startIndex)..<end])
      }
    }
    for line in read(root, "Package.swift").split(separator: "\n") {
      guard let r = line.firstRange(of: ".executableTarget(name: \"") else { continue }
      let name = line[r.upperBound...].prefix { $0 != "\"" }
      if name != "vx" { out.append(String(name)) }
    }
    return out
  }

  /// The calls syscall.h numbers, `CROI_SYS_NAME = N,`, as `name`.
  static func syscalls(_ header: String) -> [String] {
    var out: [String] = []
    for line in header.split(separator: "\n") {
      let t = line.drop { $0 == " " }
      guard t.hasPrefix("CROI_SYS_"), t.contains("=") else { continue }
      let name = t.dropFirst(9).prefix { $0 != " " && $0 != "=" }
      out.append(name.lowercased())
    }
    return out
  }

  /// A Swift file's public declarations: types, functions and properties
  /// at the top, and their public members as `Type.member`.
  public static func publicNames(_ source: String) -> [String] {
    var out: [String] = []
    func isPublic(_ m: DeclModifierListSyntax) -> Bool {
      m.contains { $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open) }
    }
    func members(_ list: MemberBlockItemListSyntax, of type: String, publicByDefault: Bool) {
      for item in list { visit(item.decl, prefix: type + ".", publicByDefault: publicByDefault) }
    }
    func visit(_ decl: DeclSyntax, prefix: String, publicByDefault: Bool = false) {
      if let d = decl.as(StructDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        out.append(prefix + d.name.text)
        members(d.memberBlock.members, of: prefix + d.name.text, publicByDefault: false)
      } else if let d = decl.as(EnumDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        out.append(prefix + d.name.text)
        members(d.memberBlock.members, of: prefix + d.name.text, publicByDefault: false)
      } else if let d = decl.as(ClassDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        out.append(prefix + d.name.text)
        members(d.memberBlock.members, of: prefix + d.name.text, publicByDefault: false)
      } else if let d = decl.as(ProtocolDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        out.append(prefix + d.name.text)
      } else if let d = decl.as(TypeAliasDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        out.append(prefix + d.name.text)
      } else if let d = decl.as(FunctionDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        if case .identifier(let name) = d.name.tokenKind { out.append(prefix + name) }
      } else if let d = decl.as(InitializerDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        if !prefix.isEmpty { out.append(prefix + "init") }
      } else if let d = decl.as(VariableDeclSyntax.self), publicByDefault || isPublic(d.modifiers) {
        for b in d.bindings {
          if let p = b.pattern.as(IdentifierPatternSyntax.self) { out.append(prefix + p.identifier.text) }
        }
      } else if let d = decl.as(ExtensionDeclSyntax.self) {
        let type = d.extendedType.trimmedDescription
        members(d.memberBlock.members, of: prefix + type, publicByDefault: isPublic(d.modifiers))
      }
    }
    for item in Parser.parse(source: source).statements {
      if let d = item.item.as(DeclSyntax.self) { visit(d, prefix: "") }
    }
    var unique: [String] = []
    for n in out where !unique.contains(n) { unique.append(n) }
    return unique
  }

  /// The functions a C header declares at file scope: `TYPE name(ARGS);`,
  /// outside comments, preprocessor lines, typedefs and braces.
  public static func cFunctions(_ header: String) -> [String] {
    var text = ""
    var i = header.startIndex
    while i < header.endIndex {  // comments out
      if header[i...].hasPrefix("/*") {
        i = header[i...].firstRange(of: "*/")?.upperBound ?? header.endIndex
        text += " "
      } else if header[i...].hasPrefix("//") {
        i = header[i...].firstIndex(of: "\n") ?? header.endIndex
      } else {
        text.append(header[i])
        i = header.index(after: i)
      }
    }
    var out: [String] = []
    var depth = 0
    var statement = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let t = trimmed(line)
      if t.hasPrefix("#") || t.hasPrefix("extern \"C\"") { continue }
      for c in t {
        if c == "{" { depth += 1 }
        if c == "}" { depth = max(depth - 1, 0) }
      }
      guard depth == 0, !t.contains("{"), !t.contains("}") else {
        statement = ""
        continue
      }
      statement += " " + t
      guard statement.hasSuffix(";") else { continue }
      defer { statement = "" }
      var s = trimmed(statement)
      while let r = s.firstRange(of: "__attribute__((") {  // its balanced parentheses out
        var depth = 2, j = r.upperBound
        while j < s.endIndex && depth > 0 {
          if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1 }
          j = s.index(after: j)
        }
        s.removeSubrange(r.lowerBound..<j)
      }
      guard !s.hasPrefix("typedef"), let paren = s.firstIndex(of: "("), s[s.index(after: paren)...].first != "*"
      else { continue }
      let name = s[..<paren].reversed().drop { $0 == " " }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      let n = String(name.reversed())
      if !n.isEmpty && !n.hasPrefix("__") { out.append(n) }  // __: the libc's own
    }
    return out
  }

  /// A format's directive table: the strings of the file's `static let
  /// directives` array.
  public static func directives(_ source: String) -> [String] { strings(named: "directives", in: source) }

  /// The strings of the array literal a file's `let NAME` holds.
  public static func strings(named name: String, in source: String) -> [String] {
    var out: [String] = []
    final class Finder: SyntaxVisitor {
      let name: String
      var found: [String] = []
      init(_ name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
      }
      override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for b in node.bindings where b.pattern.trimmedDescription == name {
          guard let array = b.initializer?.value.as(ArrayExprSyntax.self) else { continue }
          for e in array.elements {
            if let s = e.expression.as(StringLiteralExprSyntax.self) { found.append(s.segments.trimmedDescription) }
          }
        }
        return .skipChildren
      }
    }
    let f = Finder(name)
    f.walk(Parser.parse(source: source))
    out = f.found
    return out
  }
}

/// `s` without its leading and trailing spaces and tabs.
func trimmed<S: StringProtocol>(_ s: S) -> String {
  String(s.drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
}
