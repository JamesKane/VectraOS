// SPDX-License-Identifier: BSD-3-Clause

// bin/link-test: a program linked against two libraries (D124), started
// by dl-test as Sys starts any program. It names lib/liblinkb.so first,
// then lib/liblinka.so, which needs liblinkb.so too; both have TLS and
// constructors. Checked: they were loaded and bound before main (calls
// through both, into this program and back), liblinkb's constructor ran
// before liblinka's though liblinka loaded last, each thread has
// its own copy of every TLS block from its initial image, at its
// alignment, dl_iterate_phdr reports the three objects, and dlopen finds
// the libraries already loaded. It exits 0 if every check passed.

import CroiRuntime
import Ld
import LibSys
import Sys

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("link-test: FAILED: \(name)")
  }
}

/// The constructors that ran, in order: 1 liblinka's, 2 liblinkb's.
nonisolated(unsafe) var notes: UInt64 = 0

@c public func link_note(_ who: Int32) { notes = notes << 4 | UInt64(who) }
@c public func link_host_value() -> Int32 { 100 }

@_extern(c, "linka_add") func linkaAdd(_ a: Int32) -> Int32
@_extern(c, "linka_reads_b") func linkaReadsB() -> Int
@_extern(c, "linka_tls_address") func linkaTLS() -> UnsafeMutablePointer<Int32>
@_extern(c, "linkb_tls_address") func linkbTLS() -> UnsafeMutablePointer<Int>
@_extern(c, "linkb_zero_address") func linkbZero() -> UnsafeMutablePointer<Int32>

func cString(_ text: StaticString) -> UnsafePointer<CChar> {
  unsafe UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self)
}

/// What a thread finds in its TLS: liblinka's, liblinkb's two and its
/// zeroed one, where they are, and liblinkb's second read from liblinka.
struct Seen: Equatable {
  var a: Int32, b0: Int, b1: Int, zero: Int32, fromA: Int
  var at: UInt
}

func look() -> Seen {
  let a = unsafe linkaTLS(), b = unsafe linkbTLS()
  return unsafe Seen(a: a.pointee, b0: b[0], b1: b[1], zero: linkbZero().pointee, fromA: linkaReadsB(),
                     at: UInt(bitPattern: a))
}

/// dl_iterate_phdr's view: each object's name (bytes: String's == needs
/// Unicode tables only amd64's Embedded toolchain has) and TLS block.
nonisolated(unsafe) var listed: [(name: [UInt8], tls: UInt)] = []

/// What another thread saw.
nonisolated(unsafe) var theirs: Seen?

@main
struct LinkTest {
  static func main() {
    check(notes == 0x21, "liblinkb's constructor ran before liblinka's")
    check(linkaAdd(1) == 1 + 30 + 100 + 1, "calls through both libraries and back into the program")

    let mine = look()
    check(mine == Seen(a: 5, b0: 7, b1: 8, zero: 0, fromA: 8, at: mine.at), "TLS from each library's image")
    check(mine.at % 64 == 0, "at its alignment")
    unsafe linkaTLS().pointee = 6
    unsafe linkbTLS()[1] = 9
    check(linkaReadsB() == 9, "liblinka reads liblinkb's, by initial-exec")
    if let thread = try? Thread.spawn({ theirs = look() }) {
      _ = try? Thread.join(thread)
    }
    check(theirs.map { $0.a == 5 && $0.b1 == 8 && $0.at != mine.at } ?? false, "another thread's own, from the images")
    check(unsafe linkaTLS().pointee == 6, "and this thread's kept")

    _ = unsafe dl_iterate_phdr({ info, _, _ in
      guard let info = unsafe info?.pointee, let name = unsafe info.dlpi_name else { return 1 }
      var bytes: [UInt8] = []
      while unsafe name[bytes.count] != 0 { bytes.append(UInt8(bitPattern: unsafe name[bytes.count])) }
      listed.append((bytes, UInt(bitPattern: unsafe info.dlpi_tls_data)))
      return 0
    }, nil)
    check(listed.map { $0.name } == [[], Array("liblinkb.so".utf8), Array("liblinka.so".utf8)],
          "dl_iterate_phdr reports the program and both, in load order")
    check(listed.count == 3 && listed[2].tls == mine.at, "with this thread's TLS")

    let before = DynamicLinker.libraries.count
    let a = unsafe dlopen(cString("liblinka.so\0"), RTLD_NOW)
    let add = unsafe a.flatMap { unsafe dlsym($0, cString("linka_add\0")) }
    check(unsafe add.map { unsafe unsafeBitCast($0, to: (@convention(c) (Int32) -> Int32).self)(2) } == 2 + 30 + 100 + 1,
          "dlopen finds liblinka loaded")
    check(before == 2 && DynamicLinker.libraries.count == 2, "and loads nothing again")

    print("link-test: \(checks - failures) of \(checks) checks passed")
    td_exit(failures == 0 ? 0 : 1)
  }
}
