// SPDX-License-Identifier: BSD-3-Clause

// The tree the loader runs a devicetree machine on (D154): ours picked by
// the firmware tree's compatible or a known firmware identity, then
// merged with the values only firmware knows.

import DtAcpi
import Dtc
import Fdt
import Testing

func dtb(_ source: String) throws -> [UInt8] {
  try DtsParser.parse("/dts-v1/;\n" + source, file: "test.dts").flatten()
}

func match(_ ours: [UInt8], _ firmware: [UInt8]) -> Devicetree.Match? {
  ours.span.bytes.withUnsafeBytes { a in
    firmware.span.bytes.withUnsafeBytes { b in
      guard let o = Fdt(RawSpan(_unsafeBytes: a)), let f = Fdt(RawSpan(_unsafeBytes: b)) else { return nil }
      return Devicetree.matches(o, firmware: f)
    }
  }
}

let rv2 = """
  / {
    compatible = "xunlong,orangepi-rv2", "spacemit,k1";
    chosen { stdout-path = "serial0"; };
    cpus { cpu@0 { status = "okay"; }; cpu@1 { }; };
    soc { network-bus { ethernet@cac80000 { mac-address = [00 00 00 00 00 00]; status = "okay"; }; }; };
  };
  """

@Test func theRV2sTreeIsPickedByItsFirmwaresIdentity() throws {
  let ours = try dtb(rv2)
  let uboot = try dtb(#"/ { compatible = "ky,x1", "riscv"; model = "ky x1 orangepi-rv2 board"; };"#)
  #expect(match(ours, uboot) == .identity)
  #expect(match(ours, try dtb(#"/ { compatible = "ky,x1", "riscv"; model = "ky x1 deb1"; };"#)) == nil)
  #expect(match(ours, try dtb(#"/ { compatible = "xunlong,orangepi-rv2"; };"#)) == .compatible)
  #expect(match(ours, try dtb(#"/ { compatible = "riscv-virtio"; };"#)) == nil)
}

@Test func firmwaresValuesAreMergedIntoOurs() throws {
  let ours = try dtb(rv2)
  let firmware = try dtb("""
    / {
      compatible = "ky,x1"; serial-number = "1234";
      chosen { kaslr-seed = <1 2>; bootargs = "not ours"; };
      cpus { cpu@0 { }; cpu@1 { status = "disabled"; }; };
      soc { ethernet@cac80000 { local-mac-address = [02 11 22 33 44 55]; }; };
      reserved-memory {
        #address-cells = <2>; #size-cells = <2>; ranges;
        opensbi: mmode@0 { reg = <0 0 0 0x80000>; no-map; };
        spare@40000000 { reg = <0 0x40000000 0 0x1000>; };
      };
      user { memory-region = <&opensbi>; };
    };
    """)
  var buffer = [UInt8](repeating: 0, count: ours.count + firmware.count + 4096)
  let size = try #require(buffer.withUnsafeMutableBytes { raw -> Int? in
    var out = MutableRawSpan(_unsafeBytes: raw)
    return ours.span.bytes.withUnsafeBytes { a in
      firmware.span.bytes.withUnsafeBytes { b in
        guard let o = Fdt(RawSpan(_unsafeBytes: a)), let f = Fdt(RawSpan(_unsafeBytes: b)) else { return nil }
        // The second range is free memory in UEFI's map: dropped.
        return Devicetree.merge(o, firmware: f, keep: { address, _ in address != 0x4000_0000 }, into: &out)
      }
    }
  })
  let merged = Array(buffer[0..<size])
  func value(_ path: StaticString, _ name: StaticString) -> [UInt8]? { property(merged, path, name) }
  do {
    #expect(value("/", "compatible").map { $0.starts(with: Array("xunlong,orangepi-rv2\0".utf8)) } == true)  // ours
    #expect(value("/", "serial-number") == Array("1234\0".utf8))
    #expect(value("/chosen", "kaslr-seed") == [0, 0, 0, 1, 0, 0, 0, 2])
    #expect(value("/chosen", "stdout-path") == Array("serial0\0".utf8))
    #expect(value("/chosen", "bootargs") == nil)  // not on the list
    #expect(value("/cpus/cpu@0", "status") == Array("okay\0".utf8))
    #expect(value("/cpus/cpu@1", "status") == Array("disabled\0".utf8))
    #expect(value("/soc/network-bus/ethernet@cac80000", "local-mac-address") == [2, 0x11, 0x22, 0x33, 0x44, 0x55])
    #expect(value("/soc/network-bus/ethernet@cac80000", "mac-address") == nil)
    #expect(value("/soc/network-bus/ethernet@cac80000", "status") == Array("okay\0".utf8))
    #expect(value("/reserved-memory/mmode@0", "reg") == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0])
    #expect(value("/reserved-memory/mmode@0", "no-map") == [])
    #expect(value("/reserved-memory/mmode@0", "phandle") == nil)  // firmware's numbering isn't ours
    #expect(!hasNode(merged, "/reserved-memory/spare@40000000"))
    #expect(!hasNode(merged, "/user"))  // only the listed values come across
  }
}

