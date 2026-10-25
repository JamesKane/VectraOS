// SPDX-License-Identifier: BSD-3-Clause

// bin/crash-test (crash-test(8)): Taisce on a real disk through power
// cuts. `run` writes files f0, f1, ... into /data/crash-test, each
// CrashPlan's bytes for its number in 32 KiB writes, commits a group after
// every eight (the directory's sync) and says `crash-test: durable <n>`
// once it returns; someone cuts the power. After the next boot, with
// fs(4) mounting with --check, `verify` reads every file back and judges
// them (CrashPlan.judge): the whole ones must run unbroken from f0, at
// least as far as the last `durable` said, and none may hold wrong bytes.

import Fs
import IPC
import Node
import Sys

let directory = "/data/crash-test"

/// File n as found: its bytes read back and compared.
func found(_ ns: Namespace, _ n: Int) -> CrashPlan.Found? {
  guard var f = try? ns.open("\(directory)/f\(n)") else { return nil }
  let size = CrashPlan.size(n)
  var at = 0
  while at < size + 1 {
    guard let part = try? f.read(offset: UInt64(at), max: 32768) else { return .wrong }
    if part.isEmpty { break }
    guard at + part.count <= size, part == CrashPlan.bytes(n, offset: at, count: part.count) else { return .wrong }
    at += part.count
  }
  return at == 0 ? .empty : at == size ? .whole : .partial
}

/// Every file from f0 until 32 numbers in a row are missing.
func verify(_ ns: Namespace) -> CrashPlan.Verdict {
  var all: [CrashPlan.Found] = []
  var missing = 0, n = 0
  while missing < 32 {
    if let f = found(ns, n) {
      // A missing number below one found is a file lost: wrong.
      for _ in 0..<missing { all.append(.wrong) }
      missing = 0
      all.append(f)
    } else {
      missing += 1
    }
    n += 1
  }
  return CrashPlan.judge(all)
}

/// The last run's files and directory removed.
func clear(_ ns: Namespace) {
  var missing = 0, n = 0
  while missing < 32 {
    if var f = try? ns.open("\(directory)/f\(n)") {
      _ = try? f.remove()
      missing = 0
    } else {
      missing += 1
    }
    n += 1
  }
  if var d = try? ns.open(directory) { _ = try? d.remove() }
}

func run(_ ns: Namespace, files: Int) {
  clear(ns)
  guard (try? ns.create(directory, kind: .directory)) != nil, let channel = try? ns.connect(directory) else {
    Process.fail("can't make \(directory)")
  }
  var dir = FsIPC.DirectoryClient(channel: channel)
  guard (try? dir.sync()) != nil else { Process.fail("the first sync failed") }
  print("crash-test: durable 0")
  for n in 0..<files {
    guard var f = try? ns.create("\(directory)/f\(n)", kind: .file) else { Process.fail("can't make f\(n)") }
    let bytes = CrashPlan.bytes(n, count: CrashPlan.size(n))
    var at = 0
    while at < bytes.count {
      let piece = Array(bytes[at..<min(at + 32768, bytes.count)])
      guard (try? f.write(offset: UInt64(at), piece)) == UInt32(piece.count) else { Process.fail("f\(n)'s write fell short") }
      at += piece.count
    }
    if (n + 1) % CrashPlan.perGroup == 0 {
      guard (try? dir.sync()) != nil else { Process.fail("the sync after f\(n) failed") }
      print("crash-test: durable \(n + 1)")
    }
  }
  print("crash-test: done, \(files) files")
}

@main struct CrashTest {
  static func main() {
    let start = Startup.current
    let args = Array(start.args.dropFirst())
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    if args.count == 1, NodeIPC.same(args[0], "verify") {
      let v = verify(ns)
      print("crash-test: verify: \(v.text)")
      Process.exit(code: v.passed ? 0 : 1)
    }
    if args.count >= 1, args.count <= 2, NodeIPC.same(args[0], "run") {
      run(ns, files: args.count == 2 ? Int(args[1]) ?? 2000 : 2000)
      Process.exit(code: 0)
    }
    Process.fail("usage: crash-test verify | crash-test run [FILES]")
  }
}
