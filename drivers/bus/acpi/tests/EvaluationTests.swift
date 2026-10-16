// SPDX-License-Identifier: BSD-3-Clause

// A0c: evaluating AML, each rule from its section of ACPI 6.5, on AML the
// tests' encoder builds.

@testable import TDACPI
import Testing

/// Loads `aml` (running its load-time code) and evaluates `path`.
func run(_ aml: [UInt8], _ path: StaticString = "\\M", _ args: [Datum] = [], revision: UInt8 = 2,
         host: RecordingHost = RecordingHost(), loopLimit: Int = 1 << 20) throws(ACPIError) -> Datum
{
  var ns = Namespace(integerBits: revision < 2 ? 32 : 64)
  ns.loopLimit = loopLimit
  try ns.load(try Table(AML.dsdt(aml, revision: revision)), host: host)
  guard let node = ns.lookup(path) else { throw ACPIError.notFound }
  return try ns.evaluate(node, args, host: host)
}

func method(_ body: [UInt8], args: Int = 0) -> [UInt8] { AML.method("M", args: args, body) }
let x = AML.name("\\X")

@Test func arithmeticWrapsAtTheIntegerWidth() throws {
  let add = method(AML.returning(AML.op(0x72, AML.arg(0), AML.arg(1), AML.none)), args: 2)
  #expect(try run(add, "\\M", [.integer(2), .integer(40)]).integer == 42)
  #expect(try run(add, "\\M", [.integer(.max), .integer(2)]).integer == 1)
  // Revision 1: 32-bit integers (§5.2.11.1).
  #expect(try run(add, "\\M", [.integer(0xFFFF_FFFF), .integer(2)], revision: 1).integer == 1)
  #expect(try run(method(AML.returning([0xFF])), revision: 1).integer == 0xFFFF_FFFF)  // Ones
  let ops: [(UInt8, UInt64)] = [(0x74, 7 &- 3), (0x77, 21), (0x79, 7 << 3), (0x7A, 0), (0x7B, 3), (0x7D, 7),
                                (0x7F, 4), (0x85, 1)]
  for (op, expected) in ops {
    let m = method(AML.returning(AML.op(op, AML.integer(7), AML.integer(3), AML.none)))
    #expect(try run(m).integer == expected, "opcode \(op)")
  }
  // Divide: remainder, then quotient; it returns the quotient.
  let divide = method(AML.op(0x78, AML.integer(17), AML.integer(5), AML.local(0), AML.local(1))
                      + AML.returning(AML.op(0x72, AML.op(0x77, AML.local(1), AML.integer(10), AML.none), AML.local(0),
                                             AML.none)))
  #expect(try run(divide).integer == 32)
  #expect(throws: ACPIError.divideByZero) { try run(method(AML.returning(AML.op(0x85, AML.integer(1), AML.integer(0), AML.none)))) }
  #expect(try run(method(AML.returning(AML.op(0x81, AML.integer(0x80), AML.none)))).integer == 8)  // FindSetLeftBit
  #expect(try run(method(AML.returning(AML.op(0x82, AML.integer(0x80), AML.none)))).integer == 8)  // FindSetRightBit
  #expect(try run(method(AML.returning(AML.ext(0x28, AML.integer(0x1234), AML.none)))).integer == 1234)  // FromBCD
  #expect(try run(method(AML.returning(AML.ext(0x29, AML.integer(1234), AML.none)))).integer == 0x1234)  // ToBCD
}

