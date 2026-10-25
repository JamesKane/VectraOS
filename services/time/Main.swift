// SPDX-License-Identifier: BSD-3-Clause

// bin/time: the time service (M6g), Fuchsia's Timekeeper in miniature. It
// reads the PC's real-time clock through ports 0x70 and 0x71 (its manifest's
// `resource ioport`) and publishes UTC in the UTC page the launcher gave it
// writable (`clock`, D48), which every process maps and reads
// (clock_gettime's CLOCK_REALTIME). Its tree: `status`, what it set and
// from what. amd64's for now: the other machines' RTCs come later, and
// there it publishes nothing (UTC stays the launcher's backstop).

import IPC
import Node
import Sys

enum CMOS {
  static func read(_ register: UInt8) -> UInt8 {
    IOPorts.write(0x70, width: 1, UInt32(register))
    return UInt8(truncatingIfNeeded: IOPorts.read(0x71, width: 1))
  }

  /// The clock's registers, read outside an update and twice alike, so no
  /// rollover falls between two of them.
  static func reading() -> RTCReading {
    func once() -> RTCReading {
      var spins = 0
      while read(RTCRegister.statusA) & 0x80 != 0 && spins < 1_000_000 { spins += 1 }
      return RTCReading(seconds: read(RTCRegister.seconds), minutes: read(RTCRegister.minutes),
                        hours: read(RTCRegister.hours), day: read(RTCRegister.day), month: read(RTCRegister.month),
                        year: read(RTCRegister.year), century: read(RTCRegister.century),
                        statusB: read(RTCRegister.statusB))
    }
    var last = once()
    for _ in 0..<5 {
      let again = once()
      if again == last { return again }
      last = again
    }
    return last
  }
}

@main struct TimeService {
  /// The RTC's resolution: the error UTC is published with.
  static let second: UInt64 = 1_000_000_000

  static func main() {
    let start = Startup.current
    guard let pageHandle = start.take(HandleType.info(HandleType.vmoUTC, 1)) else {
      Process.fail("no UTC page to write (its manifest's `clock`)")
    }
    let status: String
    #if arch(x86_64)
      guard let resource = start.take(HandleType.info(HandleType.resource(.ioport))) else {
        Process.fail("no ioport resource (its manifest's `resource ioport`)")
      }
      do throws(Status) {
        try IOPorts.request(resource, base: 0x70, count: 2)
      } catch {
        Process.fail("can't have the CMOS's ports: \(error.rawValue)")
      }
      let reading = CMOS.reading()
      guard let utc = reading.unixNanoseconds, let set = reading.date else { Process.fail("the RTC says nothing a date fits") }
      do throws(Status) {
        try UTCPage(pageHandle).publish(utc: utc, error: second)
      } catch {
        Process.fail("can't write the UTC page: \(error.rawValue)")
      }
      func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
      let when = "\(set.year)-\(two(set.month))-\(two(set.day))T\(two(set.hour)):\(two(set.minute)):\(two(set.second))Z"
      print("time: UTC set from the RTC: \(when)")
      status = "set from rtc \(when) utc \(utc)\n"
    #else
      _ = consume pageHandle
      print("time: no RTC on this machine yet: UTC stays the backstop")
      status = "no rtc\n"
    #endif
    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { status })
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve")
    }
  }
}
