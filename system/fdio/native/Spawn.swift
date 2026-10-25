// SPDX-License-Identifier: BSD-3-Clause

// posix_spawn, posix_spawnp and waitpid (POSIX XSH, <spawn.h> and
// <sys/wait.h>): a program started as a process of its own, as D80 has
// it, over Process.start (no fork). The program is its file's memory in
// the namespace FDIO uses, as rc starts one (shell/rc's start); the child
// is given that namespace whole, so its /env (D81) and files are the
// caller's, and starts in a job of its own under the caller's. It is
// given no descriptors: its stdin is empty and its stdout and stderr go to
// the debuglog, as for any process given none (td_stdio.h). A child's pid
// is its process's koid, and its handle waits here until waitpid.

import Node
import Sys
import TDFloor
import TDNative
import VectraOSLibc

/// The children started and not yet waited for: pid, process handle.
nonisolated(unsafe) var children: [(pid: Int32, process: UInt32)] = []
let childrenLock = Lock()

/// argv's strings, up to its null.
func strings(_ list: UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
  guard let list = unsafe list else { return [] }
  var out: [String] = []
  var i = 0
  while let s = unsafe list[i] {
    out.append(unsafe String(cString: s))
    i += 1
  }
  return out
}

/// Starts the program at `path` with `args`: its pid, or the error.
func spawn(_ path: String, _ args: [String]) -> Result<Int32, Errno> {
  let resolved = FDIO.resolve(path.hasPrefix("/") ? path : FDIO.currentDirectory + "/" + path)
  guard case .success(let (ns, absolute)) = resolved else { return .failure(Errno.noEntry) }
  let memory: NodeIPC.Memory
  do throws(NamespaceError) {
    memory = try ns.memory(absolute, executable: true)
  } catch {
    return .failure(FDIO.missing(ns, absolute))
  }
  let name = String(absolute.split(separator: "/").last ?? Substring(absolute))
  var entry = ProgramEntry(image: memory.vmo.raw, offset: 0, length: Int(memory.size), name: name)
  entry.libraries = ns.libraries
  let startup = Startup(args: args.isEmpty ? [name] : args)
  // The caller's own job, left where it is: the child's goes under it.
  let job = td_startup_peek(HandleType.info(HandleType.jobDefault))
  guard job != 0 else { return .failure(Errno(1)) }  // EPERM: no job to start it in
  do throws(NamespaceError) { try startup.mount(ns) } catch { return .failure(Errno(12)) }
  let result = start(entry, startup, name, in: job)
  _ = consume memory  // the program's memory, kept until it is loaded
  return result
}

/// Starts `entry` given `startup` in a process under the job `raw` (the
/// caller's, borrowed): its pid, or the error.
func start(_ entry: ProgramEntry, _ startup: Startup, _ name: String, in raw: UInt32) -> Result<Int32, Errno> {
  let job = Handle(raw: raw)
  do throws(Status) {
    startup.add(try Sys.Job.create(parent: job), info: HandleType.info(HandleType.jobDefault))
    let process = try Process.create(job: job, name: name)
    _ = try Process.start(process, entry: entry, startup)
    let pid = Int32(truncatingIfNeeded: try process.info().koid)
    let handle = process.release()
    childrenLock.withLock { children.append((pid, handle)) }
    _ = job.release()
    return .success(pid)
  } catch {
    _ = job.release()
    return .failure(error == .noMemory ? Errno(12) : Errno(8))  // ENOMEM, or ENOEXEC: not a program it could start
  }
}

/// posix_spawn: the program at `path`, given `argv`; `envp` is the
/// environment the child would have, which is its /env, the caller's
/// (D81), so it isn't read. File actions and attributes aren't taken
/// (ENOSYS for any). The error, or 0 with the pid in `pid`.
@c(posix_spawn) public func fdioPosixSpawn(
  _ pid: UnsafeMutablePointer<Int32>?, _ path: UnsafePointer<CChar>?, _ actions: UnsafeRawPointer?,
  _ attributes: UnsafeRawPointer?, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
  _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  guard unsafe actions == nil, unsafe attributes == nil else { return 38 }  // ENOSYS
  guard let path = unsafe path else { return Errno.invalid.code }
  switch spawn(unsafe String(cString: path), unsafe strings(argv)) {
  case .success(let p):
    if let pid = unsafe pid { unsafe pid.pointee = p }
    return 0
  case .failure(let e): return e.code
  }
}

/// posix_spawnp: posix_spawn, a name without a slash looked for in /bin
/// (there is no PATH).
@c(posix_spawnp) public func fdioPosixSpawnp(
  _ pid: UnsafeMutablePointer<Int32>?, _ file: UnsafePointer<CChar>?, _ actions: UnsafeRawPointer?,
  _ attributes: UnsafeRawPointer?, _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
  _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  guard let file = unsafe file else { return Errno.invalid.code }
  let name = unsafe String(cString: file)
  let path = name.contains("/") ? name : "/bin/" + name
  return unsafe path.withCString { unsafe fdioPosixSpawn(pid, $0, actions, attributes, argv, envp) }
}

@c(posix_spawn_file_actions_init) public func fdioActionsInit(_ a: UnsafeMutableRawPointer?) -> Int32 { 0 }
@c(posix_spawn_file_actions_destroy) public func fdioActionsDestroy(_ a: UnsafeMutableRawPointer?) -> Int32 { 0 }
@c(posix_spawnattr_init) public func fdioAttrInit(_ a: UnsafeMutableRawPointer?) -> Int32 { 0 }
@c(posix_spawnattr_destroy) public func fdioAttrDestroy(_ a: UnsafeMutableRawPointer?) -> Int32 { 0 }

/// waitpid: waits for the child `pid` (or, for -1, the first one
/// started still waiting) to end, unless WNOHANG (1) and it hasn't (0);
/// its status as Linux encodes an exit, and the child is let go. ECHILD
/// for no such child.
@c(waitpid) public func fdioWaitpid(_ pid: Int32, _ status: UnsafeMutablePointer<Int32>?, _ options: Int32) -> Int32 {
  let child = childrenLock.withLock { children.first { pid == -1 || $0.pid == pid } }
  guard let child else {
    errno = 10  // ECHILD
    return -1
  }
  let deadline = options & 1 != 0 ? 0 : Int64.max
  var observed: UInt32 = 0
  let waited = unsafe td_wait_one(child.process, UInt32(CROI_SIGNAL_TASK_TERMINATED), deadline, &observed)
  if waited == Int32(CROI_ERR_TIMED_OUT) { return 0 }
  let process = Handle(raw: child.process)
  let code = (try? Process.info(process).returnCode) ?? 0
  childrenLock.withLock { children.removeAll { $0.pid == child.pid } }
  if let status = unsafe status { unsafe status.pointee = Int32(truncatingIfNeeded: code & 0xFF) << 8 }
  return child.pid
}
