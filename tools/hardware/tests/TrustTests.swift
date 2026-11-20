// SPDX-License-Identifier: BSD-3-Clause

import Hardware
import Testing

private let trustHeader = trustColumns.joined(separator: "\t")

private func trustTable(_ rows: String...) -> String {
  ([trustHeader] + rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).joined(separator: "\t") })
    .joined(separator: "\n")
}

private let sky = "board|driver|gpu|own-mmu|translates itself"
private let usb = "board|driver|usbhost|no-iommu|named by no IORT node"
private let smc = "board|smc|0xC2000001|no-addresses|SCMI; takes no address"
private let smmu = "b-smmuv3|component|board|arm64|planned|no|V4|D5|-|-|-|-|-|two SMMUv3"

@Test func trustRowsParseAndBadOnesAreProblems() {
  let (rows, problems) = parseTrust(trustTable(sky, smc, "board|driver|x|maybe|d", "b|dev|x|own-mmu|d", "b|smc"))
  #expect(rows.count == 2 && rows[0].kind == .driver && rows[1].kind == .smc)
  #expect(problems.count == 3)
  #expect(parseTrust("board\tkind\n").problems.count == 1)
}

@Test func recordsReadOwnMMUPerDriver() {
  let text = """
    # a comment
    driver gpu
    own-mmu # trusted
    driver plain
    match acpi X
    """
  #expect(parseRecords(text) == [DriverRecord(name: "gpu", ownMMU: true), DriverRecord(name: "plain", ownMMU: false)])
}

@Test func theTrustedBaseNamesUntranslatedDriversAndSMCGrants() {
  let (trust, _) = parseTrust(trustTable(sky, usb, smc))
  let (support, _) = parseSupport(table(board, smmu))
  let report = trustReport(board: "board", trust: trust, support: support)
  #expect(report.contains("  b-smmuv3: two SMMUv3"))
  #expect(report.contains { $0.hasPrefix("  gpu (own-mmu)") })
  #expect(report.contains { $0.hasPrefix("  usbhost (no-iommu)") })
  #expect(report.contains("SMC ranges a board rule grants (1), 0 whose calls take addresses"))
  #expect(trustReport(board: "other", trust: trust, support: support).contains("  none"))
}

@Test func theTrustFileIsCheckedAgainstRecordsPlatformsAndRules() {
  let (trust, _) = parseTrust(trustTable(sky, usb, smc))
  let (support, _) = parseSupport(table(board))
  let records = [DriverRecord(name: "gpu", ownMMU: true), DriverRecord(name: "usbhost", ownMMU: false)]
  let rules = "return FirmwareCall(function: 0xC200_0001, memory: 0x8438_0000, size: 0x80)"
  #expect(checkTrust(trust, support: support, records: records, ruleText: rules).isEmpty)
  // The record dropped own-mmu, the driver vanished, the rule is gone, the board isn't a platform.
  let broken = checkTrust(trust, support: support, records: [DriverRecord(name: "gpu", ownMMU: false)], ruleText: "")
  #expect(broken.count == 3)
  let other = checkTrust(trust, support: [], records: records, ruleText: rules)
  #expect(other.count == 3)
  // A record that says own-mmu with no row naming it.
  let unnamed = checkTrust([], support: support, records: records, ruleText: rules)
  #expect(unnamed.count == 1)
}