@Test func controlFlowLoopsBreaksAndReturns() throws {
  // Local0 = 0; Local1 = 0; While (Local0 < 10) { Local0++; If (Local0 == 3) { Continue }
  //   If (Local0 == 8) { Break }; Local1 += Local0 }; Return (Local1)  → 1+2+4+5+6+7 = 25
  let body = AML.store(AML.integer(0), AML.local(0)) + AML.store(AML.integer(0), AML.local(1))
    + AML.whileLoop(AML.op(0x95, AML.local(0), AML.integer(10)),
                    AML.op(0x75, AML.local(0))
                      + AML.ifThen(AML.op(0x93, AML.local(0), AML.integer(3)), [0x9F])
                      + AML.ifThen(AML.op(0x93, AML.local(0), AML.integer(8)), [0xA5])
                      + AML.op(0x72, AML.local(1), AML.local(0), AML.local(1)))
    + AML.returning(AML.local(1))
  #expect(try run(method(body)).integer == 25)
  // If/Else picks one; logical operators give Ones or Zero.
  let pick = method(AML.ifThen(AML.op(0x90, AML.arg(0), AML.op(0x92, AML.arg(1))), AML.returning(AML.integer(1)),
                                else: AML.returning(AML.integer(2))), args: 2)
  #expect(try run(pick, "\\M", [.integer(5), .integer(0)]).integer == 1)
  #expect(try run(pick, "\\M", [.integer(5), .integer(1)]).integer == 2)
  #expect(try run(method(AML.returning(AML.op(0x93, AML.integer(4), AML.integer(4))))).integer == .max)
  // A loop without end stops at the limit.
  #expect(throws: ACPIError.loopLimit) { try run(method(AML.whileLoop([0x01], [0xA3])), loopLimit: 1000) }
  // Recursion without end stops too.
  #expect(throws: ACPIError.callTooDeep) { try run(method(AML.returning(AML.name("M")))) }
}

@Test func aStoreToANameConvertsToItsType() throws {
  // Name (I, 0); Name (S, "abc"); Name (B, Buffer (4) {}) and stores into each.
  let names = AML.nameObject("I", AML.integer(0)) + AML.nameObject("S", AML.string("abc"))
    + AML.nameObject("B", AML.buffer([1, 2, 3, 4]))
  var ns = Namespace()
  let host = RecordingHost()
  try ns.load(try Table(AML.dsdt(names + method(AML.store(AML.string("1Az9"), AML.name("I"))
                                                + AML.store(AML.integer(0x1234), AML.name("S"))
                                                + AML.store(AML.string("xy"), AML.name("B"))))), host: host)
  _ = try ns.evaluate(ns.lookup("\\M")!, host: host)
  // A string's leading hex digits, up to the first that isn't (§19.3.5.7).
  #expect(try ns.evaluate(ns.lookup("\\I")!, host: host).integer == 0x1A)
  // An integer as 16 hex digits.
  #expect(try ns.evaluate(ns.lookup("\\S")!, host: host).string == Array("0000000000001234".utf8))
  // A buffer keeps its length: "xy" and its terminator, then zero.
  #expect(try ns.evaluate(ns.lookup("\\B")!, host: host).bytes == [0x78, 0x79, 0, 0])
  // An empty string won't convert.
  #expect(throws: ACPIError.typeMismatch) { try run(names + method(AML.store(AML.string(""), AML.name("I")))) }
}

@Test func argumentsHoldingReferencesWriteThrough() throws {
  // Name (X, 1); Method (SET, 1) { Store (5, Arg0) }; Method (M) { SET (RefOf (X)); Return (X) }
  let aml = AML.nameObject("X", AML.integer(1))
    + AML.method("SET", args: 1, AML.store(AML.integer(5), AML.arg(0)))
    + method(AML.name("SET") + AML.op(0x71, AML.name("X")) + AML.returning(AML.name("X")))
  #expect(try run(aml).integer == 5)
  // A local holding a reference is replaced, not written through.
  let local = AML.nameObject("X", AML.integer(1))
    + method(AML.store(AML.op(0x71, AML.name("X")), AML.local(0)) + AML.store(AML.integer(9), AML.local(0))
             + AML.returning(AML.name("X")))
  #expect(try run(local).integer == 1)
}

@Test func indexAndDerefReachIntoPackagesAndBuffers() throws {
  let aml = AML.nameObject("P", AML.packageOf([AML.integer(1), AML.integer(2), AML.string("s")]))
    + AML.nameObject("B", AML.buffer([0x10, 0x20]))
    + method(AML.store(AML.integer(7), AML.op(0x88, AML.name("P"), AML.integer(1), AML.none))
             + AML.store(AML.integer(0x1FF), AML.op(0x88, AML.name("B"), AML.integer(0), AML.none))
             + AML.returning(AML.op(0x72, AML.op(0x83, AML.op(0x88, AML.name("P"), AML.integer(1), AML.none)),
                                    AML.op(0x83, AML.op(0x88, AML.name("B"), AML.integer(0), AML.none)), AML.none)))
  #expect(try run(aml).integer == 7 + 0xFF)
  #expect(throws: ACPIError.outOfBounds) {
    try run(AML.nameObject("P", AML.packageOf([AML.integer(1)])) + method(AML.returning(AML.op(0x88, AML.name("P"), AML.integer(5), AML.none))))
  }
  #expect(try run(AML.nameObject("P", AML.packageOf([AML.integer(1), AML.integer(2)])) + method(AML.returning(AML.op(0x87, AML.name("P"))))).integer == 2)
  // DerefOf a string looks the name up.
  #expect(try run(AML.nameObject("Q", AML.integer(3)) + method(AML.returning(AML.op(0x83, AML.string("\\Q"))))).integer == 3)
}

