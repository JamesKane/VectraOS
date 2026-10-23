// SPDX-License-Identifier: BSD-3-Clause

// bin/dl-test: dlopen on croi (V2, after todhchai's dl-test.c): a C
// library and an Embedded Swift one loaded from bootfs's lib/, their
// symbols found and called, theirs calling back into this program's
// exports and heap; the errors a missing library or symbol gives; and
// fresh copies, as hot reload loads them (D122); and bin/link-test, a
// program linked against two libraries, started as Sys starts any program
// (D124), which checks itself and exits 0, and bin/link-stale, linked
// against a build of a library bootfs doesn't have, which must be
// refused. It is
// a dlopen host (EXPORT_DYNAMIC: its runtime linked whole and exported).
// userboot starts it (userboot.next=bin/dl-test, the boot-dl test); it
// exits 0 if every check passed.

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
    print("dl-test: FAILED: \(name)")
  }
}

func cString(_ text: StaticString) -> UnsafePointer<CChar> {
  unsafe UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self)
}

/// A C string's bytes are `text`'s.
func same(_ c: UnsafePointer<CChar>?, _ text: StaticString) -> Bool {
  guard let c = unsafe c, unsafe strlen(c) == text.utf8CodeUnitCount else { return false }
  return unsafe memcmp(c, text.utf8Start, text.utf8CodeUnitCount) == 0
}

/// Says dlerror's message, if there is one.
func sayError() {
  if let e = unsafe dlerror() { unsafe td_stdout_write(e, strlen(e)); print("") }
}

/// What the C library calls back into.
@c public func dl_host_value() -> Int32 { 1000 }

typealias Initialized = @convention(c) () -> Int32
typealias Add = @convention(c) (Int32, Int32) -> Int32
typealias Name = @convention(c) (Int32) -> UnsafePointer<CChar>?
typealias Numbers = @convention(c) (Int32) -> UnsafeMutablePointer<Int32>?
typealias Sum = @convention(c) (Int) -> Int

@main
struct DlTest {
  static func main() {
    let c = unsafe dlopen(cString("libdltest.so\0"), RTLD_NOW)
    if unsafe c == nil { sayError() }
    check(unsafe c != nil, "dlopen libdltest.so")
    if let c = unsafe c { unsafe library(c) }
    let me = unsafe dlopen(nil, RTLD_NOW)
    let own = unsafe dlsym(me, cString("dl_host_value\0"))
    check(unsafe own.map { unsafe unsafeBitCast($0, to: Initialized.self)() } == 1000, "the program's own symbols")

    let swift = unsafe dlopen(cString("libdlswift.so\0"), RTLD_NOW)
    if unsafe swift == nil { sayError() }
    check(unsafe swift != nil, "dlopen libdlswift.so")
    if let swift = unsafe swift {
      let sum = unsafe dlsym(swift, cString("dl_swift_sum\0"))
      check(unsafe sum.map { unsafe unsafeBitCast($0, to: Sum.self)(10) } == 45 + 9 + 1, "Swift through Sys")
    }

    check(unsafe dlopen(cString("libnothing.so\0"), RTLD_NOW) == nil, "a missing library")
    let e = unsafe dlerror()
    check(unsafe e != nil, "dlerror says why")
    if let e = unsafe e {
      unsafe td_stdout_write(e, strlen(e))
      print("")
    }
    check(unsafe dlerror() == nil, "dlerror clears")
    if let c = unsafe c {
      let closes = unsafe (dlclose(c), dlclose(c), dlclose(c))
      check(closes == (0, 0, -1), "dlclose counts")
    }

    fresh()
    linked()

    print("dl-test: \(checks - failures) of \(checks) checks passed")
    td_exit(failures == 0 ? 0 : 1)
  }