/// Property `name` of the node at `path` in `blob`, read with lib/fdt's reader.
func property(_ blob: [UInt8], _ path: StaticString, _ name: StaticString) -> [UInt8]? {
  blob.span.bytes.withUnsafeBytes { raw in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)), let node = t.node(path), let p = t.property(node, name) else {
      return nil
    }
    return p.map { t.byte($0) }
  }
}

func hasNode(_ blob: [UInt8], _ path: StaticString) -> Bool {
  blob.span.bytes.withUnsafeBytes { raw in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return false }
    return t.node(path) != nil
  }
}

/// The board's addresses, which the RV2's U-Boot reads from an EEPROM and
/// puts in no tree: the `local-mac-address` of each node our aliases name
/// `ethernet<N>`, the base plus N, unless firmware's tree gives it one.
@Test func theBoardsAddressesGoToItsEthernets() throws {
  let ours = try dtb("""
    / {
      compatible = "xunlong,orangepi-rv2";
      aliases { ethernet0 = "/soc/ethernet@cac80000"; ethernet1 = "/soc/ethernet@cac81000"; };
      soc { ethernet@cac80000 { mac-address = [00 00 00 00 00 00]; }; ethernet@cac81000 { }; };
    };
    """)
  func merged(_ firmware: [UInt8]) throws -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: ours.count + firmware.count + 4096)
    var base = InlineArray<6, UInt8>(repeating: 0)
    for (i, b) in [0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE6].enumerated() { base[i] = UInt8(b) }
    let network = NetworkAddresses(base: base, count: 2)
    let size = try #require(buffer.withUnsafeMutableBytes { raw -> Int? in
      var out = MutableRawSpan(_unsafeBytes: raw)
      return ours.span.bytes.withUnsafeBytes { a in
        firmware.span.bytes.withUnsafeBytes { b in
          guard let o = Fdt(RawSpan(_unsafeBytes: a)), let f = Fdt(RawSpan(_unsafeBytes: b)) else { return nil }
          return Devicetree.merge(o, firmware: f, keep: { _, _ in true }, network: network, into: &out)
        }
      }
    })
    return Array(buffer[0..<size])
  }
  let plain = try merged(try dtb(#"/ { compatible = "ky,x1"; };"#))
  #expect(property(plain, "/soc/ethernet@cac80000", "local-mac-address") == [0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE6])
  #expect(property(plain, "/soc/ethernet@cac80000", "mac-address") == nil)
  #expect(property(plain, "/soc/ethernet@cac81000", "local-mac-address") == [0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE7])
  let given = try merged(try dtb(#"/ { compatible = "ky,x1"; soc { ethernet@cac80000 { local-mac-address = [02 11 22 33 44 55]; }; }; };"#))
  #expect(property(given, "/soc/ethernet@cac80000", "local-mac-address") == [2, 0x11, 0x22, 0x33, 0x44, 0x55])
}

/// An ONIE TlvInfo block as the RV2's EEPROM holds it: its base address
/// and count, once its CRC checks; a block whose CRC doesn't is none.
@Test func anOnieBlockGivesTheBoardsAddresses() throws {
  var block = Array("TlvInfo\0".utf8) + [1, 0, 0]
  let entries: [UInt8] = [0x24, 6, 0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE6, 0x2A, 2, 0, 2]
  let length = entries.count + 6
  block[9] = UInt8(length >> 8)
  block[10] = UInt8(length & 0xFF)
  block += entries + [0xFE, 4]
  // CRC-32 (IEEE) over everything before its value.
  var crc: UInt32 = 0xFFFF_FFFF
  for b in block {
    crc ^= UInt32(b)
    for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xEDB8_8320 : crc >> 1 }
  }
  crc = ~crc
  block += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
  block += [UInt8](repeating: 0xFF, count: 256 - block.count)
  let parsed = Onie.addresses(block.span)
  let found = try #require(parsed)
  #expect(found.count == 2)
  #expect((0..<6).map { found.address(1)[$0] } == [0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE7])
  var bad = block
  bad[13] ^= 1
  let corrupt = Onie.addresses(bad.span)
  let blank = Onie.addresses([UInt8](repeating: 0xFF, count: 256).span)
  #expect(corrupt == nil)
  #expect(blank == nil)
}