@Test func bufferFieldsReadAndWriteTheirBits() throws {
  // Name (B, Buffer (8) {}); CreateDWordField (B, 2, F); CreateBitField (B, 0, Z)
  let aml = AML.nameObject("B", AML.buffer([UInt8](repeating: 0, count: 8)))
    + method(AML.op(0x8A, AML.name("B"), AML.integer(2), AML.name("F")) + AML.op(0x8D, AML.name("B"), AML.integer(0), AML.name("Z"))
             + AML.store(AML.integer(0xAABB_CCDD), AML.name("F")) + AML.store(AML.integer(1), AML.name("Z"))
             + AML.returning(AML.name("B")))
  #expect(try run(aml).bytes == [0x01, 0x00, 0xDD, 0xCC, 0xBB, 0xAA, 0x00, 0x00])
  // Read back, and a field past the buffer's end refused.
  let read = AML.nameObject("B", AML.buffer([0, 0, 0x34, 0x12]))
    + method(AML.op(0x8B, AML.name("B"), AML.integer(2), AML.name("W")) + AML.returning(AML.name("W")))
  #expect(try run(read).integer == 0x1234)
  #expect(throws: ACPIError.outOfBounds) {
    try run(AML.nameObject("B", AML.buffer([0])) + method(AML.op(0x8A, AML.name("B"), AML.integer(0), AML.name("F"))))
  }
}

@Test func conversionsAndStringOperators() throws {
  func value(_ expression: [UInt8]) throws -> Datum { try run(method(AML.returning(expression))) }
  // Concatenate takes the first operand's type (§19.6.12).
  #expect(try value(AML.op(0x73, AML.string("ab"), AML.integer(0x1F), AML.none)).string == Array("ab000000000000001F".utf8))
  #expect(try value(AML.op(0x73, AML.integer(1), AML.integer(2), AML.none)).bytes == [1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0])
  #expect(try value(AML.op(0x73, AML.buffer([9]), AML.string("A"), AML.none)).bytes == [9, 0x41, 0])
  #expect(try value(AML.op(0x97, AML.buffer([1, 255]), AML.none)).string == Array("1,255".utf8))  // ToDecimalString
  #expect(try value(AML.op(0x97, AML.integer(1234), AML.none)).string == Array("1234".utf8))
  #expect(try value(AML.op(0x98, AML.buffer([0xAB, 1]), AML.none)).string == Array("0xAB,0x01".utf8))  // ToHexString
  #expect(try value(AML.op(0x99, AML.string("0x1F"), AML.none)).integer == 0x1F)  // ToInteger: hex
  #expect(try value(AML.op(0x99, AML.string("123"), AML.none)).integer == 123)  // decimal
  #expect(try value(AML.op(0x96, AML.string("A"), AML.none)).bytes == [0x41, 0])  // ToBuffer
  #expect(try value(AML.op(0x9C, AML.buffer([0x41, 0x42, 0, 0x43]), [0xFF], AML.none)).string == Array("AB".utf8))  // ToString
  #expect(try value(AML.op(0x9E, AML.string("hello"), AML.integer(1), AML.integer(3), AML.none)).string == Array("ell".utf8))
  #expect(try value(AML.op(0x9E, AML.string("hi"), AML.integer(5), AML.integer(3), AML.none)).string == [])  // past the end
  // Comparisons: strings bytewise, then by length; LEqual needs both equal.
  #expect(try value(AML.op(0x95, AML.string("ab"), AML.string("abc"))).integer == .max)  // LLess
  #expect(try value(AML.op(0x94, AML.string("b"), AML.string("abc"))).integer == .max)  // LGreater
  #expect(try value(AML.op(0x93, AML.buffer([1, 2]), AML.buffer([1, 2]))).integer == .max)
  #expect(try value(AML.op(0x93, AML.integer(0x12), AML.string("12"))).integer == .max)  // "12" as hex
}

