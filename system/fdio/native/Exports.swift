// SPDX-License-Identifier: BSD-3-Clause

// fdio's calls under their C names (M6g), declared by our libc's
// <fcntl.h>, <unistd.h>, <sys/stat.h>, <dirent.h>, <stdio.h> and
// <stdlib.h>, for tier 1's programs: errno set as POSIX says. open is
// variadic, so C's (open.c) calls td_fdio_open. Descriptors 0 to 2 are the
// floor's: the rings the process was started with (D46), else an empty
// stdin and the debuglog (the floor's own write is weak and gives way to
// this one); so is any above 2 it was started with, a ring of its own,
// whose close writes its end.

import Node
import Sys
import TDFloor
import TDNative
import VectraOSLibc

/// A call's result as C returns it: the value, or -1 with errno set.
@inline(__always) func posix<T>(_ r: Result<T, Errno>, _ value: (T) -> Int) -> Int {
  switch r {
  case .success(let v): return value(v)
  case .failure(let e):
    errno = e.code
    return -1
  }
}

func path(_ p: UnsafePointer<CChar>?) -> String? {
  guard let p = unsafe p else {
    errno = Errno.invalid.code
    return nil
  }
  return unsafe String(cString: p)
}

/// Whether exit waits for the files' writes behind yet (FDIO.finishAll):
/// registered at the first open.
nonisolated(unsafe) var finishesAtExit = false

@c(td_fdio_open) public func fdioOpen(_ p: UnsafePointer<CChar>?, _ flags: Int32, _ mode: UInt32) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  if !finishesAtExit {
    finishesAtExit = true
    _ = atexit { FDIO.finishAll() }
  }
  return Int32(posix(FDIO.open(p, flags: flags, mode: mode)) { Int($0) })
}

/// pipe (POSIX XSH): the floor's (td_stdio_pipe), one ring read as
/// `fds[0]` and written as `fds[1]`, its numbers two FDIO isn't using,
/// below the floor's limit; EMFILE if there are none, ENFILE if it
/// couldn't be made.
@c(pipe) public func fdioPipe(_ fds: UnsafeMutablePointer<Int32>?) -> Int32 {
  guard let fds = unsafe fds else {
    errno = Errno.invalid.code
    return -1
  }
  return Int32(posix(FDIO.reserve(2, below: Int32(TD_STDIO_FD_LIMIT)) { numbers in
    unsafe td_stdio_pipe(numbers[0], numbers[1]) ? .success(numbers) : .failure(Errno(23))  // ENFILE
  }) { (numbers: [Int32]) -> Int in
    unsafe fds[0] = numbers[0]
    unsafe fds[1] = numbers[1]
    return 0
  })
}

@c(creat) public func fdioCreat(_ p: UnsafePointer<CChar>?, _ mode: UInt32) -> Int32 {
  unsafe fdioOpen(p, OpenFlags.writeOnly | OpenFlags.create | OpenFlags.truncate, mode)
}

@c(close) public func fdioClose(_ fd: Int32) -> Int32 {
  if fd >= 0 && fd <= 2 { return 0 }
  if inherited(fd) {
    td_stdio_close_fd(fd)
    return 0
  }
  return Int32(posix(FDIO.close(fd)) { 0 })
}

@c(read) public func fdioRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
  guard count > 0 else { return 0 }
  if fd == 0, let buffer = unsafe buffer { return unsafe td_stdin_read(buffer, count) }  // the floor's
  if fd > 2, inherited(fd), let buffer = unsafe buffer {
    let got = unsafe td_stdio_read_fd(fd, buffer, UInt64(count))
    if got < 0 { errno = Errno.badDescriptor.code }
    return Int(got)
  }
  guard let buffer = unsafe buffer else {
    errno = Errno.invalid.code
    return -1
  }
  return unsafe posix(FDIO.read(fd, into: UnsafeMutableRawBufferPointer(start: buffer, count: count))) { $0 }
}

@c(pread) public func fdioPread(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ offset: Int64) -> Int {
  guard count > 0 else { return 0 }
  guard let buffer = unsafe buffer else {
    errno = Errno.invalid.code
    return -1
  }
  return unsafe posix(FDIO.read(fd, into: UnsafeMutableRawBufferPointer(start: buffer, count: count), at: offset)) { $0 }
}

