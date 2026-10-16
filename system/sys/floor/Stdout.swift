// SPDX-License-Identifier: BSD-3-Clause

// stdout: Embedded Swift's print writes through putchar, a line at a time
// (at most 216 bytes; a longer line is split). A process its parent gave
// stdio (D46, td_stdio.h) writes its lines, newlines and all, into its
// stdout ring (stdio.c); any other writes each line as one debuglog
// record. Before stdout is set up, or if the process was started with
// neither, writes go nowhere.
//
// stderr is stdout's, flushed. stdin is the stdin ring, or empty without
// one.

import CroiSyscall
import Synchronization
import TDNative

enum Stdout {
  static let recordMax = 216

  nonisolated(unsafe) static var log: UInt32 = 0
  /// A line, and room for its newline.
  nonisolated(unsafe) static var line = InlineArray<217, UInt8>(repeating: 0)
  nonisolated(unsafe) static var count = 0
  static let lock = RuntimeLock()

  static func put(_ byte: UInt8) {
    if byte == UInt8(ascii: "\n") {
      flushLocked(line: true)  // a debuglog record is a line
      return
    }
    line[count] = byte
    count += 1
    if count == recordMax { flushLocked() }
  }

  static func write(_ text: StaticString) {
    lock.locked {
      unsafe text.withUTF8Buffer { buffer in for unsafe b in unsafe buffer { put(b) } }
    }
  }

  static func flush() { lock.locked { flushLocked() } }

  /// Writes out what's buffered; `ended`: a line ends there (the ring
  /// carries its newline; a debuglog record is a line).
  static func flushLocked(line ended: Bool = false) {
    if ended { line[count] = UInt8(ascii: "\n") }
    let ringed = unsafe withUnsafePointer(to: &line) { p in
      unsafe td_stdio_write(UnsafeRawPointer(p), UInt64(count + (ended ? 1 : 0)))
    }
    if ringed {
      count = 0
      return
    }
    guard count > 0 else { return }
    if log != 0 {
      unsafe withUnsafePointer(to: &line) { p in
        _ = unsafe croi_syscall(CROI_SYS_DEBUGLOG_WRITE, UInt64(log), 0, UInt64(UInt(bitPattern: p)), UInt64(count), 0)
      }
    }
    count = 0
  }
}

/// stdout's bytes from C (the libc's stdio, system/libc/native/stdio.c):
/// written as lines, as putchar's are.
@c public func td_stdout_write(_ bytes: UnsafeRawPointer, _ n: Int) {
  Stdout.lock.locked {
    for i in 0..<n { Stdout.put(unsafe bytes.load(fromByteOffset: i, as: UInt8.self)) }
  }
}

@c public func td_stdout_flush() { Stdout.flush() }

/// stderr's bytes: stdout's, flushed.
@c public func td_stderr_write(_ bytes: UnsafeRawPointer, _ n: Int) {
  unsafe td_stdout_write(bytes, n)
  Stdout.flush()
}

/// stdin's bytes: its ring's (0 at its end), or none without one; stdout
/// flushed first.
@c public func td_stdin_read(_ buffer: UnsafeMutableRawPointer, _ n: Int) -> Int {
  Stdout.flush()
  let got = unsafe td_stdio_read(buffer, UInt64(n))
  return got < 0 ? 0 : Int(got)
}

@c public func putchar(_ c: Int32) -> Int32 {
  Stdout.lock.locked { Stdout.put(UInt8(truncatingIfNeeded: c)) }
  return c
}

/// The runtime's lock: Sys.Lock's design (system/sys/api/Lock.swift) over
/// croi's futexes, for what sits below Sys (the heap, stdout). Not a
/// class: the heap's lock can't come from the heap.
struct RuntimeLock: ~Copyable, Sendable {
  let word = Atomic<UInt32>(0)

  borrowing func locked<R>(_ body: () -> R) -> R {
    if !word.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged {
      while word.exchange(2, ordering: .acquiring) != 0 {
        _ = unsafe croi_syscall(CROI_SYS_FUTEX_WAIT, address, 2, 0, UInt64.max >> 1, 0)
      }
    }
    defer {
      if word.exchange(0, ordering: .releasing) == 2 {
        _ = unsafe croi_syscall(CROI_SYS_FUTEX_WAKE, address, 1, 0, 0, 0)
      }
    }
    return body()
  }

  var address: UInt64 { unsafe withUnsafePointer(to: word) { UInt64(UInt(bitPattern: $0)) } }
}
