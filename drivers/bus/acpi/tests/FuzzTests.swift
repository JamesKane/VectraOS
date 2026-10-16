// SPDX-License-Identifier: BSD-3-Clause

// A0f: the fuzzer. Mutated tables (the corpus's, or a synthetic one) are
// loaded, their devices initialized and their methods called under small
// budgets: errors are expected; a trap is the failure. Each mutant's seed
// goes to stderr first, unbuffered, so a crash names its input.
// TODHCHAI_ACPI_FUZZ=N runs N mutants a table instead of the few td ci runs.

import Glibc
@testable import TDACPI
import Testing

struct Xorshift {
  var state: UInt64
  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
  mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
}

/// Bytes AML often has: prefixes, opcodes that open packages, constants.
let interesting: [UInt8] = [0x00, 0x01, 0xFF, 0x0A, 0x0B, 0x0C, 0x0E, 0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0x5E,
                            0x2E, 0x2F, 0x60, 0x68, 0x70, 0x88, 0xA0, 0xA2, 0xA4, 0x80, 0x81, 0x82, 0x3F, 0x40, 0x7F]

func mutate(_ aml: [UInt8], _ rng: inout Xorshift) -> [UInt8] {
  var b = aml
  for _ in 0..<(1 + rng.below(4)) {
    guard !b.isEmpty else { break }
    let at = rng.below(b.count)
    switch rng.below(7) {
    case 0: b[at] ^= UInt8(1 << rng.below(8))
    case 1: b[at] = interesting[rng.below(interesting.count)]
    case 2: b[at] = UInt8(truncatingIfNeeded: rng.next())
    case 3: b.removeSubrange(at..<min(b.count, at + 1 + rng.below(16)))
    case 4: b.insert(contentsOf: (0..<(1 + rng.below(8))).map { _ in interesting[rng.below(interesting.count)] }, at: at)
    case 5:
      let from = rng.below(b.count), n = min(1 + rng.below(32), b.count - from)
      b.insert(contentsOf: b[from..<(from + n)], at: at)
    default: b.removeSubrange(at...)
    }
  }
  return b
}

/// A table with `aml` for a body, its length and checksum made right.
func retable(_ original: Table, _ aml: [UInt8]) -> Table? {
  var t = Array(original.bytes[..<Table.headerSize]) + aml
  let n = t.count
  for i in 0..<4 { t[4 + i] = UInt8(truncatingIfNeeded: n >> (8 * i)) }
  t[9] = 0
  t[9] = 0 &- t.reduce(0, &+)
  return try? Table(t)
}

/// What the fuzzer starts from when there's no corpus: a table using much
/// of the grammar.
func syntheticSeed() -> Table {
  let body = AML.nameObject("I", AML.integer(5)) + AML.nameObject("S", AML.string("text"))
    + AML.nameObject("B", AML.buffer([1, 2, 3, 4, 5, 6, 7, 8]))
    + AML.nameObject("P", AML.packageOf([AML.integer(1), AML.string("x"), AML.name("\\I")]))
    + AML.region("R", space: 0, AML.integer(0x1000), AML.integer(0x20))
    + AML.field("R", 0x01, [.named("F0", 8), .reserved(8), .named("F1", 16)])
    + AML.indexField("F0", "F1", 0x01, [.named("IX", 8)])
    + AML.ifThen(AML.op(0x93, AML.name("I"), AML.integer(5)), AML.device("D", AML.nameObject("_HID", AML.integer(0x080A_D041))))
    + AML.scope("\\_SB", AML.device("DEV", AML.method("_STA", AML.returning(AML.integer(0x0F)))
      + AML.nameObject("_CRS", AML.buffer([0x47, 0x01, 0x60, 0, 0x60, 0, 1, 1, 0x79, 0]))))
    + AML.method("M", args: 2, AML.store(AML.op(0x72, AML.arg(0), AML.arg(1), AML.none), AML.local(0))
      + AML.whileLoop(AML.op(0x95, AML.local(1), AML.integer(4)), AML.op(0x75, AML.local(1))
        + AML.store(AML.op(0x73, AML.name("S"), AML.local(1), AML.none), AML.local(2)))
      + AML.op(0x8A, AML.name("B"), AML.integer(0), AML.name("BF")) + AML.store(AML.local(0), AML.name("BF"))
      + AML.store(AML.integer(7), AML.op(0x88, AML.name("P"), AML.integer(0), AML.none))
      + AML.store(AML.name("F1"), AML.name("IX")) + AML.returning(AML.op(0x83, AML.op(0x88, AML.name("P"), AML.integer(2), AML.none))))
  return try! Table(AML.dsdt(body))
}

