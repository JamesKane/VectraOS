// SPDX-License-Identifier: BSD-3-Clause

// rc on a pty (D46; V2's item 6): started with a pty's client end as its
// descriptors 0 to 2 and the pty's Control (CROI_PA_PTY_CONTROL), rc is
// the pty's controller and shares the terminal with its programs. A ring
// has one reader, so one thread reads rc's stdin, and what it reads goes
// to whoever has the terminal: the last program lent it (a foreground
// program given rc's own stdin: its stdin ring), else rc. The pty's events
// are rc's to act on: ^D (rc takes ends) ends that program's input, or
// rc's own when no program has the terminal; ^C and ^\ kill the programs
// that have it (croi has no signals: a shell kills its foreground job).
// Input typed while a program has the terminal is that program's, read or
// not.

import IPC
import Sys
import TDFloor

final class Terminal: @unchecked Sendable {
  let lock = Lock()
  /// A lent ring's writers (the input's reader, the ^D listener) take
  /// turns: a ring has one writer at a time.
  let writing = Lock()
  /// What came for rc, and whether its input has ended.
  var buffer: [UInt8] = []
  var ended = false
  /// The programs lent the terminal (their stdin rings and processes),
  /// the last the one input goes to.
  var lent: [(ring: ChildStream, process: Owned)] = []
  /// A generation word rc's reads wait on (a futex).
  let word: UnsafeMutablePointer<UInt32>

  /// The process's terminal, when it's on a pty.
  nonisolated(unsafe) static var current: Terminal? = nil

  init(control: consuming Handle) {
    word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    word.initialize(to: 0)
    let raw = control.release()
    _ = try? Thread.spawn { self.readInput() }
    _ = try? Thread.spawn { self.listen(Handle(raw: raw)) }
  }

  func bump() {
    _ = lock.withLock { word.pointee &+= 1 }
    Futex.wake(word, count: Int.max)
  }

  /// stdin, to its end (the pty's going).
  func readInput() {
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
      let n = buffer.withUnsafeMutableBytes { b in td_stdin_read(b.baseAddress!, b.count) }
      guard n > 0 else { break }
      give(Array(buffer[0..<n]))
    }
    lock.withLock { ended = true }
    bump()
  }

  /// Bytes for whoever has the terminal.
  func give(_ bytes: [UInt8]) {
    while let to = lock.withLock({ lent.last }) {
      if writing.withLock({ (try? to.ring.write(bytes)) != nil }) { return }
      reclaim(to.ring)  // it's gone
    }
    lock.withLock { buffer += bytes }
    bump()
  }

  /// The pty's events, as its controller.
  func listen(_ channel: consuming Handle) {
    var control = PtyIPC.ControlClient(channel: channel)
    guard (try? control.takeEnds(true)) != nil else { return }
    while let event = try? control.nextEvent() {
      guard case .event(let e) = event else { continue }
      switch e {
      case .end:
        // The program's input's end, or rc's.
        if let to = lock.withLock({ lent.last }) {
          writing.withLock { _ = try? to.ring.closeInput() }
          reclaim(to.ring)
        } else {
          lock.withLock { ended = true }
          bump()
        }
      case .interrupt, .quit:
        for p in lock.withLock({ lent.map { $0.process } }) { p.with { h in try? kill(h) } }
      }
    }
  }

  /// rc's next input, waiting until some comes; nil at its end.
  func read() -> [UInt8]? {
    while true {
      let (bytes, end, generation) = lock.withLock { () -> ([UInt8], Bool, UInt32) in
        defer { buffer = [] }
        return (buffer, ended, word.pointee)
      }
      if !bytes.isEmpty { return bytes }
      if end { return nil }
      try? Futex.wait(word, current: generation)
    }
  }

  /// `ring` has the terminal (a program's stdin, `process` its program),
  /// until `reclaim`.
  func lend(_ ring: ChildStream, process: Owned) { lock.withLock { lent.append((ring, process)) } }

  func reclaim(_ ring: ChildStream) { lock.withLock { lent.removeAll { $0.ring === ring } } }
}
