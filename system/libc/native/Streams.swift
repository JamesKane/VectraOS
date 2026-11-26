// SPDX-License-Identifier: BSD-3-Clause

// File streams (C23 §7.23.5 to §7.23.9, POSIX's fdopen, fseeko and
// ftello): a FILE over a descriptor, fopen's or fdopen's, buffered. Its
// calls are the libc's open, read, write, lseek and close, which tier 1's
// fdio (system/fdio) gives; without it, fopen fails as open does. stdio.c
// keeps the three standard streams and sends a file stream here.
//
// A stream is fully buffered (16 KiB of malloc's) unless setvbuf says
// otherwise; line buffering writes at each newline; an unbuffered stream
// writes at once (and still reads ahead). Reading after writing, or
// writing after reading, needs no fflush or fseek between them (C requires
// one; here the switch flushes). ungetc gives back at least one byte at
// any time, and more while the bytes before it are still buffered. Open
// streams are written out by fflush(NULL) and at exit. A stream has no
// lock: two threads may not use one at once.

import TDStdioShim

public typealias File = UnsafeMutablePointer<td_file>

/// The stream's default buffer.
let streamBufferSize = 16384
// <stdio.h>'s buffering modes, and EOF.
let fullyBuffered: Int32 = 0, lineBuffered: Int32 = 1, unbuffered: Int32 = 2
let endOfFile: Int32 = -1

nonisolated(unsafe) var openStreams: File? = nil
nonisolated(unsafe) var flushesAtExit = false

/// The mode's open flags, and whether it reads, writes and appends; nil if
/// it isn't one of C's (r, w or a, then + b x e in any order).
func parseMode(_ mode: UnsafePointer<CChar>) -> (flags: Int32, read: Bool, write: Bool, append: Bool)? {
  let rdonly: Int32 = 0, wronly: Int32 = 1, rdwr: Int32 = 2
  let creat: Int32 = 0o100, excl: Int32 = 0o200, trunc: Int32 = 0o1000, appendFlag: Int32 = 0o2000
  let cloexec: Int32 = 0o2000000
  var flags: Int32
  var read = false, write = false, append = false
  switch unsafe mode[0] {
  case 0x72:  // r
    flags = rdonly
    read = true
  case 0x77:  // w
    flags = wronly | creat | trunc
    write = true
  case 0x61:  // a
    flags = wronly | creat | appendFlag
    write = true
    append = true
  default: return nil
  }
  var i = 1
  while unsafe mode[i] != 0 {
    switch unsafe mode[i] {
    case 0x2B:  // +
      flags = (flags & ~3) | rdwr
      read = true
      write = true
    case 0x62: break  // b: no difference
    case 0x78: flags |= excl  // x
    case 0x65: flags |= cloexec  // e
    default: return nil
    }
    i += 1
  }
  return (flags, read, write, append)
}

/// A new stream over `fd`, or nil (ENOMEM).
func makeStream(_ fd: Int32, _ read: Bool, _ write: Bool, _ append: Bool) -> File? {
  guard let raw = unsafe td_file_sys_alloc(MemoryLayout<td_file>.size) else {
    Errno.set(12)  // ENOMEM
    return nil
  }
  let f = unsafe raw.bindMemory(to: td_file.self, capacity: 1)
  unsafe f.initialize(to: td_file())
  unsafe f.pointee.fd = fd
  unsafe f.pointee.file = 1
  unsafe f.pointee.readable = read ? 1 : 0
  unsafe f.pointee.writable = write ? 1 : 0
  unsafe f.pointee.append = append ? 1 : 0
  unsafe f.pointee.buffering = fullyBuffered
  unsafe f.pointee.pushed = -1
  unsafe f.pointee.next = openStreams
  unsafe openStreams = f
  if !flushesAtExit {
    flushesAtExit = true
    _ = td_file_sys_atexit(flushAllStreams)
  }
  return unsafe f
}

@c(fopen) public func fileOpen(_ path: UnsafePointer<CChar>?, _ mode: UnsafePointer<CChar>?) -> File? {
  guard let path = unsafe path, let mode = unsafe mode, let m = unsafe parseMode(mode) else {
    Errno.set(Errno.invalid)
    return nil
  }
  let fd = unsafe td_file_sys_open(path, m.flags)
  guard fd >= 0 else { return nil }
  guard let f = unsafe makeStream(fd, m.read, m.write, m.append) else {
    _ = td_file_sys_close(fd)
    return nil
  }
  return unsafe f
}

