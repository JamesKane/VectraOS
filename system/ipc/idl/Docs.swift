// SPDX-License-Identifier: BSD-3-Clause

// A protocol's page of the manual, section 5, in guide (guide(6), D86):
// its methods, their ordinals, the layout of each message, and the
// structs, unions, enums and errors they use, from the same model the code
// comes from, with the declarations' `///` comments as its prose.

import IPCModel

/// The page's name: the protocol's id after its first part, lower case,
/// a `-` for each `.`; `todhchai.pty.Control` is `pty-control`, and a
/// protocol named as its library, `todhchai.node.Node`, is `node`.
public func manPageName(_ p: ProtocolModel) -> String {
  var parts = p.id.split(separator: ".").dropFirst().map { $0.lowercased() }
  if parts.count == 2 && parts[0] == parts[1] { parts.removeLast() }
  return parts.joined(separator: "-")
}

public func manPage(_ p: ProtocolModel, _ library: LibraryModel, source: String,
                    composed: [Interface.ComposedMethod] = []) -> String {
  let types = library.types
  func kind(_ k: MethodKind) -> String {
    switch k {
    case .call: "call"
    case .oneway: "one-way"
    case .event: "event"
    }
  }
  // A signature past the manual's 80 columns (vx man --check) goes on:
  // its throws and result on a second line, then its parameters a line
  // each.
  func signature(_ m: Method) -> String {
    let named = m.parameters.map { "\($0.name): \($0.type.swiftName)" }
    let result = m.result.map { " -> \($0.type.swiftName)" } ?? ""
    let error = m.errorType.map { " throws(\($0))" } ?? ""
    let head = "\(kind(m.kind)) \(m.name)(\(named.joined(separator: ", ")))"
    let tail = String((error + result).drop { $0 == " " })
    if head.count + error.count + result.count <= 80 { return head + error + result }
    if head.count <= 80 { return head + "\n  " + tail }
    return "\(kind(m.kind)) \(m.name)(\n" + named.map { "    " + $0 }.joined(separator: ",\n") + "\n)" + error + result
  }
  var out = """
    page \(manPageName(p)) 5
    summary the \(p.id) protocol
    names \(manPageName(p)) \(p.id)
    src \(source)

    # SYNOPSIS

    ```text
    protocol \(p.id) version \(p.version)

    """
  for m in p.methods { out += signature(m) + "\n" }
  out += "```\n\n# DESCRIPTION\n\n"
  if !p.doc.isEmpty { out += p.doc + "\n\n" }
  out += "Protocol `\(p.id)`, version \(p.version), of library `\(library.name)`, "
    + "its messages in the one wire format (wire(6)).\n\n"
  out += "| Method | Kind | Since | Ordinal |\n"  // the signatures are SYNOPSIS's
  for m in p.methods { out += "| `\(m.name)` | \(kind(m.kind)) | \(m.since) | `\(hex(m.ordinal))` |\n" }
  if !composed.isEmpty {
    let ids = composed.map(\.origin.id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    out += "\nIt composes \(ids.map { "`\($0)`" }.joined(separator: ", ")): their methods are its methods, with "
      + "their own ordinals, and are described with their protocols.\n\n| Method | From | Kind | Ordinal |\n"
    for c in composed {
      out += "| `\(c.method.name)` | `\(c.origin.id)` | \(kind(c.method.kind)) | `\(hex(c.method.ordinal))` |\n"
    }
  }
  let described = p.methods.filter { !$0.doc.isEmpty }
  if !described.isEmpty { out += "\n" }
  for m in described { out += ": `\(m.name)`\n" + indented(m.doc) }

  out += "\n@node layouts Message layouts\n"
  for m in p.methods {
    out += "\n## \(m.name)\n\n"
    out += layoutTable(m.kind == .event ? "Event body" : "Request body", m.request, types)
    if m.kind == .call { out += "\n" + layoutTable("Reply body", m.reply, types) }
  }
  let used = p.used(types)
  let thrown = p.methods.compactMap(\.errorType).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
  guard !used.structs.isEmpty || !used.unions.isEmpty || !used.enums.isEmpty || !thrown.isEmpty else { return out }
  out += "\n@node types Types\n"
  for s in used.structs {
    out += "\n## struct \(s.name)\n\n" + (s.doc.isEmpty ? "" : s.doc + "\n\n")
      + layoutTable("\(s.isCopyable ? "" : "Moves (carries handles); ")aligned to \(s.alignment)", s.layout, types)
  }
  for u in used.unions {
    out += "\n## union \(u.name)\n\n"
    if !u.doc.isEmpty { out += u.doc + "\n\n" }
    out += "16 bytes inline: the tag (UInt64), then a box's presence marker; the case's "
    out += "values out of line, absent for a case that carries none. Receivers reject other tags.\n\n"
    out += "| Tag | Case |\n"
    for c in u.cases { out += "| \(c.tag) | `\(c.name)` |\n" }
    for c in u.cases where !c.values.isEmpty {
      out += "\n" + layoutTable("`\(c.name)`'s values", c.layout, types)
    }
  }
  for e in used.enums {
    out += "\n## enum \(e.name)\n\n" + (e.doc.isEmpty ? "" : e.doc + "\n\n")
      + "\(e.rawType); receivers reject other values.\n\n| Case | Value |\n"
    for c in e.cases { out += "| `\(c.name)` | \(c.value) |\n" }
  }
  for name in thrown {
    guard let e = library.errors.first(where: { $0.name == name }) else { continue }
    out += "\n## errors \(name)\n\n| Case | Code |\n"
    for c in e.cases { out += "| `\(c.name)` | \(c.code) |\n" }
  }
  return out
}

/// A doc comment as a definition's description: each line after two spaces.
func indented(_ doc: String) -> String {
  doc.split(separator: "\n", omittingEmptySubsequences: true).map { "  " + $0 + "\n" }.joined()
}

/// How a value of `t` is stored, for the layout tables: what is out of
/// line or aside; counts and presence markers are wire(6)'s.
func storage(_ t: WireType, _ types: Types) -> String {
  switch t {
  case .integer, .bool: return ""
  case .string, .bytes: return " (bytes out of line)"
  case .vector(let e): return " (\(types.size(e))-byte elements out of line)"
  case .handle: return " (in the handle array)"
  case .enumeration(let n): return " (\(types.enumeration(n)?.rawType ?? "?"))"
  case .structure: return " (inline)"
  case .union: return " (its case's values out of line)"
  case .optional(let w): return w.hasOwnPresence ? storage(w, types) + ", absent: zero" : " (boxed out of line)"
  }
}

func layoutTable(_ title: String, _ layout: Layout, _ types: Types) -> String {
  guard !layout.fields.isEmpty else { return "\(title): empty.\n" }
  var out = "\(title), \(layout.size) bytes inline:\n\n| Offset | Size | Field | Type |\n"
  for f in layout.fields {
    let name = f.name == "r" ? "result" : f.name.hasPrefix("a_") ? String(f.name.dropFirst(2)) : f.name
    out += "| \(f.offset) | \(f.size) | `\(name)` | \(f.type.swiftName)\(storage(f.type, types)) |\n"
  }
  return out
}
