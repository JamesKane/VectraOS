// SPDX-License-Identifier: BSD-3-Clause

// rcport (D70): our rc (shell/rc/lib) on Linux, for `vx rc-oracle`, which
// runs each case of shell/rc/tests/oracle through it and through 9front's
// rc (tools/rc-oracle/9front) and compares them. Its RcSystem is Linux's:
// streams are file descriptors, pipes are OS pipes, programs are found on
// 9front's unix rcmain's path (. /bin /usr/bin /usr/local/bin) and started
// with posix_spawn, and an in-memory stream (a backquote's capture) is
// bridged to a child through a pipe and a pump thread. What it can't show
// is the device's own system layer (shell/rc/native): boot-launch checks
// that.
//
//   rcport FILE [ARG...] | rcport -c TEXT [ARG...]

import Foundation
import Glibc
import Rc
final class FdStream: RcStream {
  var fd: Int32
  let keep: Bool
  init(_ fd: Int32, keep: Bool = false) {
    self.fd = fd
    self.keep = keep
  }
  func write(_ bytes: [UInt8]) {
    guard fd >= 0 else { return }
    var at = 0
    while at < bytes.count {
      let n = bytes[at...].withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if errno == EINTR { continue }
        return
      }
      at += n
    }
  }
  func read() -> [UInt8]? {
    guard fd >= 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { return nil }
      return Array(buf[0..<n])
    }
  }
  func close() {
    if fd >= 0 && !keep { _ = Glibc.close(fd) }
    if !keep { fd = -1 }
  }
}

final class Job: RcJob {
  let pid: pid_t
  var pumps: [Thread] = []
  let done = DispatchSemaphore(value: 0)
  var pumpCount = 0
  var result: String?
  init(pid: pid_t) { self.pid = pid }
  func wait() -> String {
    if let result { return result }
    var st: Int32 = 0
    while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
    for _ in 0..<pumpCount { done.wait() }
    let exited = (st & 0x7f) == 0
    let code = exited ? (st >> 8) & 0xff : (st & 0x7f) + 1000
    result = code == 0 ? "" : String(code)
    return result!
  }
}

final class LinuxSystem: RcSystem {
  var processID: UInt64 { UInt64(getpid()) }

  let searchPath = [".", "/bin", "/usr/bin", "/usr/local/bin"]

  func resolve(_ name: String) -> String? {
    func ok(_ p: String) -> Bool {
      var s = stat()
      return access(p, X_OK) == 0 && stat(p, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG
    }
    if name.contains("/") { return ok(name) ? name : nil }
    for d in searchPath {
      let p = d + "/" + name
      if ok(p) { return p }
    }
    return nil
  }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? {
    let flags: Int32
    switch mode {
    case .read: flags = O_RDONLY
    case .write: flags = O_WRONLY | O_CREAT | O_TRUNC
    case .append: flags = O_WRONLY | O_CREAT | O_APPEND
    }
    let fd = Glibc.open(path, flags | O_CLOEXEC, 0o666)
    return fd < 0 ? nil : FdStream(fd)
  }

  func pipe() -> (RcStream, RcStream) {
    var p: [Int32] = [0, 0]
    cloexecPipe(&p)
    return (FdStream(p[0]), FdStream(p[1]))
  }

  func exists(_ name: String) -> Bool { resolve(name) != nil }

  func start(_ argv: [String], fds: [Int32: RcStream], environment: [(String, [String])]) -> RcJob? {
    guard let path = resolve(argv[0]) else { return nil }
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    var parentClose: [Int32] = []
    var pumpsToStart: [() -> Void] = []
    for (target, stream) in fds.sorted(by: { $0.key < $1.key }) {
      var src: Int32
      if let f = stream as? FdStream, f.fd >= 0 {
        src = fcntl(f.fd, F_DUPFD_CLOEXEC, 100)
      } else {
        var p: [Int32] = [0, 0]
        cloexecPipe(&p)
        if target == 0 {
          src = fcntl(p[0], F_DUPFD_CLOEXEC, 100)
          _ = Glibc.close(p[0])
          let w = p[1]
          pumpsToStart.append {
            while let b = stream.read() { FdStream(w).write(b) }
            _ = Glibc.close(w)
          }
        } else {
          src = fcntl(p[1], F_DUPFD_CLOEXEC, 100)
          _ = Glibc.close(p[1])
          let r = p[0]
          pumpsToStart.append {
            let rs = FdStream(r)
            while let b = rs.read() { stream.write(b) }
            rs.close()
          }
        }
      }
      parentClose.append(src)
      posix_spawn_file_actions_adddup2(&actions, src, target)
    }
    for t: Int32 in 0...2 where fds[t] == nil { posix_spawn_file_actions_addclose(&actions, t) }

    var attr = posix_spawnattr_t()
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var sigs = sigset_t()
    sigemptyset(&sigs)
    sigaddset(&sigs, SIGPIPE)
    posix_spawnattr_setsigdefault(&attr, &sigs)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))