@c(write) public func fdioWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
  guard count > 0 else { return 0 }
  guard let buffer = unsafe buffer else {
    errno = Errno.invalid.code
    return -1
  }
  if fd == 1 {
    unsafe td_stdout_write(buffer, count)
    return count
  }
  if fd == 2 {
    unsafe td_stderr_write(buffer, count)
    return count
  }
  if fd > 2, inherited(fd) {
    guard unsafe td_stdio_write_fd(fd, buffer, UInt64(count)) else {
      errno = Errno.badDescriptor.code
      return -1
    }
    return count
  }
  return unsafe posix(FDIO.write(fd, UnsafeRawBufferPointer(start: buffer, count: count))) { $0 }
}

@c(pwrite) public func fdioPwrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ offset: Int64) -> Int {
  guard count > 0 else { return 0 }
  guard let buffer = unsafe buffer else {
    errno = Errno.invalid.code
    return -1
  }
  return unsafe posix(FDIO.write(fd, UnsafeRawBufferPointer(start: buffer, count: count), at: offset)) { $0 }
}

@c(lseek) public func fdioLseek(_ fd: Int32, _ offset: Int64, _ whence: Int32) -> Int64 {
  Int64(posix(FDIO.seek(fd, offset, whence: whence)) { Int($0) })
}

@c(fsync) public func fdioFsync(_ fd: Int32) -> Int32 { Int32(posix(FDIO.sync(fd)) { 0 }) }

@c(ftruncate) public func fdioFtruncate(_ fd: Int32, _ size: Int64) -> Int32 {
  Int32(posix(FDIO.truncate(fd, to: size)) { 0 })
}

/// struct stat from what a node says: no permissions or owners (a file
/// 0644, a directory 0755), one time for all three.
func fill(_ st: UnsafeMutablePointer<stat>, _ s: FileStatus) {
  var out = stat()
  out.st_ino = s.id
  out.st_nlink = s.isDirectory ? 2 : 1
  out.st_mode = s.isDirectory ? UInt32(S_IFDIR) | 0o755 : UInt32(S_IFREG) | 0o644
  out.st_size = Int64(s.size)
  out.st_blksize = 4096
  out.st_blocks = Int64((s.size + 511) / 512)
  let time = timespec(tv_sec: s.modified / 1_000_000_000, tv_nsec: Int(s.modified % 1_000_000_000))
  out.st_atim = time
  out.st_mtim = time
  out.st_ctim = time
  unsafe st.pointee = out
}

@c(stat) public func fdioStat(_ p: UnsafePointer<CChar>?, _ st: UnsafeMutablePointer<stat>?) -> Int32 {
  guard let p = unsafe path(p), let st = unsafe st else { return -1 }
  return Int32(posix(FDIO.status(p)) { s in unsafe fill(st, s); return 0 })
}

@c(lstat) public func fdioLstat(_ p: UnsafePointer<CChar>?, _ st: UnsafeMutablePointer<stat>?) -> Int32 {
  unsafe fdioStat(p, st)
}

@c(fstat) public func fdioFstat(_ fd: Int32, _ st: UnsafeMutablePointer<stat>?) -> Int32 {
  guard let st = unsafe st else {
    errno = Errno.invalid.code
    return -1
  }
  if fd >= 0 && fd <= 2 {
    unsafe fill(st, FileStatus(isDirectory: false, size: 0, modified: 0, id: 0))
    return 0
  }
  return Int32(posix(FDIO.status(fd)) { s in unsafe fill(st, s); return 0 })
}

@c(mkdir) public func fdioMkdir(_ p: UnsafePointer<CChar>?, _ mode: UInt32) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  return Int32(posix(FDIO.makeDirectory(p)) { 0 })
}

@c(unlink) public func fdioUnlink(_ p: UnsafePointer<CChar>?) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  return Int32(posix(FDIO.unlink(p)) { 0 })
}

@c(rmdir) public func fdioRmdir(_ p: UnsafePointer<CChar>?) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  return Int32(posix(FDIO.removeDirectory(p)) { 0 })
}

/// remove (C23 §7.23.4.1): a file, or an empty directory.
@c(remove) public func fdioRemove(_ p: UnsafePointer<CChar>?) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  if case .success(let s) = FDIO.status(p), s.isDirectory { return Int32(posix(FDIO.removeDirectory(p)) { 0 }) }
  return Int32(posix(FDIO.unlink(p)) { 0 })
}

@c(rename) public func fdioRename(_ from: UnsafePointer<CChar>?, _ to: UnsafePointer<CChar>?) -> Int32 {
  guard let from = unsafe path(from), let to = unsafe path(to) else { return -1 }
  return Int32(posix(FDIO.rename(from, to: to)) { 0 })
}

@c(access) public func fdioAccess(_ p: UnsafePointer<CChar>?, _ mode: Int32) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  guard mode & ~7 == 0 else {
    errno = Errno.invalid.code
    return -1
  }
  return Int32(posix(FDIO.access(p)) { 0 })
}

