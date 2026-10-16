// SPDX-License-Identifier: BSD-3-Clause

// fdio over a NodeTree (V2): what it does through Node alone, which is
// how tier 1 reaches services' trees (/svc) until the fs service comes
// with Taisce (V3), when todhchai's comparison with Linux over a volume
// comes too. Files a box allows to be made, a service's text leaves,
// directories, the current directory and paths, a walk, and errno as
// Linux sets it; what needs the fs protocol (truncating, renaming) fails
// as it must on a node that doesn't speak it.

import FDIO
import Glibc
import IPC
import Node
import Testing

/// A tree on its own dispatcher thread, mounted at /svc/t in the
/// namespace fdio resolves in (FDIO.install).
final class Rig: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var thread = pthread_t()

  init() throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { "running\n" })
    tree.file("data/hello", Array("hello, world".utf8))
    tree.directory("box", allowsCreate: true)
    tree.directory("box/inner", allowsCreate: true)
    pthread_create(&thread, nil, { arg in
      let r = Unmanaged<Rig>.fromOpaque(arg!).takeUnretainedValue()
      try? r.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
    let ends = try Channel.create()
    try tree.serve(ends.b)
    let ns = Namespace()
    try ns.mount(ends.a, at: "/svc/t", create: true)
    FDIO.install(ns)
    _ = FDIO.changeDirectory("/")
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

func value<T>(_ r: Result<T, Errno>) -> T? { if case .success(let v) = r { v } else { nil } }
func failure<T>(_ r: Result<T, Errno>) -> Errno? { if case .failure(let e) = r { e } else { nil } }

func read(_ fd: Int32, _ count: Int, at offset: Int64? = nil) -> [UInt8]? {
  var buffer = [UInt8](repeating: 0, count: count)
  let n = buffer.withUnsafeMutableBytes { value(FDIO.read(fd, into: $0, at: offset)) }
  return n.map { Array(buffer[..<$0]) }
}

func write(_ fd: Int32, _ bytes: [UInt8], at offset: Int64? = nil) -> Int? {
  bytes.withUnsafeBytes { value(FDIO.write(fd, $0, at: offset)) }
}

/// One rig at a time: fdio's namespace and descriptors are the process's.
@Suite(.serialized)
struct FDIOTests {
  @Test func filesAreMadeWrittenSoughtAndRead() throws {
    let rig = try Rig()
    defer { rig.stop() }
    let path = "/svc/t/box/notes"
    let fd = try #require(value(FDIO.open(path, flags: OpenFlags.readWrite | OpenFlags.create)))
    #expect(write(fd, Array("one two three".utf8)) == 13)
    #expect(value(FDIO.seek(fd, 4, whence: SEEK_SET)) == 4)
    #expect(read(fd, 3) == Array("two".utf8))
    #expect(value(FDIO.seek(fd, -5, whence: SEEK_END)) == 8)
    #expect(read(fd, 100) == Array("three".utf8))
    #expect(read(fd, 100) == [])  // the end
    #expect(write(fd, Array("TWO".utf8), at: 4) == 3)
    #expect(read(fd, 7, at: 0) == Array("one TWO".utf8))
    #expect(value(FDIO.status(fd))?.size == 13)
    #expect(value(FDIO.close(fd)) != nil)
    #expect(failure(FDIO.close(fd)) == Errno.badDescriptor)
    // O_APPEND writes at the end; O_EXCL refuses what's there.
    let appending = try #require(value(FDIO.open(path, flags: OpenFlags.writeOnly | OpenFlags.append)))
    #expect(write(appending, Array("!".utf8)) == 1)
    _ = FDIO.close(appending)
    #expect(value(FDIO.status(path))?.size == 14)
    #expect(failure(FDIO.open(path, flags: OpenFlags.writeOnly | OpenFlags.create | OpenFlags.exclusive))
              == Errno.exists)
  }

  @Test func servicesLeavesReadAsFiles() throws {
    let rig = try Rig()
    defer { rig.stop() }
    let fd = try #require(value(FDIO.open("/svc/t/status", flags: OpenFlags.readOnly)))
    #expect(read(fd, 100) == Array("running\n".utf8))
    _ = FDIO.close(fd)
    let hello = try #require(value(FDIO.open("/svc/t/data/hello", flags: OpenFlags.readOnly)))
    #expect(read(hello, 5, at: 7) == Array("world".utf8))
    _ = FDIO.close(hello)
  }

  @Test func errorsAreLinuxs() throws {
    let rig = try Rig()
    defer { rig.stop() }
    #expect(failure(FDIO.open("/svc/t/nope", flags: OpenFlags.readOnly)) == Errno.noEntry)
    #expect(failure(FDIO.open("/svc/t/box", flags: OpenFlags.writeOnly)) == Errno.isDirectory)
    #expect(failure(FDIO.open("/svc/t/status", flags: OpenFlags.readOnly | OpenFlags.directory)) == Errno.notDirectory)
    #expect(failure(FDIO.open("/svc/t/box/x", flags: OpenFlags.accessMode)) == Errno.invalid)
    #expect(failure(FDIO.open("/svc/t/missing/x", flags: OpenFlags.writeOnly | OpenFlags.create)) == Errno.noEntry)
    #expect(failure(FDIO.status("/elsewhere")) == Errno.noEntry)
    // What needs the fs protocol: a NodeTree doesn't speak it.
    let fd = try #require(value(FDIO.open("/svc/t/box/f", flags: OpenFlags.readWrite | OpenFlags.create)))
    #expect(write(fd, [1, 2, 3]) == 3)
    #expect(failure(FDIO.truncate(fd, to: 1)) != nil)
    _ = FDIO.close(fd)
  }

  @Test func directoriesAndPaths() throws {
    let rig = try Rig()
    defer { rig.stop() }
    #expect(value(FDIO.makeDirectory("/svc/t/box/made")) != nil)
    #expect(failure(FDIO.makeDirectory("/svc/t/box/made")) == Errno.exists)
    #expect(value(FDIO.status("/svc/t/box/made"))?.isDirectory == true)
    // The current directory: relative paths, getcwd and realpath.
    #expect(value(FDIO.changeDirectory("/svc/t/box")) != nil)
    #expect(FDIO.currentDirectory == "/svc/t/box")
    let fd = try #require(value(FDIO.open("made/file", flags: OpenFlags.writeOnly | OpenFlags.create)))
    _ = FDIO.close(fd)
    #expect(value(FDIO.realPath("made/../made/./file")) == "/svc/t/box/made/file")
    #expect(failure(FDIO.changeDirectory("made/file")) == Errno.notDirectory)
    let listing = try #require(value(FDIO.openDirectory(".")))
    var names: [String] = []
    while let e = listing.read() {
      if e.name != "." && e.name != ".." { names.append(e.name) }
    }
    #expect(names.sorted() == ["inner", "made"])
    #expect(failure(FDIO.removeDirectory("made")) == Errno.notEmpty)
    #expect(value(FDIO.unlink("made/file")) != nil)
    #expect(value(FDIO.removeDirectory("made")) != nil)
    #expect(failure(FDIO.status("made")) == Errno.noEntry)
  }

  @Test func aWalkVisitsEveryNode() throws {
    let rig = try Rig()
    defer { rig.stop() }
    for p in ["/svc/t/box/a", "/svc/t/box/inner/b"] {
      let fd = try #require(value(FDIO.open(p, flags: OpenFlags.writeOnly | OpenFlags.create)))
      _ = FDIO.close(fd)
    }
    let walk = Walk(["/svc/t/box"], order: { $0.name < $1.name })
    var seen: [String] = []
    while let e = walk.next() { seen.append("\(e.info) \(e.path)") }
    #expect(seen == ["directory /svc/t/box", "file /svc/t/box/a", "directory /svc/t/box/inner",
                     "file /svc/t/box/inner/b", "directoryAfter /svc/t/box/inner", "directoryAfter /svc/t/box"])
  }
}
