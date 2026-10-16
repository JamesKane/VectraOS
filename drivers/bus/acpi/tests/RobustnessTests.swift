// SPDX-License-Identifier: BSD-3-Clause

// A0f: hostile AML ends in an error, never a trap or an exhausted process.

import Glibc
@testable import TDACPI
import Testing

@Test func aReferenceToAReturnedCallsLocalIsCaught() throws {
  // SET stores RefOf (its Local0) in a global, then returns; M reads through it.
  let aml = AML.nameObject("G", AML.integer(0))
    + AML.method("SET", AML.store(AML.integer(5), AML.local(0)) + AML.op(0x9D, AML.op(0x71, AML.local(0)), AML.name("G")))
    + method(AML.name("SET") + AML.returning(AML.op(0x83, AML.name("G"))))
  #expect(throws: ACPIError.uninitialized) { try run(aml) }
}

@Test func aReferenceToItselfIsCaught() throws {
  // Local0 = RefOf (Local0), then Local0 + 1.
  let aml = method(AML.op(0x9D, AML.op(0x71, AML.local(0)), AML.local(0))
                   + AML.returning(AML.op(0x72, AML.local(0), AML.integer(1), AML.none)))
  #expect(throws: ACPIError.recursive) { try run(aml) }
}

@Test func objectsDependingOnThemselvesAreCaught() throws {
  // A region whose offset is its own field; an index field indexed through itself.
  let region = AML.region("R", space: 0, AML.name("F"), AML.integer(4)) + AML.field("R", 0x03, [.named("F", 32)])
    + method(AML.returning(AML.name("F")))
  #expect(throws: ACPIError.recursive) { try run(region) }
  let index = AML.region("IO", space: 1, AML.integer(0x70), AML.integer(2)) + AML.field("IO", 0x01, [.named("DAT", 8)])
    + AML.indexField("IXF", "DAT", 0x01, [.named("IXF", 8)]) + method(AML.returning(AML.name("IXF")))
  #expect(throws: ACPIError.recursive) { try run(index) }
}

@Test func sizesAndOffsetsAreBounded() throws {
  // CreateField past the buffer by a wrapping offset.
  let wrap = AML.nameObject("B", AML.buffer([0, 0, 0, 0]))
    + method(AML.ext(0x13, AML.name("B"), AML.integer(0xFFFF_FFFF_FFFF_FFF0), AML.integer(0x20), AML.name("F")))
  #expect(throws: ACPIError.outOfBounds) { try run(wrap) }
  // A string doubled forty times.
  let doubling = method(AML.store(AML.string("ab"), AML.local(0)) + AML.store(AML.integer(0), AML.local(1))
                        + AML.whileLoop(AML.op(0x95, AML.local(1), AML.integer(40)),
                                        AML.store(AML.op(0x73, AML.local(0), AML.local(0), AML.none), AML.local(0))
                                          + AML.op(0x75, AML.local(1))))
  #expect(throws: ACPIError.tooLarge) { try run(doubling) }
  // A field of two million bits.
  let huge = AML.region("R", space: 0, AML.integer(0), AML.integer(0x100000)) + AML.field("R", 0x01, [.named("BIG", 1 << 21)])
    + method(AML.returning(AML.name("BIG")))
  #expect(throws: ACPIError.tooLarge) { try run(huge) }
}

@Test func nestingAndRunningTimeAreBounded() throws {
  // A thousand Ifs inside one another, in a method.
  var nested: [UInt8] = AML.returning(AML.integer(1))
  for _ in 0..<1000 { nested = AML.ifThen([0x01], nested) }
  #expect(throws: ACPIError.tooDeep) { try run(method(nested)) }
  // Loops inside loops, each within its own limit, but past the budget.
  var ns = Namespace()
  ns.stepLimit = 100_000
  let host = RecordingHost()
  let inner = AML.store(AML.integer(0), AML.local(1))
    + AML.whileLoop(AML.op(0x95, AML.local(1), AML.integer(1000)), AML.op(0x75, AML.local(1)))
  let loops = AML.whileLoop(AML.op(0x95, AML.local(0), AML.integer(1000)), inner + AML.op(0x75, AML.local(0)))
  try ns.load(try Table(AML.dsdt(method(AML.store(AML.integer(0), AML.local(0)) + loops))), host: host)
  #expect(throws: ACPIError.stepLimit) { try ns.evaluate(ns.lookup("\\M")!, host: host) }
}

final class StackRun: @unchecked Sendable { var result = "" }

/// The deepest code the limits allow: a method calling itself, each call
/// inside Ifs and expressions, until a limit stops it.
func deepestCode() -> String {
  var body = AML.name("M") + AML.op(0x72, AML.arg(0), AML.integer(1), AML.none)
  for _ in 0..<3 { body = AML.op(0x72, body, AML.integer(1), AML.none) }
  var nested = AML.returning(body)
  for _ in 0..<3 { nested = AML.ifThen([0x01], nested) }
  var ns = Namespace()
  let host = RecordingHost()
  do {
    try ns.load(try Table(AML.dsdt(AML.method("M", args: 1, nested))), host: host)
    _ = try ns.evaluate(ns.lookup("\\M")!, [.integer(0)], host: host)
    return "returned"
  } catch {
    return "\(error)"
  }
}

@Test func theDeepestCodeTheLimitsAllowFitsAKnownStack() {
  // Measured (2026-10-09): 1 MiB in a debug build, 128 KiB in release
  // (64 KiB overflows). This runs it on a 2 MiB thread, twice the debug
  // need; devmgr gives its interpreter thread 256 KiB.
  let run = StackRun()
  var attr = pthread_attr_t()
  pthread_attr_init(&attr)
  pthread_attr_setstacksize(&attr, 2 << 20)
  var thread = pthread_t()
  let box = Unmanaged.passRetained(run).toOpaque()
  pthread_create(&thread, &attr, { arg in
    let run = Unmanaged<StackRun>.fromOpaque(arg!).takeRetainedValue()
    run.result = deepestCode()
    return nil
  }, box)
  pthread_join(thread, nil)
  #expect(run.result == "tooDeep")
}
