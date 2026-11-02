// SPDX-License-Identifier: BSD-3-Clause

// bin/time: the time service (M6g), Fuchsia's Timekeeper in miniature. It
// reads a real-time clock and publishes UTC in the UTC page the launcher
// gave it writable (`clock`, D48), which every process maps and reads
// (clock_gettime's CLOCK_REALTIME): on amd64 the PC's, through ports 0x70
// and 0x71 (its manifest's `resource ioport`); elsewhere a driver's,
// which devmgr mounts at dev/rtc0 (its manifest's `use devmgr`), waited
// for 20 s. Its tree: `status`, what it set and from what; `ctl`, `set
// DATE`, a driver's clock set and UTC from it. Without a clock UTC stays
// the launcher's backstop.

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
    let clock: DeviceClock?
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
      clock = nil
    #else
      // A devicetree machine's clock is a driver's, at devmgr's dev/rtc0
      // once devmgr has bound it.
      let page: UTCPage
      do throws(Status) { page = try UTCPage(pageHandle) } catch { Process.fail("can't map the UTC page: \(error.rawValue)") }
      let c = DeviceClock(page, try? Namespace(start))
      clock = c
      status = ""
      // Waited for on a thread of its own: the tree answers meanwhile, so
      // whatever uses the time service doesn't wait for the clock.
      _ = try? Thread.spawn {
        if let set = c.publish(waiting: 20) {
          print("time: UTC set from \(DeviceClock.path): \(set)")
        } else {
          print("time: no clock at \(DeviceClock.path): UTC stays the backstop")
        }
      }.release()
    #endif
    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { clock?.status ?? status })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        // `set 2026-11-01T18:04:05Z`: the clock set, and UTC from it.
        let words = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A }).map { String(decoding: $0, as: UTF8.self) }
        guard words.count == 2, words[0].utf8.elementsEqual("set".utf8), let clock, clock.set(words[1]) else {
          throw .invalid
        }
      })
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve")
    }
  }
}

/// A devicetree machine's real-time clock, a driver's `rtc` at devmgr's
/// dev/rtc0 (`2026-11-01T18:04:05Z`), and the UTC page it sets.
final class DeviceClock: @unchecked Sendable {
  static let path = "/mnt/devmgr/dev/rtc0/rtc"
  let page: UTCPage
  let ns: Namespace?
  let lock = Lock()
  var line = "no rtc\n"

  init(_ page: consuming UTCPage, _ ns: Namespace?) {
    self.page = page
    self.ns = ns
  }

  /// UTC published from the clock, waiting up to `seconds` for it: the
  /// date it gave.
  func publish(waiting seconds: Int) -> String? {
    let deadline = Clock.monotonic() + Int64(seconds) * 1_000_000_000
    while true {
      if let text = ns?.readText(DeviceClock.path), let utc = RTC.unixNanoseconds(text: text) {
        let date = String(decoding: text.utf8.filter { $0 != 0x0A }, as: UTF8.self)
        page.publish(utc: utc, error: TimeService.second)
        lock.withLock { line = "set from \(DeviceClock.path) \(date) utc \(utc)\n" }
        return date
      }
      guard Clock.monotonic() < deadline else { return nil }
      sleep(until: Clock.monotonic() + 250_000_000)
    }
  }

  /// The clock set to `date`, then UTC published from it.
  func set(_ date: String) -> Bool {
    guard RTC.unixNanoseconds(text: date) != nil, ns?.writeText(DeviceClock.path, date + "\n") == true else { return false }
    return publish(waiting: 0) != nil
  }

  var status: String { lock.withLock { line } }
}
