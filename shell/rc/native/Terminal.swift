// SPDX-License-Identifier: BSD-3-Clause

// rc's terminal: started with no stdio and a /dev/cons (kbdfs's on the
// console, the terminal's in a cpu session), rc opens it as its terminal,
// as Plan 9's init opens #c/cons, and shares it with its programs. One
// thread reads it, and what it reads goes to whoever has the terminal: the
// last program lent it (a foreground program given rc's own stdin: its
// stdin ring), else rc. A read of nothing is ^D's end, of the program
// that has the terminal or else of rc. Interrupts are notes to rc's note
// group (D87), posted by whatever serves /dev/cons, which kill the
// programs that have the terminal; rc's own reads wake for them. Input
// typed while a program has the terminal is that program's, read or not.

import FDIO
import Sys

final class Terminal: @unchecked Sendable {
  let lock = Lock()
  /// A lent ring's writers (the reader, giving bytes or ^D's end) take
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

  /// The process's terminal, when it has /dev/cons.
  nonisolated(unsafe) static var current: Terminal? = nil

  /// `cons`, an fdio descriptor of /dev/cons, read.
  init(cons: Int32) {
    word = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    word.initialize(to: 0)
    _ = try? Thread.spawn { self.readConsole(cons) }
  }

  func bump() {
    _ = lock.withLock { word.pointee &+= 1 }
    Futex.wake(word, count: Int.max)
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

  /// rc's next input, waiting until some comes; nil at its end. With
  /// `notes`, empty when a note came first (for rc to take at its prompt).
  func read(notes wake: Bool = false) -> [UInt8]? {
    while true {
      let (bytes, end, noted, generation) = lock.withLock { () -> ([UInt8], Bool, Bool, UInt32) in
        defer { buffer = [] }
        return (buffer, ended, NoteQueue.shared.waiting, word.pointee)
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