    var env: [String: String] = ProcessInfo.processInfo.environment
    for (k, v) in environment where k != "*" { env[k] = v.joined(separator: "\u{1}") }
    let envStrings = env.map { $0.key + "=" + $0.value }
    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = envStrings.map { strdup($0) } + [nil]
    defer {
      cArgs.forEach { free($0) }
      cEnv.forEach { free($0) }
    }
    var pid: pid_t = 0
    let rcode = posix_spawn(&pid, path, &actions, &attr, cArgs, cEnv)
    for fd in parentClose { _ = Glibc.close(fd) }
    if rcode != 0 { return nil }
    let job = Job(pid: pid)
    for body in pumpsToStart {
      job.pumpCount += 1
      let t = Thread {
        body()
        job.done.signal()
      }
      t.start()
    }
    return job
  }

  func changeDirectory(_ path: String) -> Bool { chdir(path) == 0 }

  var directory: String {
    var buf = [CChar](repeating: 0, count: 4096)
    guard getcwd(&buf, buf.count) != nil else { return "/" }
    return String(cString: buf)
  }

  func list(_ directory: String) -> [String]? {
    guard let d = opendir(directory) else { return nil }
    defer { closedir(d) }
    var names: [String] = []
    while let e = readdir(d) {
      let name = withUnsafePointer(to: e.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
      }
      if name != "." && name != ".." { names.append(name) }
    }
    return names
  }
}

@main
struct Main {
  static func main() {
    signal(SIGPIPE, SIG_IGN)
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
      FileHandle.standardError.write("usage: rcport file | -c text [args]\n".data(using: .utf8)!)
      exit(2)
    }
    let text: String, name: String
    if args[0] == "-c" {
      name = "rc"
      text = args.count > 1 ? args[1] : ""
      args.removeFirst(min(2, args.count))
    } else {
      guard let d = FileManager.default.contents(atPath: args[0]) else {
        FileHandle.standardError.write("rcport: can't open \(args[0])\n".data(using: .utf8)!)
        exit(2)
      }
      text = String(decoding: d, as: UTF8.self)
      name = args[0]
      args.removeFirst()
    }
    let rc = Rc(system: LinuxSystem(), name: name, arguments: args)
    rc.run(text, fds: [0: FdStream(0, keep: true), 1: FdStream(1, keep: true), 2: FdStream(2, keep: true)])
    exit(rc.status.allSatisfy { $0 == "|" } ? 0 : 1)
  }
}

func cloexecPipe(_ p: inout [Int32]) {
  _ = p.withUnsafeMutableBufferPointer { Glibc.pipe($0.baseAddress!) }
  _ = fcntl(p[0], F_SETFD, FD_CLOEXEC)
  _ = fcntl(p[1], F_SETFD, FD_CLOEXEC)
}