@c(fdopen) public func fileDescriptorOpen(_ fd: Int32, _ mode: UnsafePointer<CChar>?) -> File? {
  guard fd >= 0 else {
    Errno.set(9)  // EBADF
    return nil
  }
  guard let mode = unsafe mode, let m = unsafe parseMode(mode) else {
    Errno.set(Errno.invalid)
    return nil
  }
  return unsafe makeStream(fd, m.read, m.write, m.append)
}

/// The stream's buffer, made on first use; false if there's no memory.
func ensureBuffer(_ f: File) -> Bool {
  if unsafe f.pointee.buffer != nil { return true }
  guard let p = unsafe td_file_sys_alloc(streamBufferSize) else {
    unsafe f.pointee.error = 1
    Errno.set(12)
    return false
  }
  unsafe f.pointee.buffer = p.assumingMemoryBound(to: UInt8.self)
  unsafe f.pointee.size = streamBufferSize
  unsafe f.pointee.own = 1
  return true
}

/// Writes all of `n` bytes; false (the stream's error set) if it couldn't.
func writeAll(_ f: File, _ p: UnsafeRawPointer, _ n: Int) -> Bool {
  var done = 0
  while done < n {
    let k = unsafe td_file_sys_write(f.pointee.fd, p + done, n - done)
    if k <= 0 {
      unsafe f.pointee.error = 1
      return false
    }
    done += k
  }
  return true
}

/// The bytes read ahead that the program hasn't taken: the buffer's, and
/// a pushed-back byte.
func unread(_ f: File) -> Int {
  unsafe Int(f.pointee.count - f.pointee.at) + (f.pointee.pushed >= 0 ? 1 : 0)
}

/// Writes what's pending, and gives back what was read ahead (the
/// descriptor's offset moved back to the stream's, where it can be).
func flushStream(_ f: File) -> Bool {
  if unsafe f.pointee.pending > 0 {
    let n = unsafe Int(f.pointee.pending)
    unsafe f.pointee.pending = 0
    guard unsafe writeAll(f, f.pointee.buffer, n) else { return false }
  }
  let back = unsafe unread(f)
  if back > 0 { _ = unsafe td_file_sys_seek(f.pointee.fd, Int64(-back), 1) }
  unsafe f.pointee.at = 0
  unsafe f.pointee.count = 0
  unsafe f.pointee.pushed = -1
  return true
}

@c public func td_file_flush(_ f: File) -> Int32 { unsafe flushStream(f) ? 0 : endOfFile }

/// Every open stream written out (fflush(NULL), and at exit).
@c public func td_file_flush_all() -> Int32 {
  var result: Int32 = 0
  var f = unsafe openStreams
  while let s = unsafe f {
    if unsafe !flushStream(s) { result = endOfFile }
    unsafe f = s.pointee.next
  }
  return result
}

@c public func flushAllStreams() { _ = td_file_flush_all() }

@c public func td_file_close(_ f: File) -> Int32 {
  let flushed = unsafe flushStream(f)
  let closed = unsafe td_file_sys_close(f.pointee.fd) == 0
  // Out of the list.
  if unsafe openStreams == f {
    unsafe openStreams = f.pointee.next
  } else {
    var p = unsafe openStreams
    while let s = unsafe p {
      if unsafe s.pointee.next == f {
        unsafe s.pointee.next = f.pointee.next
        break
      }
      unsafe p = s.pointee.next
    }
  }
  if unsafe f.pointee.own != 0 { unsafe td_file_sys_free(f.pointee.buffer) }
  unsafe td_file_sys_free(f)
  return flushed && closed ? 0 : endOfFile
}

