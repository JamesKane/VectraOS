// SPDX-License-Identifier: BSD-3-Clause

// vx man --check (D86): the manual against itself and against the code.
//
// - Every page parses, lives at man/<section>/<page>, and keeps the house
//   rules: no trailing spaces, no tabs outside fences, fences within 80
//   columns, headings in capitals and Plan 9's in Plan 9's order.
//   No two pages give one name in one section.
// - Every link resolves: to a page through the index, to a node of it, or
//   to a page man/missing promises.
// - Everything that needs a page (Requirements) has one, or a row in
//   man/missing; no row is for something that has a page or needs none.
// - A format's page defines every directive in its table.
// - Each generated file of usage messages is what the pages say.

import HostSystem
import Guide

/// Plan 9's headings, in Plan 9's order.
let plan9Headings = ["SYNOPSIS", "DESCRIPTION", "EXAMPLES", "FILES", "SEE ALSO", "DIAGNOSTICS", "BUGS"]

public enum Check {
  /// Every problem, "where: what", in the order found.
  public static func run(_ manual: Manual, requirements: [Requirement], root: String,
                         usage: [UsageFile] = usageFiles) -> [String] {
    var problems = manual.refused
    let index = manual.index
    for p in manual.pages {
      problems += house(p)
      let h = p.page.header
      if p.path != "man/\(h.section)/\(h.page)" {
        problems.append("\(p.path): its header says \(h.page)(\(h.section)), so it belongs at man/\(h.section)/\(h.page)")
      }
    }
    var seen: [(String, Int, String)] = []
    for r in index where r.node.isEmpty {
      if let other = seen.first(where: { $0.0 == r.name && $0.1 == r.section }) {
        problems.append("\(r.page)(\(r.section)): '\(r.name)' is also \(other.2)(\(r.section))'s")
      }
      seen.append((r.name, r.section, r.page))
    }
    for p in manual.pages { problems += links(p, manual: manual) }

    func documented(_ r: Requirement) -> Bool {
      index.contains { $0.node.isEmpty && $0.name == r.pageName && r.sections.contains($0.section) }
    }
    for r in requirements where !documented(r) && !manual.missing.contains(where: { $0.requirement == r }) {
      let sections = r.sections.map(String.init).joined(separator: ", ")
      problems.append("no page for \(r.kind.rawValue) \(r.name) (section \(sections)), and no row in man/missing")
    }
    for m in manual.missing {
      if documented(m.requirement) {
        problems.append("man/missing:\(m.line): \(m.requirement.kind.rawValue) \(m.requirement.name) has a page now; take its row out")
      } else if !requirements.contains(m.requirement) {
        problems.append("man/missing:\(m.line): \(m.requirement.kind.rawValue) \(m.requirement.name) needs no page; take its row out")
      }
    }
    for f in directiveFormats {
      guard let p = manual.lookup(f.name, section: 6) else { continue }
      let terms = p.page.blocks.filter { $0.kind == .definition }.map { String(decoding: $0.text, as: UTF8.self) }
      let source = Requirements.read(root, f.source)
      for d in Requirements.directives(source) where !terms.contains("`\(d)`") {
        problems.append("\(p.path): no definition of `\(d)`, a directive in \(f.source)")
      }
    }
    for u in usage {
      let commands = Requirements.strings(named: "names", in: Requirements.read(root, u.commands))
      switch UsageMessages.swift(manual, commands: commands) {
      case .failure(let m):
        for n in m.names { problems.append("\(u.path): no section 1 page with a usage fence for \(n)") }
      case .success(let text):
        if Requirements.read(root, u.path) != text {
          problems.append("\(u.path): not what the pages say; vx man --usage writes it")
        }
      }
    }
    return problems
  }

  /// The house rules, line by line, and the headings.
  static func house(_ p: ManualPage) -> [String] {
    var out: [String] = []
    var fenced = false
    for (i, l) in p.lines.enumerated() {
      let at = "\(p.path):\(i + 1)"
      let isFence = l.count >= 3 && l[0] == 0x60 && l[1] == 0x60 && l[2] == 0x60
      if let last = l.last, last == 0x20 || last == 0x09 || last == 0x0D { out.append("\(at): a trailing space") }
      if fenced && !isFence {
        if columns(l) > 80 { out.append("\(at): a fence's line past 80 columns") }
      } else if l.contains(0x09) {
        out.append("\(at): a tab outside a fence")
      }
      if isFence { fenced = !fenced }
    }
    var order = -1
    for b in p.page.blocks {
      if b.kind == .node { order = -1 }
      guard b.kind == .heading else { continue }
      let text = String(decoding: b.text, as: UTF8.self)
      if b.text.contains(where: { $0 >= 0x61 && $0 <= 0x7A }) {
        out.append("\(p.path):\(b.line): a heading is in capitals")
      }
      guard let k = plan9Headings.firstIndex(of: text) else { continue }
      if k <= order { out.append("\(p.path):\(b.line): \(text) out of Plan 9's order (\(plan9Headings.joined(separator: ", ")))") }
      order = k
    }
    return out
  }

  /// Every reference and link target in a page, resolved.
  static func links(_ p: ManualPage, manual: Manual) -> [String] {
    var out: [String] = []
    let nodes = p.page.blocks.filter { $0.kind == .node }.map(\.node)
    func resolve(_ target: [UInt8], line: Int) {
      let t = String(decoding: target, as: UTF8.self)
      if t.hasPrefix("https:") || t.hasPrefix("gemini:") || t.hasPrefix("gopher:") { return }
      if t.hasPrefix("#") {
        if !nodes.contains(Array(target.dropFirst())) { out.append("\(p.path):\(line): no node '\(t)' in this page") }
        return
      }
      guard let open = t.firstIndex(of: "("), let section = Int(String(t[t.index(after: open)])) else { return }
      let name = String(t[..<open])
      let node = t.firstIndex(of: "#").map { String(t[t.index(after: $0)...]) }
      if let target = manual.lookup(name, section: section) {
        if let node, !target.page.blocks.contains(where: { $0.kind == .node && $0.node == Array(node.utf8) }) {
          out.append("\(p.path):\(line): \(name)(\(section)) has no node '\(node)'")
        }
      } else if node == nil,
        manual.missing.contains(where: { $0.requirement.pageName == name && $0.requirement.sections.contains(section) }) {
        return  // a page the list promises
      } else {
        out.append("\(p.path):\(line): \(t) is no page")
      }
    }
    for b in p.page.blocks {
      var texts: [[UInt8]] = []
      switch b.kind {
      case .heading, .subheading, .paragraph, .item: texts = [b.text]
      case .definition: texts = [b.text, b.body]
      case .row: texts = Inline.cells(b.text)
      case .node, .fence: break
      }
      for text in texts {
        for s in (try? Inline.spans(text)) ?? [] {
          if s.kind == .reference { resolve(s.text, line: b.line) }
          if s.kind == .link { resolve(s.target, line: b.line) }
        }
      }
    }
    return out
  }
}

/// Columns: one per character.
func columns(_ s: [UInt8]) -> Int { s.count { $0 & 0xC0 != 0x80 } }