  /// Fresh copies of libdlswift.so (hot reload's, D122): each at an
  /// address of its own, each running, made runnable with a VMEX resource
  /// cut from the system resource userboot gives.
  static func fresh() {
    guard let system = StartupHandles.take(HandleType.info(HandleType.resource(.system))),
      let vmex = try? Resource.create(parent: Handle(raw: system), kind: .system, base: SystemResource.vmex, size: 1,
                                      name: "dl-test")
    else { return check(false, "a VMEX resource") }
    guard let file = DynamicLinker.bootfsFile("lib/libdlswift.so") else { return check(false, "bootfs's libdlswift.so") }
    var bases: [UInt] = []
    for _ in 0..<2 {
      guard let i = DynamicLinker.openFresh(file.vmo, offset: file.offset, size: file.length, name: "libdlswift.so",
                                            vmex: vmex.raw)
      else {
        if let why = DynamicLinker.takeFailure() { print("dl-test: \(why)") }
        return check(false, "a fresh copy")
      }
      let sum = DynamicLinker.symbol("dl_swift_sum", in: i)
      check(sum.map { unsafe unsafeBitCast($0, to: Sum.self)(10) } == 45 + 9 + 1, "a fresh copy runs")
      bases.append(DynamicLinker.libraries[i].base)
    }
    check(bases.count == 2 && bases[0] != bases[1], "each copy at an address of its own")
  }

  /// bin/link-test, started from bootfs and linked with its libraries as
  /// it starts: it exits 0 if its own checks passed.
  static func linked() {
    guard let job = StartupHandles.take(HandleType.info(HandleType.jobDefault)).map({ Handle(raw: $0) }) else {
      return check(false, "a job, to start bin/link-test in")
    }
    guard let file = DynamicLinker.bootfsFile("bin/link-test") else { return check(false, "bootfs's bin/link-test") }
    let entry = ProgramEntry(image: file.vmo, offset: Int(file.offset), length: Int(file.length), name: "bin/link-test")
    do throws(Status) {
      let process = try Process.create(job: job, name: "link-test")
      let thread = try Process.start(process, entry: entry, Startup())
      _ = try process.wait(for: Signals.terminated, deadline: Clock.monotonic() + 20_000_000_000)
      check(try Process.info(process).returnCode == 0, "a program linked with its libraries ran and passed")
      _ = consume thread
    } catch {
      check(false, "bin/link-test started")
    }
    guard let stale = DynamicLinker.bootfsFile("bin/link-stale") else { return check(false, "bootfs's bin/link-stale") }
    let staleEntry = ProgramEntry(image: stale.vmo, offset: Int(stale.offset), length: Int(stale.length),
                                  name: "bin/link-stale")
    guard let process = try? Process.create(job: job, name: "link-stale") else { return check(false, "a process") }
    let started = try? Process.start(process, entry: staleEntry, Startup())
    check(started == nil, "a program linked against another build of a library is refused")
  }

  /// The C library: its symbols, constructor, relocations, and calls back
  /// into the program and its heap.
  static func library(_ c: UnsafeMutableRawPointer) {
    let initialized = unsafe dlsym(c, cString("dl_initialized\0"))
    let add = unsafe dlsym(c, cString("dl_add\0"))
    let name = unsafe dlsym(c, cString("dl_name\0"))
    let numbers = unsafe dlsym(c, cString("dl_numbers\0"))
    guard let initialized = unsafe initialized, let add = unsafe add, let name = unsafe name,
          let numbers = unsafe numbers else { return check(false, "dlsym") }
    check(true, "dlsym")
    check(unsafe unsafeBitCast(initialized, to: Initialized.self)() == 41, "its constructor ran")
    check(unsafe unsafeBitCast(add, to: Add.self)(2, 3) == 1005, "a call back into the program")
    check(unsafe same(unsafeBitCast(name, to: Name.self)(1), "two"), "its relative relocations")
    guard let n = unsafe unsafeBitCast(numbers, to: Numbers.self)(8) else { return check(false, "the program's heap") }
    check(unsafe n[7] == 49, "the program's heap")
    unsafe free(n)  // the same heap
    check(unsafe dlopen(cString("libdltest.so\0"), RTLD_NOW) == c, "opened again: the same")
    let missing = unsafe dlsym(c, cString("nonexistent\0"))
    check(unsafe missing == nil && dlerror() != nil, "a missing symbol")
    // RTLD_DEFAULT, ((void *)0), which Swift doesn't import: nil.
    check(unsafe dlsym(nil, cString("dl_add\0")) == add, "the global scope finds a library's")
  }
}