/// Writes `n` bytes through the buffer: how many it took (all of them,
/// unless the descriptor failed).
@c public func td_file_write(_ f: File, _ p: UnsafeRawPointer, _ n: Int) -> Int {
  guard unsafe f.pointee.writable != 0 else {
    unsafe f.pointee.error = 1
    Errno.set(9)
    return 0
  }
  if unsafe f.pointee.count > 0 || f.pointee.pushed >= 0 { guard unsafe flushStream(f) else { return 0 } }
  guard unsafe ensureBuffer(f) else { return 0 }
  let size = unsafe Int(f.pointee.size)
  if unsafe f.pointee.buffering == unbuffered || n >= size {
    guard unsafe flushStream(f) else { return 0 }
    return unsafe writeAll(f, p, n) ? n : 0
  }
  var done = 0
  var newline = false
  while done < n {
    let pending = unsafe Int(f.pointee.pending)
    let k = min(n - done, size - pending)
    for j in 0..<k {
      let b = unsafe p.load(fromByteOffset: done + j, as: UInt8.self)
      unsafe f.pointee.buffer[pending + j] = b
      if b == 0x0A { newline = true }
    }
    unsafe f.pointee.pending += k
    done += k
    if unsafe Int(f.pointee.pending) == size { guard unsafe flushStream(f) else { return done - k } }
  }
  if unsafe newline && f.pointee.buffering == lineBuffered { guard unsafe flushStream(f) else { return 0 } }
  return n
}

/// Fills the empty buffer; false at the end or on an error (eof or error set).
func refill(_ f: File) -> Bool {
  guard unsafe ensureBuffer(f) else { return false }
  let k = unsafe td_file_sys_read(f.pointee.fd, f.pointee.buffer, f.pointee.size)
  if k <= 0 {
    if k == 0 { unsafe f.pointee.eof = 1 } else { unsafe f.pointee.error = 1 }
    return false
  }
  unsafe f.pointee.at = 0
  unsafe f.pointee.count = k
  return true
}

/// Readable, with nothing pending to write; false (EBADF) if it isn't readable.
func startReading(_ f: File) -> Bool {
  guard unsafe f.pointee.readable != 0 else {
    unsafe f.pointee.error = 1
    Errno.set(9)
    return false
  }
  if unsafe f.pointee.pending > 0 { return unsafe flushStream(f) }
  return true
}

/// Reads up to `n` bytes: how many it read.
@c public func td_file_read(_ f: File, _ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
  guard unsafe startReading(f) else { return 0 }
  var done = 0
  if n > 0, unsafe f.pointee.pushed >= 0 {
    unsafe p.storeBytes(of: UInt8(truncatingIfNeeded: f.pointee.pushed), as: UInt8.self)
    unsafe f.pointee.pushed = -1
    done = 1
  }
  while done < n {
    let have = unsafe Int(f.pointee.count - f.pointee.at)
    if have > 0 {
      let k = min(have, n - done)
      unsafe (p + done).copyMemory(from: f.pointee.buffer + Int(f.pointee.at), byteCount: k)
      unsafe f.pointee.at += k
      done += k
      continue
    }
    // Large reads go straight to the caller's memory.
    if n - done >= streamBufferSize {
      let k = unsafe td_file_sys_read(f.pointee.fd, p + done, n - done)
      if k <= 0 {
        if k == 0 { unsafe f.pointee.eof = 1 } else { unsafe f.pointee.error = 1 }
        break
      }
      done += k
      continue
    }
    if unsafe !refill(f) { break }
  }
  return done
}

@c public func td_file_getc(_ f: File) -> Int32 {
  guard unsafe startReading(f) else { return endOfFile }
  if unsafe f.pointee.pushed >= 0 {
    let c = unsafe f.pointee.pushed
    unsafe f.pointee.pushed = -1
    return c
  }
  if unsafe f.pointee.at == f.pointee.count, unsafe !refill(f) { return endOfFile }
  let c = unsafe f.pointee.buffer[Int(f.pointee.at)]
  unsafe f.pointee.at += 1
  return Int32(c)
}

@c public func td_file_ungetc(_ c: Int32, _ f: File) -> Int32 {
  guard c != endOfFile, unsafe startReading(f) else { return endOfFile }
  let b = UInt8(truncatingIfNeeded: c)
  if unsafe f.pointee.at > 0 {
    unsafe f.pointee.at -= 1
    unsafe f.pointee.buffer[Int(f.pointee.at)] = b
  } else if unsafe f.pointee.pushed < 0 {
    unsafe f.pointee.pushed = Int32(b)
  } else {
    return endOfFile
  }
  unsafe f.pointee.eof = 0
  return Int32(b)
}

