// SPDX-License-Identifier: BSD-3-Clause

// The budget lines a boot prints (kernel/Kernel/Trace/Budgets.swift, m2),
// read into Judge's units.

/// One budget line from a boot, in Judge's units: seconds, or the count.
public struct Reported: Equatable {
  public var value: Double
  public var limit: Double?
  public var target: Double?
  public var unit: Rule.Unit

  public init(value: Double, limit: Double?, target: Double?, unit: Rule.Unit) {
    self.value = value
    self.limit = limit
    self.target = target
    self.unit = unit
  }
}

/// `budget name=N value=V unit=U [limit=L] [target=T]`. The kernel's limit
/// is exclusive (a value at the limit misses it); Judge's is inclusive, so
/// the integer limit becomes L - 1.
public func parseBudgets(_ text: String) -> [String: Reported] {
  var found: [String: Reported] = [:]
  // QEMU's serial console ends lines with CR LF, one Character to Swift.
  for line in text.split(whereSeparator: \.isNewline) {
    guard let at = line.firstRange(of: "budget name=") else { continue }
    var fields: [Substring: Substring] = [:]
    for word in line[at.lowerBound...].split(separator: " ").dropFirst() {
      guard let eq = word.firstIndex(of: "=") else { continue }
      fields[word[..<eq]] = word[word.index(after: eq)...]
    }
    guard let name = fields["name"], let value = fields["value"].flatMap({ UInt64($0) }) else { continue }
    let count = fields["unit"] == "count"
    // Divided, not multiplied by 1e-9: 1000 ns is then exactly the double 1e-6.
    let perUnit = count ? 1.0 : 1e9
    found[String(name)] = Reported(
      value: Double(value) / perUnit,
      limit: fields["limit"].flatMap { UInt64($0) }.map { Double($0 == 0 ? 0 : $0 - 1) / perUnit },
      target: fields["target"].flatMap { UInt64($0) }.map { Double($0) / perUnit },
      unit: count ? .count : .seconds)
  }
  return found
}
