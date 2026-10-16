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
  var id: UInt64 { UInt64(pid) }
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

  /// This rc's directory: a fork of rc (where 9front forks; here a copy on
  /// a thread, or in rc) has its own, so paths are made absolute here and
  /// a program started there.
  var cwd: String

  init() {
    var buf = [CChar](repeating: 0, count: 4096)
    cwd = getcwd(&buf, buf.count) != nil ? String(cString: buf) : "/"
  }

  init(cwd: String) { self.cwd = cwd }

  func fork() -> RcSystem { LinuxSystem(cwd: cwd) }

  /// `path` against this directory.
  func absolute(_ path: String) -> String {
    path.hasPrefix("/") || path.isEmpty ? path : (cwd == "/" ? "/" : cwd + "/") + path
  }

  /// Signals as notes, by the names 9front's unix rc gives them (its
  /// Trapinit): each caught and counted, and taken between commands. Not
  /// SIGPIPE, which rcport ignores: its pump threads write to pipes.
  static let signalNames: [(Int32, String)] = [
    (SIGINT, "sigint"), (SIGTERM, "sigterm"), (SIGHUP, "sighup"), (SIGQUIT, "sigquit"),
    (SIGUSR1, "sigusr1"), (SIGUSR2, "sigusr2"), (SIGBUS, "sigbus"), (SIGWINCH, "sigwinch"),
  ]

  func catchSignals() {
    _ = caught  // made before a handler can use it
    for (n, _) in Self.signalNames { signal(n) { caught[Int($0)] &+= 1 } }
  }

  func takeNotes() -> [String] {
    var out: [String] = []
    for (n, name) in Self.signalNames {
      while caught[Int(n)] > 0 {
        caught[Int(n)] &-= 1
        out.append(name)
      }
    }
    return out
  }

  /// A thread, waited for by a semaphore, its status what it returned; its
  /// id ($apid) one above any Linux pid (pid_max is at most 2^22), as a
  /// fork's would be its own.
  final class ThreadJob: RcJob, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) static var last: UInt64 = 1 << 32
    let id: UInt64
    init() {
      ThreadJob.last += 1
      id = ThreadJob.last
    }
    var status = ""
    func wait() -> String {
      done.wait()
      done.signal()
      return status
    }
  }

  func spawn(_ body: @escaping @Sendable () -> String) -> RcJob? {
    let job = ThreadJob()
    Thread.detachNewThread {
      job.status = body()
      job.done.signal()
    }
    return job
  }

  /// 9front unix.c's Executable: a file it may run, not a directory.
  func executable(_ relative: String) -> Bool {
    let path = absolute(relative)
    var s = stat()
    return access(path, X_OK) == 0 && stat(path, &s) == 0 && (s.st_mode & S_IFMT) != S_IFDIR
  }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? {
    let flags: Int32
    switch mode {
    case .read: flags = O_RDONLY
    case .write: flags = O_WRONLY | O_CREAT | O_TRUNC
    case .readWrite: flags = O_RDWR  // 9front unix.c's Open: no create
    case .append: flags = O_WRONLY | O_CREAT | O_APPEND
    }
    let fd = Glibc.open(absolute(path), flags | O_CLOEXEC, 0o666)
    return fd < 0 ? nil : FdStream(fd)
  }

  /// A pipe's end as /dev/fd/N, N its own number (rc gives it to the
  /// command at that number).
  func descriptor(_ s: RcStream) -> (fd: Int32, path: String)? {
    guard let f = s as? FdStream, f.fd >= 0 else { return nil }
    return (f.fd, "/dev/fd/\(f.fd)")
  }

  func pipe() -> (RcStream, RcStream) {
    var p: [Int32] = [0, 0]
    cloexecPipe(&p)
    return (FdStream(p[0]), FdStream(p[1]))
  }

  func start(_ path: String, _ argv: [String], fds: [Int32: RcStream], environment: [String]) -> RcJob? {
    var actions = posix_spawn_file_actions_t()
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addchdir_np(&actions, cwd)
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

    // rc's, as 9front's mkenv makes it (rc took the process's at start).
    let envStrings = environment
    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = envStrings.map { strdup($0) } + [nil]
    defer {
      cArgs.forEach { free($0) }
      cEnv.forEach { free($0) }
    }
    var pid: pid_t = 0
    let rcode = posix_spawn(&pid, absolute(path), &actions, &attr, cArgs, cEnv)
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

  /// cd: this rc's directory, the path made real (as chdir and getcwd).
  func changeDirectory(_ path: String) -> Bool {
    var s = stat()
    guard stat(absolute(path), &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR, let real = realpath(absolute(path), nil) else {
      return false
    }
    defer { free(real) }
    cwd = String(cString: real)
    return true
  }

  var directory: String { cwd }

  func list(_ directory: String) -> [String]? {
    guard let d = opendir(absolute(directory)) else { return nil }
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
    guard let a = RcArguments(Array(CommandLine.arguments.dropFirst())) else {
      FileHandle.standardError.write((RcArguments.usage + "\n").data(using: .utf8)!)
      exit(1)
    }
    let system = LinuxSystem()
    signal(SIGPIPE, SIG_IGN)
    system.catchSignals()
    let rc = Rc(system: system, arguments: a.rest)
    rc.interactive = a.flags.contains("i")
    rc.take(a, name: CommandLine.arguments[0])
    var env: [String] = []
    var e = environ
    while let p = e.pointee {
      env.append(String(cString: p))
      e += 1
    }
    rc.variables["path"] = nil
    rc.take(environment: env)
    rc.functions["sigexit"] = nil  // rcmain's `fn sigexit`: not one inherited
    // rcmain.unix's, where the environment gave none.
    if (rc.variables["home"] ?? []).isEmpty { rc.variables["home"] = rc.variables["HOME"] }
    if (rc.variables["path"] ?? []).isEmpty || a.flags.contains("p") {
      rc.variables["path"] = a.flags.contains("p") ? ["/bin"] : [".", "/bin", "/usr/bin", "/usr/local/bin"]
    }
    let fds: [Int32: RcStream] = [0: FdStream(0, keep: true), 1: FdStream(1, keep: true), 2: FdStream(2, keep: true)]
    // As rcmain.unix: -c's command, else stdin if there's no file, else
    // `. $*` (no -i here: the oracle's stdin is empty).
    let ran: Bool
    if let c = a.command {
      ran = rc.run(c, fds: fds)
    } else if let file = a.rest.first {
      ran = rc.run(file: file, arguments: Array(a.rest.dropFirst()), fds: fds)
    } else {
      var text: [UInt8] = []
      while let b = fds[0]!.read() { text += b }
      ran = rc.run(String(decoding: text, as: UTF8.self), fds: fds)
    }
    // The end of rcmain: sigexit, unless rc exited already.
    if ran { rc.end() }
    exit(rc.status.allSatisfy { $0 == "|" } ? 0 : 1)
  }
}

func cloexecPipe(_ p: inout [Int32]) {
  _ = p.withUnsafeMutableBufferPointer { Glibc.pipe($0.baseAddress!) }
  _ = fcntl(p[0], F_SETFD, FD_CLOEXEC)
  _ = fcntl(p[1], F_SETFD, FD_CLOEXEC)
}

/// Signals caught, by number, not yet taken (a signal handler only adds).
nonisolated(unsafe) let caught: UnsafeMutablePointer<sig_atomic_t> = {
  let p = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 65)
  p.initialize(repeating: 0, count: 65)
  return p
}()
