// SPDX-License-Identifier: BSD-3-Clause

// vx dtc (D154): devicetree source through Dtc's parser and lib/fdt's
// writer, read back with lib/fdt's reader, the loader's.

import Dtc
import Fdt
import Testing

/// What a compiled tree says, read through lib/fdt's reader.
struct Read {
  var nodes: [String: [String: [UInt8]]] = [:]  // path -> property -> value
}

func read(_ blob: [UInt8]) -> Read? {
  blob.span.bytes.withUnsafeBytes { raw -> Read? in
    guard let fdt = Fdt(RawSpan(_unsafeBytes: raw)), let root = fdt.root else { return nil }
    var out = Read()
    func visit(_ node: Int, _ path: String) {
      var props: [String: [UInt8]] = [:]
      fdt.forEachProperty(of: node) { name, value in
        var end = name
        while fdt.byte(end) != 0 { end += 1 }
        let key = String(decoding: (name..<end).map { fdt.byte($0) }, as: UTF8.self)
        props[key] = value.map { fdt.byte($0) }
        return true
      }
      out.nodes[path] = props
      fdt.forEachChild(of: node) { child in
        var end = child + 4
        while fdt.byte(end) != 0 { end += 1 }
        let name = String(decoding: ((child + 4)..<end).map { fdt.byte($0) }, as: UTF8.self)
        visit(child, (path == "/" ? "" : path) + "/" + name)
        return true
      }
    }
    visit(root, "/")
    return out
  }
}

func compile(_ source: String) throws -> Read {
  try #require(read(try DtsParser.parse(source, file: "test.dts").flatten()))
}