/// chmod: no permissions are kept, so it succeeds on what's there.
@c(chmod) public func fdioChmod(_ p: UnsafePointer<CChar>?, _ mode: UInt32) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  return Int32(posix(FDIO.access(p)) { 0 })
}

@c(fchmod) public func fdioFchmod(_ fd: Int32, _ mode: UInt32) -> Int32 {
  if fd >= 0 && fd <= 2 { return 0 }
  return Int32(posix(FDIO.status(fd)) { _ in 0 })
}

/// The template's trailing XXXXXX replaced by letters and digits from
/// croi's CPRNG until the name isn't there; EINVAL without six X's.
func fillTemplate(_ t: UnsafeMutablePointer<CChar>) -> Bool {
  let n = unsafe strlen(t)
  guard n >= 6 else { return false }
  for i in (n - 6)..<n where unsafe t[i] != 0x58 { return false }  // 'X'
  let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
  var random = [UInt8](repeating: 0, count: 6)
  _ = random.withUnsafeMutableBytes { unsafe getentropy($0.baseAddress, 6) }
  for i in 0..<6 { unsafe t[n - 6 + i] = CChar(bitPattern: alphabet[Int(random[i]) % alphabet.count]) }
  return true
}

@c(mktemp) public func fdioMktemp(_ t: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
  guard let t = unsafe t else {
    errno = Errno.invalid.code
    return nil
  }
  for _ in 0..<100 {
    guard unsafe fillTemplate(t) else {
      errno = Errno.invalid.code
      unsafe t[0] = 0
      return unsafe t
    }
    if case .failure(Errno.noEntry) = FDIO.status(unsafe String(cString: t)) { return unsafe t }
    let n = unsafe strlen(t)
    for i in (n - 6)..<n { unsafe t[i] = 0x58 }
  }
  errno = Errno.exists.code
  unsafe t[0] = 0
  return unsafe t
}

/// mkstemp: mktemp's name, created and opened read-write (O_EXCL).
@c(mkstemp) public func fdioMkstemp(_ t: UnsafeMutablePointer<CChar>?) -> Int32 {
  guard let t = unsafe t else {
    errno = Errno.invalid.code
    return -1
  }
  for _ in 0..<100 {
    guard unsafe fillTemplate(t) else {
      errno = Errno.invalid.code
      return -1
    }
    switch FDIO.open(unsafe String(cString: t), flags: OpenFlags.readWrite | OpenFlags.create | OpenFlags.exclusive) {
    case .success(let fd): return fd
    case .failure(Errno.exists):
      let n = unsafe strlen(t)
      for i in (n - 6)..<n { unsafe t[i] = 0x58 }
    case .failure(let e):
      errno = e.code
      return -1
    }
  }
  errno = Errno.exists.code
  return -1
}