func say(_ s: String) {
  let bytes = Array((s + "\n").utf8)
  _ = bytes.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }  // unbuffered: survives a crash
}

/// Loads `table`, initializes, calls methods: whatever happens but a trap.
func exercise(_ table: Table, _ rng: inout Xorshift) {
  var ns = Namespace()
  ns.loopLimit = 200
  ns.stepLimit = 20_000
  let host = RecordingHost()
  host.interfaces = OSInterfaces.windows
  _ = try? ns.load(table, host: host)
  _ = ns.initializeDevices(host: host)
  var calls = 0
  for n in 0..<ns.nodes.count where calls < 64 && ns.isLive(n) {
    guard case .method(let args, _, _, _) = ns.nodes[n].object else { continue }
    calls += 1
    let values: [Datum] = (0..<args).map { _ in
      switch rng.below(4) {
      case 0: .integer(rng.next())
      case 1: .integer(UInt64(rng.below(4)))
      case 2: .string(Array("\\_SB".utf8))
      default: .buffer(BufferObject([UInt8](repeating: 0x5A, count: rng.below(16))))
      }
    }
    _ = try? ns.evaluate(n, values, host: host)
  }
  for d in ns.deviceNodes().prefix(32) {
    _ = try? ns.currentResources(d, host: host)
    _ = try? ns.routing(d, host: host)
  }
}

@Test func mutatedTablesNeverTrapTheInterpreter() {
  let perTable = getenv("TODHCHAI_ACPI_FUZZ").flatMap { Int(String(cString: $0)) } ?? 40
  var seeds: [(String, Table)] = [("synthetic", syntheticSeed())]
  for machine in Corpus.machines {
    for file in Corpus.tableFiles(machine) where file.hasPrefix("DSDT") || file.hasPrefix("SSDT") {
      // The biggest tables take long to run; td ci samples the rest.
      guard let bytes = Corpus.bytes(machine, file), bytes.count < 120_000 || perTable > 40, let t = try? Table(bytes) else {
        continue
      }
      seeds.append(("\(machine)/\(file)", t))
    }
  }
  var mutants = 0
  for (s, (name, table)) in seeds.enumerated() {
    for i in 0..<perTable {
      let seed = UInt64(s) << 32 | UInt64(i) | 1
      say("fuzz \(name) seed \(seed)")
      var rng = Xorshift(state: seed)
      guard let mutant = retable(table, mutate(Array(table.body), &rng)) else { continue }
      exercise(mutant, &rng)
      mutants += 1
    }
  }
  #expect(mutants >= 40)
}

@Test func aBufferSizeRunningPastItsPackageIsMalformed() throws {
  // Found by the fuzzer: Name (X, Buffer { QWord size }) whose package ends
  // inside the size. Loading read the size past the package, then sliced
  // backwards.
  let aml: [UInt8] = AML.nameObject("X", [0x11, 0x03, 0x0E, 0, 0, 0, 0, 0, 0, 0, 0])
  var ns = Namespace()
  #expect(throws: ACPIError.malformed(52)) { try ns.load(try Table(AML.dsdt(aml))) }  // 36 + 1 + 4 + 1 + 1 + 9: past the size
}
