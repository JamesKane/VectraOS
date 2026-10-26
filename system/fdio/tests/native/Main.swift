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

// nftw (<ftw.h>, C's only: not in the libc's module map, whose change
// would rebuild the toolchain's stdlib). Its callback counts entries by
// kind into globals: a C function can't capture.
@_extern(c, "nftw")
func nftw(_ path: UnsafePointer<CChar>, _ fn: @convention(c) (UnsafePointer<CChar>?, UnsafeRawPointer?, Int32,
          UnsafeMutableRawPointer?) -> Int32, _ nopenfd: Int32, _ flags: Int32) -> Int32
nonisolated(unsafe) var walkFiles = 0, walkDirectories = 0, walkPostorder = 0, walkDeepest: Int32 = 0
let walkVisit: @convention(c) (UnsafePointer<CChar>?, UnsafeRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32 = {
  _, _, type, ftw in
  switch type {
  case 0: walkFiles += 1
  case 1: walkDirectories += 1
  case 5: walkPostorder += 1
  default: break
  }
  // struct FTW: base, then level.
  if let ftw { walkDeepest = max(walkDeepest, ftw.load(fromByteOffset: 4, as: Int32.self)) }
  return 0
}

/// fts_read's entries under `root`, each as "<fts_info> <path>", with
/// whether each FTS_DP was its directory's FTS_D entry again and each
/// file's fts_statp a regular file's; with `skip`, FTS_SKIP on the root.
func ftsWalk(_ root: String, skip: Bool) -> (entries: [String], sameEntry: Bool, filesStated: Bool) {
  var entries: [String] = []
  var sameEntry = true, filesStated = true
  var path = Array(root.utf8CString)
  path.withUnsafeMutableBufferPointer { p in
    var paths: [UnsafeMutablePointer<CChar>?] = [p.baseAddress, nil]
    guard let fts = fts_open(&paths, 0, nil) else { return }
    var open: [UnsafeMutablePointer<FTSENT>] = []
    while let e = fts_read(fts) {
      entries.append("\(e.pointee.fts_info) \(String(cString: e.pointee.fts_path))")
      switch Int32(e.pointee.fts_info) {
      case FTS_D:
        open.append(e)
        if skip && e.pointee.fts_level == 0 { _ = fts_set(fts, e, FTS_SKIP) }
      case FTS_DP: sameEntry = sameEntry && open.popLast() == e
      case FTS_F: filesStated = filesStated && e.pointee.fts_statp != nil
        && (e.pointee.fts_statp.pointee.st_mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
      default: break
      }
    }
    if errno != 0 { entries.append("errno \(errno)") }
    _ = fts_close(fts)
  }
  return (entries, sameEntry, filesStated)
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
    // nftw: box, made and notes; directories before their contents, or
    // after them with FTW_DEPTH (8).
    check(nftw("/svc/t/box", walkVisit, 4, 1) == 0 && walkFiles == 1 && walkDirectories == 2 && walkPostorder == 0
      && walkDeepest == 1, "nftw walks the tree")
    walkFiles = 0
    walkDirectories = 0
    check(nftw("/svc/t/box", walkVisit, 4, 1 | 8) == 0 && walkFiles == 1 && walkDirectories == 0 && walkPostorder == 2,
          "nftw with FTW_DEPTH reports directories after their contents")
    // fts: a directory before and after its entries, as one entry (an
    // entry is freed at the next read, a directory after its FTS_DP).
    let walked = ftsWalk("/svc/t/box", skip: false)
    check(walked.entries.count == 5 && walked.entries.first == "1 /svc/t/box" && walked.entries.last == "6 /svc/t/box"
      && walked.entries.contains("8 /svc/t/box/notes") && walked.entries.contains("1 /svc/t/box/made")
      && walked.entries.contains("6 /svc/t/box/made") && walked.sameEntry && walked.filesStated,
          "fts walks the tree, a directory's FTS_DP its FTS_D entry")
    check(ftsWalk("/svc/t/box", skip: true).entries == ["1 /svc/t/box", "6 /svc/t/box"],
          "fts_set's FTS_SKIP leaves a directory's entries out")
    check(unlink("notes") == 0 && rmdir("made") == 0, "unlink and rmdir, relative")
    check(stat("notes", &st) == -1 && errno == ENOENT, "and they've gone")

    // pipe: bytes through one ring, more than it holds through a thread
    // (the writer sleeps until the reader makes room), then 0 once the
    // write end is closed; the numbers come back after.
    var ends: [Int32] = [0, 0]
    check(pipe(&ends) == 0 && ends[0] > 2 && ends[1] > 2 && ends[0] != ends[1], "pipe")
    check(writeBytes(ends[1], Array("ping".utf8)) == 4 && readBytes(ends[0], 16) == Array("ping".utf8),
          "a pipe's bytes come out its read end")
    let w = ends[1]
    let writer = try? Thread.spawn { _ = writeBytes(w, [UInt8](repeating: 0x5A, count: 20_000)); _ = close(w) }
    var total = 0, same = true
    while true {
      guard let got = readBytes(ends[0], 4096), !got.isEmpty else { break }
      total += got.count
      same = same && got.allSatisfy { $0 == 0x5A }
    }
    check(total == 20_000 && same, "20,000 bytes through the 8 KiB ring, then its end")
    _ = writer
    check(close(ends[0]) == 0, "the read end closed")
    var again: [Int32] = [0, 0]
    check(pipe(&again) == 0 && Set(again) == Set(ends), "the numbers are free again")
    _ = close(again[0])
    _ = close(again[1])

    print("fdio-test: \(checks - failures) of \(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
  }
}
