// SPDX-License-Identifier: BSD-3-Clause

// rc on a pty (D46; V2's item 6): started with a pty's client end as its
// descriptors 0 to 2 and the pty's Control (CROI_PA_PTY_CONTROL), rc is
// the pty's controller and shares the terminal with its programs. A ring
// has one reader, so one thread reads rc's stdin, and what it reads goes
// to whoever has the terminal: the last program lent it (a foreground
// program given rc's own stdin: its stdin ring), else rc. The pty's events
// are rc's to act on: ^D (rc takes ends) ends that program's input, or
// rc's own when no program has the terminal. ^C, ^\ and the terminal's
// going are notes (sigint, sigquit, sighup): croi has no signals, so rc
// kills the programs that have the terminal (a note's default for them)
// and takes the note itself between commands (Rc.notes). Input typed
// while a program has the terminal is that program's, read or not.
//
// rc on the console: started with no stdio and a /dev/cons (kbdfs's, the
// console's shell), rc opens it as its terminal (Plan 9's init does) and
// reads it as it reads a pty, lending it the same way. A read of nothing
// is ^D's end, of the program that has the terminal or else of rc. Its
// interrupt is kbdfs's note to rc's note group (D87), which kills the
// programs that have the terminal; rc's own reads wake for it.

import FDIO
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
  /// The notes that came for rc, not yet taken.
  var notes: [String] = []
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

  /// The console's: `cons`, an fdio descriptor of /dev/cons, read.
  init(cons: Int32) {
    word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    word.initialize(to: 0)
    _ = try? Thread.spawn { self.readConsole(cons) }
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

  /// /dev/cons, a line a read, to rc's end or an error: an empty read is
  /// ^D's end.
  func readConsole(_ cons: Int32) {
    var buffer = [UInt8](repeating: 0, count: 1024)
    while !lock.withLock({ ended }) {
      guard case .success(let n) = buffer.withUnsafeMutableBytes({ b in FDIO.read(cons, into: b) }) else { break }
      if n > 0 { give(Array(buffer[0..<n])) } else { end() }
    }
    lock.withLock { ended = true }
    bump()
  }

  /// The end of the input of the program that has the terminal, or else
  /// of rc's.
  func end() {
    if let to = lock.withLock({ lent.last }) {
      writing.withLock { _ = try? to.ring.closeInput() }
      reclaim(to.ring)
    } else {
      lock.withLock { ended = true }
      bump()
    }
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

  /// A note for rc, then the programs that have the terminal killed (rc
  /// finds the note there once their wait ends).
  func note(_ name: String) {
    let processes = lock.withLock { () -> [Owned] in
      notes.append(name)
      return lent.map { $0.process }
    }
    bump()
    for p in processes { p.with { h in try? kill(h) } }
  }

  /// The pty's events, as its controller.
  func listen(_ channel: consuming Handle) {
    var control = PtyIPC.ControlClient(channel: channel)
    guard (try? control.takeEnds(true)) != nil else { return }
    while let event = try? control.nextEvent() {
      switch event {
      case .event(.end): end()
      case .event(.interrupt): note("sigint")
      case .event(.quit): note("sigquit")
      case .hangup: note("sighup")
      default: continue
      }
    }
  }

  /// The notes that came, taken.
  func takeNotes() -> [String] {
    lock.withLock {
      defer { notes = [] }
      return notes
    }
  }

  /// rc's next input, waiting until some comes; nil at its end. With
  /// `notes`, empty when a note came first (for rc to take at its prompt).
  func read(notes wake: Bool = false) -> [UInt8]? {
    while true {
      let (bytes, end, noted, generation) = lock.withLock { () -> ([UInt8], Bool, Bool, UInt32) in
        defer { buffer = [] }
        return (buffer, ended, !notes.isEmpty || NoteQueue.shared.waiting, word.pointee)
      }
      if !bytes.isEmpty { return bytes }
      if wake && noted { return [] }
      if end { return nil }
      try? Futex.wait(word, current: generation)
    }
  }

  /// `ring` has the terminal (a program's stdin, `process` its program),
  /// until `reclaim`.
  func lend(_ ring: ChildStream, process: Owned) { lock.withLock { lent.append((ring, process)) } }

  func reclaim(_ ring: ChildStream) { lock.withLock { lent.removeAll { $0.ring === ring } } }
}
