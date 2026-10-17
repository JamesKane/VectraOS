// SPDX-License-Identifier: BSD-3-Clause

// man, lookman and sig (man(1), D86): the manual at /lib/man, read through
// the namespace as any files are. Pages are found through the index,
// /lib/man/index (`vx man --index`'s TSV: name, page, section, node,
// summary, keys), and read and refilled with Guide.

import Guide
import Node

extension Command {
  static let manual = "/lib/man"

  /// The index's rows: (name, page, section, node, summary, keys).
  func index() -> [[String]]? {
    guard let bytes = readAll(Self.manual + "/index") else { return nil }
    var rows: [[String]] = []
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n").dropFirst() {
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      if f.count == 6 { rows.append(f) }
    }
    return rows
  }

  /// A file's whole contents, or nil if it can't be read.
  func readAll(_ path: String) -> [UInt8]? {
    guard var n = try? ns.open(at(path)) else { return nil }
    var out: [UInt8] = []
    while true {
      guard let chunk = try? n.read(offset: UInt64(out.count), max: UInt32(NodeIPC.maxIO)) else { return nil }
      if chunk.isEmpty { return out }
      out += chunk
    }
  }

  /// The page that documents `name`: in the first of `sections` that has
  /// one, or of 1 to 8. (page, section)
  func find(_ name: String, in sections: [Int], _ rows: [[String]]) -> (String, Int)? {
    for s in sections.isEmpty ? Array(1...8) : sections {
      if let r = rows.first(where: { $0[0] == name && $0[3].isEmpty && $0[2] == String(s) }) { return (r[1], s) }
    }
    return nil
  }

  // MARK: man

  func man(_ args: [String]) -> String {
    let a = Flags(args)
    var rest = a.rest
    var sections: [Int] = []
    while rest.count > 1, let s = Int(rest[0]), (1...8).contains(s) {
      sections.append(s)
      rest.removeFirst()
    }
    guard a.unknown("tw") == nil, (1...2).contains(rest.count) else { return usage(Usage.man) }
    guard let rows = index() else { return fatal("no manual at \(Self.manual)") }
    guard let found = find(rest[0], in: sections, rows) else { return fatal("no manual page for \(rest[0])") }
    let (page, section) = found
    let path = "\(Self.manual)/\(section)/\(page)"
    if a.has("w") {
      io.out(Array((path + "\n").utf8))
      return ""
    }
    guard let bytes = readAll(path) else { return fatal("can't read \(path)") }
    let p: Page
    do throws(GuideError) {
      p = try Page(bytes, file: path)
    } catch {
      return fatal(error.description)
    }
    if a.has("t") {
      io.out(contents(p))
      return ""
    }
    do throws(GuideError) {
      io.out(try Render.text(p, node: rest.count == 2 ? Array(rest[1].utf8) : nil))
      return ""
    } catch {
      return fatal(error.description)
    }
  }

  /// A page's contents: its headings, and each node's id and title with
  /// its headings under it.
  func contents(_ p: Page) -> [UInt8] {
    var out: [UInt8] = []
    var indent: [UInt8] = []
    for b in p.blocks {
      switch b.kind {
      case .node:
        out += b.node + Array("  ".utf8) + b.title + [0x0A]
        indent = Array("     ".utf8)
      case .heading: out += indent + b.text + [0x0A]
      case .subheading: out += indent + Array("   ".utf8) + b.text + [0x0A]
      default: break
      }
    }
    return out
  }

  // MARK: lookman

  /// Every page whose names, summary or keys hold each key as a word, any
  /// case: a line each, the command that shows it.
  func lookman(_ args: [String]) -> String {
    guard !args.isEmpty else { return usage(Usage.lookman) }
    guard let rows = index() else { return fatal("no manual at \(Self.manual)") }
    func lower(_ s: String) -> [UInt8] { s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 } }
    func words(_ s: String) -> [[UInt8]] {
      lower(s).split { !(($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 >= 0x80 || $0 == 0x5F) }
        .map(Array.init)
    }
    var pages: [(page: String, section: String, summary: String, words: [[UInt8]])] = []
    for r in rows where r[3].isEmpty {
      let w = words(r[0]) + words(r[4]) + words(r[5])
      if let i = pages.firstIndex(where: { $0.page == r[1] && $0.section == r[2] }) {
        pages[i].words += w
      } else {
        pages.append((r[1], r[2], r[4], w))
      }
    }
    var found = false
    for p in pages where args.allSatisfy({ key in p.words.contains(lower(key)) }) {
      io.out(Array("man \(p.section) \(p.page) # \(p.summary)\n".utf8))
      found = true
    }
    return found ? "" : "no match"
  }

  // MARK: sig

  /// Each name's declarations, from the SYNOPSIS of the section 2 page
  /// that documents it.
  func sig(_ args: [String]) -> String {
    guard !args.isEmpty else { return usage(Usage.sig) }
    guard let rows = index() else { return fatal("no manual at \(Self.manual)") }
    var failed = ""
    for name in args {
      guard let page = find(name, in: [2], rows)?.0, let bytes = readAll("\(Self.manual)/2/\(page)"),
        let p = try? Page(bytes, file: page)
      else {
        failed = complainAbout(name)
        continue
      }
      let short = Array((name.split(separator: ".").last.map(String.init) ?? name).utf8)
      var synopsis = false
      var lines: [[UInt8]] = []
      for b in p.blocks {
        if b.kind == .heading || b.kind == .node { synopsis = b.kind == .heading && b.text == Array("SYNOPSIS".utf8) }
        guard synopsis, b.kind == .fence, b.fence == .swift || b.fence == .c else { continue }
        for l in b.text.split(separator: 0x0A) where declares(Array(l), short) { lines.append(Array(l)) }
      }
      if lines.isEmpty {
        failed = complainAbout(name)
        continue
      }
      for l in lines { io.out(l + [0x0A]) }
    }
    return failed
  }

  func complainAbout(_ name: String) -> String {
    complain("sig: no declaration of \(name)")
    return "no declaration"
  }

  /// Whether `line` holds `name` as a word, not part of a longer one.
  func declares(_ line: [UInt8], _ name: [UInt8]) -> Bool {
    func ident(_ c: UInt8) -> Bool {
      (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
    }
    guard !name.isEmpty, line.count >= name.count else { return false }
    for i in 0...(line.count - name.count) where Array(line[i..<(i + name.count)]) == name {
      let before = i == 0 || !ident(line[i - 1])
      let after = i + name.count == line.count || !ident(line[i + name.count])
      if before && after { return true }
    }
    return false
  }
}
