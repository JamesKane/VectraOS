// SPDX-License-Identifier: BSD-3-Clause

// The manual on the dev machine (D86): every page under man/<section>/,
// read with Guide, its index, and the backlog man/missing. `vx man` reads
// and checks it through here (Check.swift, Requirements.swift).

import FoundationEssentials
import Guide

/// A page read from the tree.
public struct ManualPage: Sendable {
  /// Relative to the root: `man/1/ls`.
  public var path: String
  public var page: Page
  /// The file's lines, as written, for the house rules.
  public var lines: [[UInt8]]
}

/// One row of the index (`lib/man/index`): a name a page documents, or a
/// node of a page.
public struct IndexRow: Sendable, Equatable {
  public var name: String
  public var page: String
  public var section: Int
  /// Empty for a name; the node's id for a node.
  public var node: String
  /// The page's summary, or the node's title.
  public var summary: String
  /// The page's keys, a space between; none for a node.
  public var keys: String = ""
}

public struct Manual: Sendable {
  public var pages: [ManualPage] = []
  /// Pages that don't parse: "path:line: message".
  public var refused: [String] = []
  public var missing: [MissingRow] = []

  public init() {}

  /// Reads `root`'s man/: each section's pages, and man/missing.
  public init(root: String) {
    let fm = FileManager.default
    for section in 1...8 {
      let dir = "\(root)/man/\(section)"
      guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
      for name in names.sorted() where !name.hasPrefix(".") {
        let path = "man/\(section)/\(name)"
        guard let data = fm.contents(atPath: "\(root)/\(path)") else { continue }
        add(path: path, bytes: Array(data))
      }
    }
    if let data = fm.contents(atPath: "\(root)/man/missing") {
      switch MissingRow.parse(Array(data), file: "man/missing") {
      case .success(let rows): missing = rows
      case .failure(let problem): refused.append(problem.description)
      }
    }
  }

  /// Adds one page, or its refusal.
  public mutating func add(path: String, bytes: [UInt8]) {
    do throws(GuideError) {
      let page = try Page(bytes, file: path)
      pages.append(ManualPage(path: path, page: page, lines: lines(bytes)))
    } catch {
      refused.append(error.description)
    }
  }

  /// The index: every name of every page, then its nodes, in page order.
  public var index: [IndexRow] {
    var rows: [IndexRow] = []
    for p in pages {
      let h = p.page.header
      for n in h.names {
        rows.append(IndexRow(name: n, page: h.page, section: h.section, node: "", summary: h.summary,
                             keys: h.keys.joined(separator: " ")))
      }
      for b in p.page.blocks where b.kind == .node {
        let id = String(decoding: b.node, as: UTF8.self)
        rows.append(IndexRow(name: id, page: h.page, section: h.section, node: id,
                             summary: String(decoding: b.title, as: UTF8.self)))
      }
    }
    return rows
  }

  /// The index as TSV, a header row first.
  public var indexTSV: String {
    var out = "name\tpage\tsection\tnode\tsummary\tkeys\n"
    for r in index { out += "\(r.name)\t\(r.page)\t\(r.section)\t\(r.node)\t\(r.summary)\t\(r.keys)\n" }
    return out
  }

  /// The page that documents `name`: in `section`, or the first section
  /// that has it.
  public func lookup(_ name: String, section: Int? = nil) -> ManualPage? {
    for s in section.map({ [$0] }) ?? Array(1...8) {
      for p in pages where p.page.header.section == s && p.page.header.names.contains(name) { return p }
    }
    return nil
  }
}

/// `bytes`' lines without their newlines, as written (a CR kept).
func lines(_ bytes: [UInt8]) -> [[UInt8]] {
  var out: [[UInt8]] = [], line: [UInt8] = []
  for b in bytes {
    if b == 0x0A {
      out.append(line)
      line = []
    } else {
      line.append(b)
    }
  }
  if !line.isEmpty { out.append(line) }
  return out
}
