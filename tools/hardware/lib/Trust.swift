// SPDX-License-Identifier: BSD-3-Clause

// A board's trusted base (D168): the drivers whose DMA the kernel doesn't
// translate, and the SMC ranges a board rule grants. trust.tsv names them
// per board, each with its reason; the drivers' records (`own-mmu`) and
// support.tsv's IOMMU components are what it is checked and printed
// against. Pure, so the rules are tested hosted (HardwareTests).

/// One row of trust.tsv.
public struct TrustRow: Equatable, Sendable {
  /// What makes a driver's DMA untranslated, or an SMC grant's calls
  /// not take addresses.
  public enum Kind: String, Sendable { case driver, smc }

  public var line: Int
  public var board: String
  public var kind: Kind
  /// A driver's program name, or an SMC function id as `0x` and hex.
  public var subject: String
  /// `own-mmu` or `no-iommu` for a driver; `addresses` or `no-addresses`
  /// for an SMC range.
  public var reason: String
  public var detail: String

  public init(line: Int, board: String, kind: Kind, subject: String, reason: String, detail: String) {
    self.line = line
    self.board = board
    self.kind = kind
    self.subject = subject
    self.reason = reason
    self.detail = detail
  }
}

public let trustColumns = ["board", "kind", "subject", "reason", "detail"]

/// Every row of trust.tsv's text, and a problem for each line that isn't one.
public func parseTrust(_ text: String) -> (rows: [TrustRow], problems: [String]) {
  var rows: [TrustRow] = []
  var problems: [String] = []
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  guard let header = lines.first, header.split(separator: "\t").map(String.init) == trustColumns else {
    return ([], ["trust.tsv:1: the header must be \(trustColumns.joined(separator: " "))"])
  }
  for (n, line) in lines.enumerated().dropFirst() where !line.isEmpty {
    let at = "trust.tsv:\(n + 1)"
    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard f.count == trustColumns.count else {
      problems.append("\(at): \(f.count) fields, not \(trustColumns.count)")
      continue
    }
    guard let kind = TrustRow.Kind(rawValue: String(f[1])) else {
      problems.append("\(at): kind \(f[1]) is not driver or smc")
      continue
    }
    let reasons = kind == .driver ? ["own-mmu", "no-iommu"] : ["addresses", "no-addresses"]
    guard reasons.contains(String(f[3])) else {
      problems.append("\(at): reason \(f[3]) is not \(reasons.joined(separator: " or ")) for a \(kind.rawValue)")
      continue
    }
    rows.append(TrustRow(line: n + 1, board: String(f[0]), kind: kind, subject: String(f[2]), reason: String(f[3]),
                         detail: String(f[4])))
  }
  return (rows, problems)
}

/// What a driver's `driver.manifest` says that trust cares about.
public struct DriverRecord: Equatable, Sendable {
  public var name: String
  public var ownMMU: Bool

  public init(name: String, ownMMU: Bool) {
    self.name = name
    self.ownMMU = ownMMU
  }
}

/// The records in a manifest's text: each `driver NAME` starts one, and an
/// `own-mmu` line after it is its. `#` starts a comment.
public func parseRecords(_ text: String) -> [DriverRecord] {
  var out: [DriverRecord] = []
  for raw in text.split(separator: "\n") {
    let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = words.first else { continue }
    if first == "driver", words.count == 2 {
      out.append(DriverRecord(name: String(words[1]), ownMMU: false))
    } else if first == "own-mmu", words.count == 1, !out.isEmpty {
      out[out.count - 1].ownMMU = true
    }
  }
  return out
}

/// Whether a support.tsv component is an IOMMU: its id says smmu, iommu,
/// vtd or amdvi.
private func isIOMMU(_ row: Row) -> Bool {
  ["smmu", "iommu", "vtd", "amdvi"].contains { row.id.contains($0) }
}

/// The report `vx hardware trust` prints for `board`: its IOMMUs, the
/// drivers whose DMA the kernel doesn't translate, and its SMC grants.
public func trustReport(board: String, trust: [TrustRow], support: [Row]) -> [String] {
  let mine = trust.filter { $0.board == board }
  var out = ["trusted base of \(board)"]
  let units = support.filter { $0.kind == .component && $0.parents.contains(board) && isIOMMU($0) }
  out.append("translated by an IOMMU")
  if units.isEmpty { out.append("  none: the board has no IOMMU listed in support.tsv") }
  for u in units { out.append("  \(u.id): \(u.notes)") }
  let drivers = mine.filter { $0.kind == .driver }
  out.append("DMA the kernel doesn't translate (the driver is trusted with all of memory)")
  if drivers.isEmpty { out.append("  none") }
  for d in drivers { out.append("  \(d.subject) (\(d.reason)): \(d.detail)") }
  let smc = mine.filter { $0.kind == .smc }
  let withAddresses = smc.filter { $0.reason == "addresses" }
  out.append("SMC ranges a board rule grants (\(smc.count)), \(withAddresses.count) whose calls take addresses")
  if smc.isEmpty { out.append("  none") }
  for s in smc { out.append("  \(s.subject) (\(s.reason)): \(s.detail)") }
  return out
}

/// Problems in trust.tsv against the platforms, the drivers' records and
/// the board rules' SMC function ids (the source text a rule's id must
/// appear in): a board that isn't a platform, a driver that has no
/// record or whose `own-mmu` disagrees with its reason, an own-MMU
/// record no row names, and an SMC function the rules don't grant.
public func checkTrust(_ trust: [TrustRow], support: [Row], records: [DriverRecord], ruleText: String) -> [String] {
  var problems: [String] = []
  let platforms = support.filter { $0.kind == .platform }.map(\.id)
  let lowered = ruleText.lowercased()
  for r in trust {
    let at = "trust.tsv:\(r.line): \(r.board) \(r.subject)"
    if !platforms.contains(r.board) { problems.append("\(at): \(r.board) is not a platform in support.tsv") }
    switch r.kind {
    case .driver:
      guard let record = records.first(where: { $0.name == r.subject }) else {
        problems.append("\(at): no driver.manifest has a record for \(r.subject)")
        continue
      }
      if (r.reason == "own-mmu") != record.ownMMU {
        problems.append("\(at): reason \(r.reason), but the record \(record.ownMMU ? "says" : "doesn't say") own-mmu")
      }
    case .smc:
      let lower = r.subject.lowercased()
      let digits = lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
      let grouped = digits.count == 8 ? String(digits.prefix(4)) + "_" + String(digits.suffix(4)) : digits
      if !lowered.contains("0x" + grouped) && !lowered.contains("0x" + digits) {
        problems.append("\(at): no board rule grants SMC function \(r.subject)")
      }
    }
  }
  for rec in records where rec.ownMMU && !trust.contains(where: { $0.kind == .driver && $0.subject == rec.name }) {
    problems.append("trust.tsv: \(rec.name)'s record says own-mmu, and no board's row names it")
  }
  return problems
}