/// readlink: there are no symbolic links, so what's there isn't one
/// (EINVAL), and what isn't, ENOENT.
@c(readlink) public func fdioReadlink(_ p: UnsafePointer<CChar>?, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int {
  guard let p = unsafe path(p) else { return -1 }
  return posix(FDIO.access(p).flatMap { _ in Result<Void, Errno>.failure(Errno.invalid) }) { 0 }
}

/// symlink and link: the fs service has neither (EPERM, as Linux says of
/// a file system without them).
@c(symlink) public func fdioSymlink(_ target: UnsafePointer<CChar>?, _ p: UnsafePointer<CChar>?) -> Int32 {
  errno = Errno.notPermitted.code
  return -1
}

@c(link) public func fdioLink(_ from: UnsafePointer<CChar>?, _ to: UnsafePointer<CChar>?) -> Int32 {
  errno = Errno.notPermitted.code
  return -1
}

@c(chdir) public func fdioChdir(_ p: UnsafePointer<CChar>?) -> Int32 {
  guard let p = unsafe path(p) else { return -1 }
  return Int32(posix(FDIO.changeDirectory(p)) { 0 })
}

/// A path into `buffer` (`size` bytes), or a new one on the heap if
/// `buffer` is null; ERANGE if it doesn't fit.
func give(_ s: String, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> UnsafeMutablePointer<CChar>? {
  let bytes = Array(s.utf8)
  let out: UnsafeMutablePointer<CChar>
  if let buffer = unsafe buffer {
    guard size > bytes.count else {
      errno = 34  // ERANGE
      return nil
    }
    unsafe out = buffer
  } else {
    unsafe out = malloc(bytes.count + 1)!.assumingMemoryBound(to: CChar.self)
  }
  for (i, b) in bytes.enumerated() { unsafe out[i] = CChar(bitPattern: b) }
  unsafe out[bytes.count] = 0
  return unsafe out
}

@c(getcwd) public func fdioGetcwd(_ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> UnsafeMutablePointer<CChar>? {
  if unsafe buffer != nil && size == 0 {
    errno = Errno.invalid.code
    return nil
  }
  return unsafe give(FDIO.currentDirectory, buffer, buffer == nil ? 0 : size)
}

/// realpath: `resolved` holds PATH_MAX (4096) bytes, or is null.
@c(realpath) public func fdioRealpath(_ p: UnsafePointer<CChar>?, _ resolved: UnsafeMutablePointer<CChar>?)
  -> UnsafeMutablePointer<CChar>?
{
  guard let p = unsafe path(p) else { return nil }
  switch FDIO.realPath(p) {
  case .success(let r): return unsafe give(r, resolved, 4096)
  case .failure(let e):
    errno = e.code
    return nil
  }
}

/// A DIR: the stream and the dirent readdir hands out, valid until the
/// next readdir or closedir on it.
final class OpenDirectory {
  let stream: DirectoryStream
  let entry = UnsafeMutablePointer<dirent>.allocate(capacity: 1)
  init(_ stream: DirectoryStream) { self.stream = stream }
  deinit { unsafe entry.deallocate() }
}

@c(opendir) public func fdioOpendir(_ p: UnsafePointer<CChar>?) -> OpaquePointer? {
  guard let p = unsafe path(p) else { return nil }
  switch FDIO.openDirectory(p) {
  case .success(let s): return OpaquePointer(Unmanaged.passRetained(OpenDirectory(s)).toOpaque())
  case .failure(let e):
    errno = e.code
    return nil
  }
}

@c(readdir) public func fdioReaddir(_ dir: OpaquePointer?) -> UnsafeMutablePointer<dirent>? {
  guard let dir else {
    errno = Errno.badDescriptor.code
    return nil
  }
  let d = unsafe Unmanaged<OpenDirectory>.fromOpaque(UnsafeRawPointer(dir)).takeUnretainedValue()
  guard let e = d.stream.read() else { return nil }  // the end: errno unchanged
  var out = dirent()
  out.d_ino = e.id
  out.d_off = Int64(d.stream.next)
  out.d_reclen = UInt16(MemoryLayout<dirent>.size)
  out.d_type = UInt8(e.isDirectory ? DT_DIR : DT_REG)
  unsafe withUnsafeMutableBytes(of: &out.d_name) { name in
    let bytes = Array(e.name.utf8.prefix(255))
    for (i, b) in bytes.enumerated() { unsafe name[i] = b }
    unsafe name[bytes.count] = 0
  }
  unsafe d.entry.initialize(to: out)
  return unsafe d.entry
}

@c(rewinddir) public func fdioRewinddir(_ dir: OpaquePointer?) {
  guard let dir else { return }
  unsafe Unmanaged<OpenDirectory>.fromOpaque(UnsafeRawPointer(dir)).takeUnretainedValue().stream.rewind()
}

@c(closedir) public func fdioClosedir(_ dir: OpaquePointer?) -> Int32 {
  guard let dir else {
    errno = Errno.badDescriptor.code
    return -1
  }
  unsafe Unmanaged<OpenDirectory>.fromOpaque(UnsafeRawPointer(dir)).release()
  return 0
}


/// getenv (C23 §7.24.4.6, open.c's) from the process's /env (D81), as
/// Plan 9's getenv(2) reads it: a list's elements joined by blanks. Read on each
/// call; the string stays the caller's until the next getenv of `name`.
@c(td_fdio_getenv) public func fdioGetenv(_ name: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
  guard let name = unsafe name, let value = FDIO.namespace?.getenv(unsafe String(cString: name)) else { return nil }
  let bytes = Array(value.utf8)
  let copy = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
  for (i, b) in bytes.enumerated() { unsafe copy[i] = CChar(bitPattern: b) }
  unsafe copy[bytes.count] = 0
  let key = unsafe String(cString: name)
  let old = Environment.lock.withLock { () -> UnsafeMutablePointer<CChar>? in
    let i = unsafe Environment.given.firstIndex { $0.name.utf8.elementsEqual(key.utf8) }
    let old = unsafe i.map { unsafe Environment.given.remove(at: $0).value }
    unsafe Environment.given.append((key, copy))
    return unsafe old
  }
  unsafe old?.deallocate()
  return unsafe copy
}

/// What getenv gave, each name's last.
enum Environment {
  static let lock = Lock()
  nonisolated(unsafe) static var given: [(name: String, value: UnsafeMutablePointer<CChar>)] = []
}