func cells(_ values: UInt32...) -> [UInt8] {
  values.flatMap { [UInt8($0 >> 24), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
}

func be32(_ bytes: [UInt8]?) -> UInt32? {
  guard let bytes, bytes.count == 4 else { return nil }
  return bytes.reduce(0) { $0 << 8 | UInt32($1) }
}

@Test func nodesPropertiesAndValuesComeOutAsWritten() throws {
  let t = try compile("""
    /dts-v1/;
    / {
      #address-cells = <2>;
      compatible = "vendor,board", "vendor,soc";
      model = "A \\"board\\"\\n";
      empty;
      mac = [ 00 11 22 33 44 55 ];
      wide = /bits/ 64 <0x1122334455667788>;
      narrow = /bits/ 8 <1 2 0xff>;
      soc { uart@d4017000 { reg = <0x0 0xd4017000 0x0 0x100>; }; };
    };
    """)
  let root = try #require(t.nodes["/"])
  #expect(root["#address-cells"] == cells(2))
  #expect(root["compatible"] == Array("vendor,board\0vendor,soc\0".utf8))
  #expect(root["model"] == Array("A \"board\"\n\0".utf8))
  #expect(root["empty"] == [])
  #expect(root["mac"] == [0, 0x11, 0x22, 0x33, 0x44, 0x55])
  #expect(root["wide"] == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
  #expect(root["narrow"] == [1, 2, 0xFF])
  #expect(t.nodes["/soc/uart@d4017000"]?["reg"] == cells(0, 0xd401_7000, 0, 0x100))
}

@Test func cellExpressionsAreCs() throws {
  let t = try compile("""
    /dts-v1/;
    / { a = <(((3) << 16) | (1)) (10 - 2 * 3) (7 / 2 + 7 % 2) ((1 ? 5 : 6)) (~0) (-1) ('A') 010 0b101>; };
    """)
  #expect(t.nodes["/"]?["a"] == cells(0x3_0001, 4, 4, 5, 0xFFFF_FFFF, 0xFFFF_FFFF, 65, 8, 5))
}

@Test func referencesBecomePhandlesAndPaths() throws {
  let t = try compile("""
    /dts-v1/;
    / {
      aliases { serial0 = &uart0; root = &{/soc}; };
      soc {
        clk: clock-controller@1000 { #clock-cells = <1>; };
        uart0: serial@2000 { clocks = <&clk 5>, <&clk 6>; };
        fixed: thing { phandle = <1>; };
        user { other = <&fixed &uart0>; };
      };
    };
    """)
  // The clock is referenced first: it takes the first phandle free (2, as
  // the source fixed 1), then the UART.
  #expect(t.nodes["/soc/clock-controller@1000"]?["phandle"] == cells(2))
  #expect(t.nodes["/soc/serial@2000"]?["clocks"] == cells(2, 5, 2, 6))
  #expect(t.nodes["/soc/thing"]?["phandle"] == cells(1))
  #expect(t.nodes["/soc/user"]?["other"] == cells(1, 3))
  #expect(t.nodes["/soc/serial@2000"]?["phandle"] == cells(3))
  #expect(t.nodes["/aliases"]?["serial0"] == Array("/soc/serial@2000\0".utf8))
  #expect(t.nodes["/aliases"]?["root"] == Array("/soc\0".utf8))
  // A path reference alone gives no phandle.
  #expect(t.nodes["/soc"]?["phandle"] == nil)
}

@Test func overridesDeletionsAndOmissionApply() throws {
  let t = try compile("""
    /dts-v1/;
    / {
      soc {
        eth0: ethernet@1 { status = "disabled"; old = <1>; };
        gone: x { };
        y { };
        pins {
          used: used-cfg { };
          /omit-if-no-ref/ unused: unused-cfg { };
        };
      };
      user { pinctrl-0 = <&used>; };
    };
    &eth0 { status = "okay"; /delete-property/ old; phy { reg = <1>; }; };
    / { soc { /delete-node/ y; }; };
    /delete-node/ &gone;
    """)
  let eth = try #require(t.nodes["/soc/ethernet@1"])
  #expect(eth["status"] == Array("okay\0".utf8))
  #expect(eth["old"] == nil)
  #expect(t.nodes["/soc/ethernet@1/phy"]?["reg"] == cells(1))
  #expect(t.nodes["/soc/x"] == nil && t.nodes["/soc/y"] == nil)
  #expect(t.nodes["/soc/pins/used-cfg"] != nil)
  #expect(t.nodes["/soc/pins/unused-cfg"] == nil)
}

@Test func errorsSayWhereFromLineMarkers() {
  let source = """
    # 1 "board.dts"
    /dts-v1/;
    # 1 "soc.dtsi" 1
    / {
      a = <&nowhere>;
    };
    """
  do {
    _ = try DtsParser.parse(source, file: "board.dts").flatten()
    Issue.record("a reference to no label compiled")
  } catch {
    #expect(error.description == "soc.dtsi:2: no node labelled 'nowhere'")
  }
  #expect(throws: DtcError.self) { try DtsParser.parse("/ { };", file: "a.dts") }  // no /dts-v1/
  #expect(throws: DtcError.self) { try DtsParser.parse("/dts-v1/;\n/ { a = <1>; ", file: "a.dts") }
  #expect(throws: DtcError.self) { try DtsParser.parse("/dts-v1/;\n/ { a = /bits/ 8 <256>; };", file: "a.dts") }
}

@Test func includeReadsAnotherSource() throws {
  let tree = try DtsParser.parse("/dts-v1/;\n/include/ \"soc.dtsi\"\n&u { status = \"okay\"; };", file: "b.dts") { name, _ in
    name == "soc.dtsi" ? ("/ { u: uart { status = \"disabled\"; }; };", "soc.dtsi") : nil
  }
  let t = try #require(read(try tree.flatten()))
  #expect(t.nodes["/uart"]?["status"] == Array("okay\0".utf8))
}

@Test func theWriterSharesNamesAndRefusesWhatDoesntFit() {
  func write(capacity: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0xEE, count: capacity)
    let size = buffer.withUnsafeMutableBytes { raw -> Int? in
      var out = MutableRawSpan(_unsafeBytes: raw)
      var w = FdtWriter(capacity: capacity)
      w.beginNode([UInt8]().span, into: &out)
      w.property(Array("status".utf8).span, Array("okay\0".utf8).span, into: &out)
      w.beginNode(Array("a".utf8).span, into: &out)
      w.property(Array("status".utf8).span, Array("disabled\0".utf8).span, into: &out)
      w.endNode(into: &out)
      w.endNode(into: &out)
      return w.finish(bootCpu: 3, into: &out)
    }
    return size.map { Array(buffer[0..<$0]) }
  }
  let blob = write(capacity: 4096)
  #expect(blob.map { be32(Array($0[32..<36])) } == 7)  // "status" once
  #expect(blob.map { be32(Array($0[28..<32])) } == 3)
  #expect(blob.flatMap(read)?.nodes["/a"]?["status"] == Array("disabled\0".utf8))
  #expect(write(capacity: 80) == nil)
}

// Every DT board's tree (docs/hardware/support.tsv's devicetree column),
// from firmware/dts through the toolchain's clang as the build runs it,
// read back with the loader's reader. Skips without clang.

import Foundation

enum Boards {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  static let clang: String? = {
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs.append("\(NSHomeDirectory())/.local/share/swiftly/toolchains/6.4.0/usr/bin")
    return dirs.map { "\($0)/clang" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }()

  /// Each DT board's source, from support.tsv.
  static func trees() throws -> [String] {
    let text = try String(contentsOf: root.appendingPathComponent("docs/hardware/support.tsv"), encoding: .utf8)
    return text.split(separator: "\n").dropFirst().compactMap { line in
      let f = line.split(separator: "\t", omittingEmptySubsequences: false)
      return f.count == 14 && f[1] == "platform" && f[12] != "-" ? String(f[12]) : nil
    }
  }

  static func compile(_ tree: String) throws -> [UInt8] {
    let dts = root.appendingPathComponent("firmware/dts").appendingPathComponent(tree)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("dtc-\(UUID().uuidString).i")
    defer { try? FileManager.default.removeItem(at: out) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: clang!)
    p.arguments = ["-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
                   "-I", dts.deletingLastPathComponent().path, "-I", root.appendingPathComponent("firmware/dts/include").path,
                   dts.path, "-o", out.path]
    try p.run()
    p.waitUntilExit()
    try #require(p.terminationStatus == 0)
    return try DtsParser.parse(String(contentsOf: out, encoding: .utf8), file: tree).flatten()
  }
}

@Test(.enabled(if: Boards.clang != nil))
func everyBoardsTreeCompilesAndReadsBack() throws {
  let trees = try Boards.trees()
  #expect(trees.contains("riscv/spacemit/k1-orangepi-rv2.dts"))
  for tree in trees {
    let t = try #require(read(try Boards.compile(tree)), "\(tree) doesn't read back")
    let compatible = try #require(t.nodes["/"]?["compatible"], "\(tree) has no root compatible")
    #expect(compatible.last == 0 && compatible.count > 1)
    // Phandles are unique, and every cell that refers to one finds it.
    let phandles = t.nodes.values.compactMap { be32($0["phandle"]) }
    #expect(Set(phandles).count == phandles.count, "\(tree): a phandle twice")
    for (path, props) in t.nodes {
      for name in ["clocks", "resets", "interrupt-parent", "phy-handle"] {
        guard let value = props[name] else { continue }
        let first = be32(Array(value.prefix(4)))
        #expect(first.map(phandles.contains) == true, "\(tree): \(path)'s \(name) names no node")
      }
    }
  }
  // The RV2's EMAC, as upstream's binding has it: what U-Boot's tree lacks.
  let rv2 = try #require(read(try Boards.compile("riscv/spacemit/k1-orangepi-rv2.dts")))
  let eth0 = try #require(rv2.nodes["/soc/network-bus/ethernet@cac80000"] ?? rv2.nodes.first { $0.key.hasSuffix("/ethernet@cac80000") }?.value)
  #expect(eth0["compatible"] == Array("spacemit,k1-emac\0".utf8))
  #expect(eth0["interrupts"] == cells(131))
  #expect(eth0["status"] == Array("okay\0".utf8))
}
