// SPDX-License-Identifier: BSD-3-Clause

// man/missing (D86): what has no page yet, a TSV row each, `kind` then
// `name`; `#` starts a comment line. The check fails on anything
// undocumented that isn't here, and on anything here that now has a page
// or no longer needs one, so the list only shrinks.

/// What needs a page, and the sections it may be in.
public enum Kind: String, Sendable, CaseIterable {
  /// A program in bootfs's bin/: a command, a service's or a driver's.
  case program
  /// A tool on the dev machine: vx and its commands, SwiftPM's executables.
  case host
  case syscall
  /// A public declaration of Sys.
  case sys
  /// A function a libc header declares.
  case libc
  /// An IDL protocol.
  case `protocol`
  /// A service a manifest names.
  case service
  /// A driver a `driver.manifest` names.
  case driver
  /// A file format.
  case format
  /// A section's intro page, its name the section.
  case intro

  public var sections: [Int] {
    switch self {
    case .program: [1, 3, 4, 8]
    case .host: [1, 8]
    case .syscall, .sys, .libc: [2]
    case .protocol: [5]
    case .service: [4, 8]
    case .driver: [3]
    case .format: [6]
    case .intro: []
    }
  }
}

/// A thing that needs a page.
public struct Requirement: Sendable, Equatable {
  public var kind: Kind
  public var name: String

  public init(_ kind: Kind, _ name: String) {
    self.kind = kind
    self.name = name
  }

  /// The sections its page may be in, and the name the page must give.
  public var sections: [Int] { kind == .intro ? [Int(name) ?? 0] : kind.sections }
  public var pageName: String { kind == .intro ? "intro" : name }
}

public struct MissingRow: Sendable, Equatable {
  public var requirement: Requirement
  public var line: Int

  public struct Problem: Error, CustomStringConvertible {
    public let description: String
  }

  public static func parse(_ bytes: [UInt8], file: String) -> Result<[MissingRow], Problem> {
    var rows: [MissingRow] = []
    for (i, raw) in lines(bytes).enumerated() {
      let line = String(decoding: raw, as: UTF8.self)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 2, let kind = Kind(rawValue: String(fields[0])), !fields[1].isEmpty else {
        return .failure(Problem(description: "\(file):\(i + 1): a row is a kind and a name, a tab between"))
      }
      let r = MissingRow(requirement: Requirement(kind, String(fields[1])), line: i + 1)
      if rows.contains(where: { $0.requirement == r.requirement }) {
        return .failure(Problem(description: "\(file):\(i + 1): \(kind.rawValue) \(fields[1]) listed twice"))
      }
      rows.append(r)
    }
    return .success(rows)
  }

  /// The list for `requirements`, with its comment: what `vx man --missing` prints.
  public static func tsv(_ requirements: [Requirement]) -> String {
    var out = """
      # man/missing: what has no page yet (D86). A row is a kind and a name,
      # a tab between. vx man --check fails on anything undocumented that
      # isn't here, and on anything here that now has a page or no longer
      # needs one, so the list only shrinks: a change that adds something
      # adds its page, not a row.

      """
    for r in requirements { out += "\(r.kind.rawValue)\t\(r.name)\n" }
    return out
  }
}
