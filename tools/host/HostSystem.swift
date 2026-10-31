// SPDX-License-Identifier: BSD-3-Clause

// The host's C library and Foundation, under one name for the host tools:
// Glibc and FoundationEssentials on Linux, Darwin and Foundation on the
// Mac. A call that must be qualified (a type's own `close` hides the C
// one) is written `HostSystem.close`.

#if canImport(Glibc)
@_exported import Glibc
#elseif canImport(Darwin)
@_exported import Darwin
#endif

#if canImport(FoundationEssentials)
@_exported import FoundationEssentials
#else
@_exported import Foundation
#endif

/// Starts `body` on a new thread and returns it, or nil if pthread_create
/// failed. Darwin's pthread_t is a pointer and its start routine's
/// argument isn't optional; glibc's is an integer, its argument optional.
public func startThread(_ body: @escaping @Sendable () -> Void) -> pthread_t? {
  final class Box {
    let body: @Sendable () -> Void
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
  }
  let box = Unmanaged.passRetained(Box(body)).toOpaque()
  #if canImport(Darwin)
  var thread: pthread_t?
  let r = pthread_create(&thread, nil, { p in
    Unmanaged<Box>.fromOpaque(p).takeRetainedValue().body()
    return nil
  }, box)
  #else
  var thread = pthread_t()
  let r = pthread_create(&thread, nil, { p in
    Unmanaged<Box>.fromOpaque(p!).takeRetainedValue().body()
    return nil
  }, box)
  #endif
  guard r == 0 else {
    Unmanaged<Box>.fromOpaque(box).release()
    return nil
  }
  return thread
}

#if canImport(Darwin)
/// glibc's names for stat's times, which Darwin calls `st_*timespec`.
extension stat {
  public var st_atim: timespec { st_atimespec }
  public var st_mtim: timespec { st_mtimespec }
  public var st_ctim: timespec { st_ctimespec }
}
#endif

#if canImport(Glibc)
/// SOCK_STREAM as the Int32 socket() takes (glibc imports it as an enum).
public let streamSocket = Int32(SOCK_STREAM.rawValue)
/// send()'s flag that makes a closed peer EPIPE, not SIGPIPE. Darwin has
/// none: openSocket sets it on the socket instead.
public let sendNoSignal = Int32(MSG_NOSIGNAL)
#else
public let streamSocket = SOCK_STREAM
public let sendNoSignal: Int32 = 0
#endif

/// A socket closed on exec, whose sends to a closed peer fail with EPIPE
/// rather than raising SIGPIPE.
public func openSocket(_ family: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
  #if canImport(Glibc)
  return socket(family, type | Int32(SOCK_CLOEXEC.rawValue), proto)
  #else
  let fd = socket(family, type, proto)
  guard fd >= 0 else { return fd }
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  var on: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  return fd
  #endif
}

/// Empty file actions for posix_spawn_file_actions_init: glibc's are a
/// struct, Darwin's a pointer the calls take as optional.
#if canImport(Darwin)
public func spawnFileActions() -> posix_spawn_file_actions_t? { nil }
#else
public func spawnFileActions() -> posix_spawn_file_actions_t { posix_spawn_file_actions_t() }
#endif
