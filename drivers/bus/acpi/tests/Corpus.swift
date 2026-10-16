// SPDX-License-Identifier: BSD-3-Clause

// The corpus of real firmware tables (vx acpi; drivers/bus/acpi/README.md),
// out of the tree in .cache/acpi. Tests over it skip when it's absent.

import FoundationEssentials
import TDACPI

enum Corpus {
  /// .cache/acpi at the repository's root, found from this file.
  static let root: String = {
    var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    parts.removeLast(5)  // drivers/bus/acpi/tests/Corpus.swift
    return parts.joined(separator: "/") + "/.cache/acpi"
  }()

  static var isPresent: Bool { !machines.isEmpty }

  /// Each machine's directory name.
  static var machines: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
  }

  /// A machine's files that hold tables: everything but PROVENANCE, the
  /// oracle and the memory snapshot.
  static func tableFiles(_ machine: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(machine)")) ?? [])
      .filter { $0 != "PROVENANCE" && $0 != "memory" && !$0.hasSuffix(".tsv") }.sorted()
  }

  static func bytes(_ machine: String, _ file: String) -> [UInt8]? {
    FileManager.default.contents(atPath: "\(root)/\(machine)/\(file)").map { [UInt8]($0) }
  }
}

/// A host for a corpus machine: SystemMemory reads come from the memory
/// `vx acpi import` saved (writes go to an overlay), `_OSI` answers as
/// Windows does, and no other space has a handler.
final class SnapshotHost: ACPIHost {
  var regions: [(base: UInt64, bytes: [UInt8])] = []
  var overlay: [UInt64: UInt8] = [:]

  init(_ machine: String) {
    let dir = "\(Corpus.root)/\(machine)/memory"
    for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
      if let base = UInt64(file, radix: 16), let data = FileManager.default.contents(atPath: "\(dir)/\(file)") {
        regions.append((base, [UInt8](data)))
      }
    }
  }

  static func hasMemory(_ machine: String) -> Bool {
    !((try? FileManager.default.contentsOfDirectory(atPath: "\(Corpus.root)/\(machine)/memory")) ?? []).isEmpty
  }

  func byte(_ address: UInt64) -> UInt8? {
    if let o = overlay[address] { return o }
    for r in regions where address >= r.base && address < r.base + UInt64(r.bytes.count) {
      return r.bytes[Int(address - r.base)]
    }
    return nil
  }

  func supportsInterface(_ name: [UInt8]) -> Bool { OSInterfaces.claims(name) }
  func sleep(milliseconds: UInt64) {}
  func stall(microseconds: UInt64) {}
  func notify(_ node: Int, _ value: UInt64) {}
  func timer() -> UInt64 { 0 }
  func debug(_ text: [UInt8]) {}
  func fatal(type: UInt8, code: UInt32, argument: UInt64) {}

  func readRegion(_ a: RegionAccess) -> UInt64? {
    guard a.space == 0 else { return nil }
    var v: UInt64 = 0
    for i in 0..<a.width {
      guard let b = byte(a.address + UInt64(i)) else { return nil }
      v |= UInt64(b) << (8 * UInt64(i))
    }
    return v
  }

  func writeRegion(_ a: RegionAccess, _ value: UInt64) -> Bool {
    guard a.space == 0 else { return false }
    for i in 0..<a.width { overlay[a.address + UInt64(i)] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    return true
  }
}
