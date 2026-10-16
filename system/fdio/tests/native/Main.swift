// SPDX-License-Identifier: BSD-3-Clause

// bin/fdio-test: fdio natively (V2, tier 1), through POSIX's C names as a
// tier 1 program calls them (open, read, write, lseek, stat, readdir,
// mkdir, chdir, getcwd, unlink), on a tree this program serves itself on
// a thread of its own, installed as fdio's namespace. userboot starts it
// (boot-fdio-test, amd64 and arm64); it exits 0 if every check passed.

import FDIO
import IPC
import Node
import Sys
import VectraOSLibc

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: String) {
  checks += 1
  if !condition {
    failures += 1
    print("fdio-test: FAILED: \(name)")
  }
}

/// `count` bytes read from `fd`, or nil on an error.
func readBytes(_ fd: Int32, _ count: Int) -> [UInt8]? {
  var buffer = [UInt8](repeating: 0, count: count)
  let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, count) }
  return n < 0 ? nil : Array(buffer[..<n])
}

func writeBytes(_ fd: Int32, _ bytes: [UInt8]) -> Int {
  bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
}

@main struct FDIOTest {
  static func main() {
    // The tree, served from a dispatcher thread, at /svc/t.
    let dispatcher: IPCDispatcher
    do {
      dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { "running\n" })
      tree.directory("box", allowsCreate: true)
      let d = dispatcher
      _ = try Thread.spawn { _ = try? d.run() }
      let ends = try Channel.create()
      try tree.serve(ends.b)
      let ns = Namespace()
      try ns.mount(ends.a, at: "/svc/t", create: true)
      FDIO.install(ns)
    } catch {
      print("fdio-test: FAILED: no tree")
      exit(1)
    }

    // A file made, written, sought, read and stat-ed.
    let fd = open("/svc/t/box/notes", O_RDWR | O_CREAT, 0o644)
    check(fd > 2, "open makes a file")
    check(writeBytes(fd, Array("one two three".utf8)) == 13, "write")
    check(lseek(fd, 4, SEEK_SET) == 4, "lseek")
    check(readBytes(fd, 3) == Array("two".utf8), "read")
    var st = stat()
    check(fstat(fd, &st) == 0 && st.st_size == 13 && (st.st_mode & UInt32(S_IFMT)) == UInt32(S_IFREG), "fstat")
    check(close(fd) == 0, "close")
    check(close(fd) == -1 && errno == EBADF, "close twice: EBADF")
    check(open("/svc/t/nope", O_RDONLY) == -1 && errno == ENOENT, "a missing file: ENOENT")

    // A service's leaf, read as a file.
    let leaf = open("/svc/t/status", O_RDONLY)
    check(leaf > 2 && readBytes(leaf, 64) == Array("running\n".utf8), "a service's leaf reads as a file")
    _ = close(leaf)

    // Directories, the current one, and listings.
    check(mkdir("/svc/t/box/made", 0o755) == 0, "mkdir")
    check(stat("/svc/t/box/made", &st) == 0 && (st.st_mode & UInt32(S_IFMT)) == UInt32(S_IFDIR), "stat a directory")
    check(chdir("/svc/t/box") == 0, "chdir")
    var cwd = [CChar](repeating: 0, count: 256)
    check(getcwd(&cwd, 256) != nil && String(cString: cwd) == "/svc/t/box", "getcwd")
    var names: [String] = []
    if let dir = opendir(".") {
      while let e = readdir(dir) {
        let name = withUnsafeBytes(of: e.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if name != "." && name != ".." { names.append(name) }
      }
      closedir(dir)
    }
    check(names.sorted() == ["made", "notes"], "readdir lists what's there")
    check(unlink("notes") == 0 && rmdir("made") == 0, "unlink and rmdir, relative")
    check(stat("notes", &st) == -1 && errno == ENOENT, "and they've gone")

    print("fdio-test: \(checks - failures) of \(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
  }
}