@Test func matchFindsTheFirstElementMeetingBothConditions() throws {
  // Match (P, MGE, 3, MLT, 6, 0): the first element in [3, 6), from 0.
  let aml = AML.nameObject("P", AML.packageOf([AML.integer(1), AML.string("x"), AML.integer(5), AML.integer(4)]))
    + method(AML.returning(AML.op(0x89, AML.name("P"), [4], AML.integer(3), [3], AML.integer(6), AML.integer(0))))
  #expect(try run(aml).integer == 2)
  let none = AML.nameObject("P", AML.packageOf([AML.integer(1)]))
    + method(AML.returning(AML.op(0x89, AML.name("P"), [1], AML.integer(9), [0], AML.integer(0), AML.integer(0))))
  #expect(try run(none).integer == .max)
}

@Test func objectTypeSizeOfAndCondRefOf() throws {
  let aml = AML.device("DEV", []) + AML.nameObject("S", AML.string("abc"))
    + method(AML.store(AML.op(0x8E, AML.name("DEV")), AML.local(0))  // 6
             + AML.store(AML.op(0x8E, AML.name("S")), AML.local(1))  // 2
             + AML.store(AML.op(0x87, AML.name("S")), AML.local(2))  // 3
             + AML.store(AML.ext(0x12, AML.name("NONE"), AML.none), AML.local(3))  // False
             + AML.store(AML.ext(0x12, AML.name("S"), AML.local(4)), AML.local(5))  // True; Local4 = RefOf (S)
             + AML.returning(AML.op(0x72, AML.op(0x72, AML.op(0x77, AML.local(0), AML.integer(100), AML.none),
                                                 AML.op(0x77, AML.local(1), AML.integer(10), AML.none), AML.none),
                                    AML.op(0x72, AML.local(2), AML.op(0x7B, AML.local(5), AML.integer(1000), AML.none), AML.none), AML.none)))
  #expect(try run(aml).integer == 600 + 20 + 3 + 1000)
}

@Test func loadTimeCodeDecidesWhatExists() throws {
  // Name (G, 1); If (LEqual (G, 1)) { Device (D1) {} } Else { Device (D2) {} }
  var ns = Namespace()
  let aml = AML.nameObject("G", AML.integer(1))
    + AML.ifThen(AML.op(0x93, AML.name("G"), AML.integer(1)), AML.device("D1", []), else: AML.device("D2", []))
    + AML.device("D3", [])  // after the If, as in the table
  try ns.load(try Table(AML.dsdt(aml)), host: RecordingHost())
  #expect(ns.lookup("\\D1") != nil && ns.lookup("\\D2") == nil && ns.lookup("\\D3") != nil)
  #expect(ns.problems.isEmpty)
  // Load-time code that fails is noted, and loading goes on.
  var failing = Namespace()
  try failing.load(try Table(AML.dsdt(AML.store(AML.name("NONE"), AML.name("\\G")) + AML.device("D4", []))),
                   host: RecordingHost())
  #expect(failing.lookup("\\D4") != nil)
  #expect(failing.problems.map { $0.kind } == [.codeFailed(.notFound)])
}

@Test func aMethodsObjectsGoWhenItReturns() throws {
  var ns = Namespace()
  let host = RecordingHost()
  try ns.load(try Table(AML.dsdt(method(AML.nameObject("T", AML.integer(3)) + AML.returning(AML.name("T"))))),
              host: host)
  #expect(try ns.evaluate(ns.lookup("\\M")!, host: host).integer == 3)
  #expect(ns.lookup("\\M.T") == nil)  // gone with the call
  #expect(try ns.evaluate(ns.lookup("\\M")!, host: host).integer == 3)  // and made again
}