@c(fseeko) public func fileSeek(_ f: File, _ offset: Int64, _ whence: Int32) -> Int32 {
  guard unsafe f.pointee.file != 0 else {
    Errno.set(29)  // ESPIPE: the standard streams don't seek
    return -1
  }
  var offset = offset
  if whence == 1 { offset -= Int64(unsafe unread(f)) }  // from the stream's position, not the descriptor's
  unsafe f.pointee.at = 0
  unsafe f.pointee.count = 0
  unsafe f.pointee.pushed = -1
  guard unsafe flushStream(f) else { return -1 }
  guard unsafe td_file_sys_seek(f.pointee.fd, offset, whence) >= 0 else { return -1 }
  unsafe f.pointee.eof = 0
  return 0
}

@c(fseek) public func fileSeekLong(_ f: File, _ offset: Int, _ whence: Int32) -> Int32 {
  unsafe fileSeek(f, Int64(offset), whence)
}

@c(ftello) public func fileTell(_ f: File) -> Int64 {
  guard unsafe f.pointee.file != 0 else {
    Errno.set(29)
    return -1
  }
  let at = unsafe td_file_sys_seek(f.pointee.fd, 0, 1)
  guard at >= 0 else { return -1 }
  return unsafe at - Int64(unread(f)) + Int64(f.pointee.pending)
}

@c(ftell) public func fileTellLong(_ f: File) -> Int { Int(unsafe fileTell(f)) }

@c(rewind) public func fileRewind(_ f: File) {
  _ = unsafe fileSeek(f, 0, 0)
  unsafe f.pointee.error = 0
}

/// setvbuf: the mode, and a buffer of the caller's (or the stream's own, of
/// `size` bytes if given). The standard streams accept it and keep theirs.
@c(setvbuf) public func fileSetBuffer(_ f: File, _ buffer: UnsafeMutablePointer<CChar>?, _ mode: Int32, _ size: Int)
  -> Int32
{
  guard mode == fullyBuffered || mode == lineBuffered || mode == unbuffered else {
    Errno.set(Errno.invalid)
    return -1
  }
  guard unsafe f.pointee.file != 0 else { return 0 }
  guard unsafe flushStream(f) else { return -1 }
  unsafe f.pointee.buffering = mode
  if let buffer = unsafe buffer, size > 0 {
    if unsafe f.pointee.own != 0 { unsafe td_file_sys_free(f.pointee.buffer) }
    unsafe f.pointee.buffer = UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self)
    unsafe f.pointee.size = size
    unsafe f.pointee.own = 0
  }
  return 0
}

@c(setbuf) public func fileSetBufferDefault(_ f: File, _ buffer: UnsafeMutablePointer<CChar>?) {
  _ = unsafe fileSetBuffer(f, buffer, buffer == nil ? unbuffered : fullyBuffered, buffer == nil ? 0 : 1024)
}

/// printf's sink for a file stream: gathered a little, then written.
@safe struct FileSink: FormatSink {
  let f: File
  var chunk = InlineArray<128, UInt8>(repeating: 0)
  var n = 0
  var failed = false
  mutating func put(_ byte: UInt8) {
    chunk[n] = byte
    n += 1
    if n == 128 { flush() }
  }
  mutating func flush() {
    guard n > 0 else { return }
    let k = n
    let written = withUnsafePointer(to: &chunk) { p in unsafe td_file_write(f, UnsafeRawPointer(p), k) }
    if written != k { failed = true }
    n = 0
  }
}

@c public func td_format_file(_ f: File, _ fmt: UnsafePointer<CChar>, _ ap: UnsafeMutableRawPointer) -> Int32 {
  guard unsafe f.pointee.writable != 0 else {
    unsafe f.pointee.error = 1
    Errno.set(9)
    return -1
  }
  var args = unsafe VaArguments(ap: ap)
  var sink = unsafe FileSink(f: f)
  let n = unsafe format(UnsafeRawPointer(fmt).assumingMemoryBound(to: UInt8.self), &args, &sink)
  sink.flush()
  return sink.failed ? -1 : Int32(truncatingIfNeeded: n)
}