@Test func theHostAnswersOSINotifyDebugAndSleep() throws {
  let host = RecordingHost()
  let aml = AML.device("DEV", [])
    + method(AML.store(AML.name("_OSI") + AML.string("Windows 2015"), AML.local(0))
             + AML.store(AML.name("_OSI") + AML.string("Linux"), AML.local(1))
             + AML.op(0x86, AML.name("DEV"), AML.integer(0x80))
             + AML.store(AML.string("hello"), AML.debug) + AML.store(AML.integer(0x2A), AML.debug)
             + AML.ext(0x22, AML.integer(15))
             + AML.returning(AML.op(0x72, AML.op(0x7B, AML.local(0), AML.integer(1), AML.none), AML.local(1), AML.none)))
  var ns = Namespace()
  try ns.load(try Table(AML.dsdt(aml)), host: host)
  #expect(try ns.evaluate(ns.lookup("\\M")!, host: host).integer == 1)  // Windows 2015 yes, Linux no
  #expect(host.notifications.count == 1 && host.notifications[0].0 == ns.lookup("\\DEV") && host.notifications[0].1 == 0x80)
  #expect(host.debugged == ["hello", "0x000000000000002A"])
  #expect(host.slept == 15)
}

@Test func mutexesTakeSyncLevelsInOrderAndEventsCount() throws {
  // Mutex (LOW, 3); Mutex (HIGH, 5): HIGH then LOW is in order; LOW then HIGH isn't.
  let mutexes = AML.ext(0x01, AML.name("LOW"), [3]) + AML.ext(0x01, AML.name("HIGH"), [5])
  let ok = mutexes + method(AML.ext(0x23, AML.name("LOW"), [0xFF, 0xFF]) + AML.ext(0x23, AML.name("HIGH"), [0xFF, 0xFF])
                              + AML.ext(0x27, AML.name("HIGH")) + AML.ext(0x27, AML.name("LOW")) + AML.returning(AML.integer(1)))
  #expect(try run(ok).integer == 1)
  let wrong = mutexes + method(AML.ext(0x23, AML.name("HIGH"), [0xFF, 0xFF]) + AML.ext(0x23, AML.name("LOW"), [0xFF, 0xFF]))
  #expect(throws: ACPIError.mutexOrder) { try run(wrong) }
  // Event: Wait times out (True) until Signal, then succeeds (False).
  let event = AML.ext(0x02, AML.name("EV"))
    + method(AML.store(AML.ext(0x25, AML.name("EV"), AML.integer(10)), AML.local(0)) + AML.ext(0x24, AML.name("EV"))
             + AML.store(AML.ext(0x25, AML.name("EV"), AML.integer(10)), AML.local(1))
             + AML.returning(AML.op(0x72, AML.op(0x7B, AML.local(0), AML.integer(2), AML.none),
                                    AML.op(0x7B, AML.local(1), AML.integer(1), AML.none), AML.none)))
  #expect(try run(event).integer == 2)
}

@Test(.enabled(if: Corpus.isPresent, "no corpus: vx acpi import, vx acpi fetch-qemu"))
func everyIdentifyingMethodInTheCorpusEvaluates() throws {
  // _STA, _HID, _CID, _UID and _ADR, on every machine with its load-time
  // code run: each evaluates, or fails only for want of operation regions
  // (A0d). Any other error is the interpreter's.
  var evaluated = 0, waiting = 0
  for machine in Corpus.machines {
    for set in corpusLoads(machine) {
      var ns = Namespace()
      let host = RecordingHost()
      host.unhandled = Set(0...255)  // no regions: the snapshot test reads real memory
      for file in set { try ns.load(try Table(try #require(Corpus.bytes(machine, file))), host: host) }
      for problem in ns.problems {
        #expect(problem.kind == .codeFailed(.unsupported), "\(machine) \(set): \(problem)")
      }
      for n in 0..<ns.nodes.count where ns.isLive(n) {
        guard ["_STA", "_HID", "_CID", "_UID", "_ADR"].contains(String(decoding: ns.nodes[n].name.bytes, as: UTF8.self)) else {
          continue
        }
        do {
          _ = try ns.evaluate(n, host: host)
          evaluated += 1
        } catch .unsupported {
          waiting += 1
        } catch {
          Issue.record("\(machine) \(set): \(String(decoding: ns.path(n), as: UTF8.self)): \(error)")
        }
      }
    }
  }
  // QEMU's tables alone evaluate 4,990.
  #expect(evaluated > 4900)
  _ = waiting
}
