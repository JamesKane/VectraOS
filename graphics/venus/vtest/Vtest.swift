// SPDX-License-Identifier: BSD-3-Clause

// The Venus client driver's transport on the host (M5e): virglrenderer's
// vtest server (`virgl_test_server --venus`) over its Unix socket, as
// docs/research/venus-protocol.md Part A describes it. The socket is
// $VTEST_SOCKET_NAME, else /tmp/.virgl_test. Every request is whole under
// one mutex; a SYNC_WAIT polls its eventfd after letting go of it. Any
// failure is the end of the connection (the server disconnects on errors).

import Glibc
import TDVtest
import VenusDriver

public final class VtestTransport: VenusTransport {
  let fd: Int32
  public private(set) var capset: [UInt8] = []
  public private(set) var version: UInt32 = 0
  public private(set) var timelines: UInt32 = 0
  var io = pthread_mutex_t()
  var state = pthread_mutex_t()
  var broken = false

  /// Request ids (§1.4).
  enum Request: UInt32 {
    case resourceUnref = 3, createRenderer = 8, protocolVersion = 11, getParam = 15, getCapset = 16, contextInit = 17,
      resourceCreateBlob = 18, syncCreate = 19, syncUnref = 20, syncRead = 21, syncWrite = 22, syncWait = 23,
      submitCmd2 = 24
  }

  /// Connects, negotiates and makes a Venus context (§15, steps 1-7).
  public init(socket path: String? = nil, name: String = "todhchai") throws(VenusLost) {
    pthread_mutex_init(&io, nil)
    pthread_mutex_init(&state, nil)
    let path = path ?? (getenv("VTEST_SOCKET_NAME").map { String(cString: $0) }) ?? "/tmp/.virgl_test"
    fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
    guard fd >= 0 else { throw VenusLost() }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw VenusLost() }
    withUnsafeMutableBytes(of: &address.sun_path) { b in
      for (i, c) in bytes.enumerated() { b[i] = c }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
      close(fd)
      throw VenusLost()
    }
    // CREATE_RENDERER: the length in bytes, the name with its NUL.
    let nameBytes = Array(name.utf8) + [0]
    try write(header(UInt32(nameBytes.count), .createRenderer) + nameBytes)
    try request(.protocolVersion, [4])
    version = try reply(.protocolVersion)[0]
    guard version >= 3 else { throw VenusLost() }
    try request(.getParam, [1])  // MAX_TIMELINE_COUNT
    let timelineParam = try reply(.getParam)
    timelines = timelineParam[0] == 1 ? timelineParam[1] : 0
    guard timelines > 0 else { throw VenusLost() }
    try request(.getCapset, [4, 0])  // Venus, version 0
    let set = try reply(.getCapset)
    guard set.first == 1 else { throw VenusLost() }
    capset = set.dropFirst().flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * $0)) } }
    try request(.contextInit, [4])
  }

  deinit {
    close(fd)
    pthread_mutex_destroy(&io)
    pthread_mutex_destroy(&state)
  }

  public func lock() { pthread_mutex_lock(&state) }
  public func unlock() { pthread_mutex_unlock(&state) }

  // MARK: The socket

  func header(_ length: UInt32, _ id: Request) -> [UInt8] { words([length, id.rawValue]) }

  func words(_ w: [UInt32]) -> [UInt8] { w.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } } }

  func write(_ bytes: [UInt8]) throws(VenusLost) {
    var sent = 0
    while sent < bytes.count {
      let n = bytes.withUnsafeBytes { b in send(fd, b.baseAddress! + sent, b.count - sent, Int32(MSG_NOSIGNAL)) }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else {
        broken = true
        throw VenusLost()
      }
      sent += n
    }
  }

  func read(_ count: Int) throws(VenusLost) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
      let n = out.withUnsafeMutableBytes { b in recv(fd, b.baseAddress! + got, count - got, 0) }
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else {
        broken = true
        throw VenusLost()
      }
      got += n
    }
    return out
  }

  func request(_ id: Request, _ body: [UInt32]) throws(VenusLost) {
    guard !broken else { throw VenusLost() }
    try write(header(UInt32(body.count), id) + words(body))
  }

  /// A reply's dwords, after checking its header names `id`.
  func reply(_ id: Request) throws(VenusLost) -> [UInt32] {
    let h = try read(8)
    let length = Int(UInt32(h[0]) | UInt32(h[1]) << 8 | UInt32(h[2]) << 16 | UInt32(h[3]) << 24)
    guard h[4] == UInt8(id.rawValue), length < 1 << 20 else {
      broken = true
      throw VenusLost()
    }
    let body = try read(length * 4)
    return (0..<length).map { i in
      UInt32(body[4 * i]) | UInt32(body[4 * i + 1]) << 8 | UInt32(body[4 * i + 2]) << 16 | UInt32(body[4 * i + 3]) << 24
    }
  }

  /// The fd that follows a reply (§1.3).
  func receiveFD() throws(VenusLost) -> Int32 {
    let received = td_vtest_receive_fd(fd)
    guard received >= 0 else {
      broken = true
      throw VenusLost()
    }
    return received
  }

  func withIO<R>(_ body: () throws(VenusLost) -> R) throws(VenusLost) -> R {
    pthread_mutex_lock(&io)
    defer { pthread_mutex_unlock(&io) }
    return try body()
  }

  // MARK: VenusTransport

  func blob(type: UInt32, flags: UInt32, size: Int, id: UInt64) throws(VenusLost) -> (UInt32, Int32) {
    try withIO { () throws(VenusLost) -> (UInt32, Int32) in
      try request(.resourceCreateBlob, [type, flags, UInt32(truncatingIfNeeded: size), UInt32(truncatingIfNeeded: size >> 32),
                                        UInt32(truncatingIfNeeded: id), UInt32(truncatingIfNeeded: id >> 32)])
      let r = try reply(.resourceCreateBlob)
      return (r[0], try receiveFD())
    }
  }

  func map(_ fd: Int32, _ size: Int) throws(VenusLost) -> UnsafeMutableRawPointer {
    let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    close(fd)
    guard let p, p != MAP_FAILED else { throw VenusLost() }
    return p
  }

  public func createSharedMemory(size: Int) throws(VenusLost) -> (resource: UInt32, address: UnsafeMutableRawPointer) {
    let (resource, fd) = try blob(type: 2, flags: VenusBlob.mappable, size: size, id: 0)  // HOST3D, blob id 0
    return (resource, try map(fd, size))
  }

  public func createBlob(id: UInt64, size: Int, flags: UInt32) throws(VenusLost)
    -> (resource: UInt32, address: UnsafeMutableRawPointer?)
  {
    let (resource, fd) = try blob(type: 2, flags: flags, size: size, id: id)
    guard flags & VenusBlob.mappable != 0 else {
      close(fd)
      return (resource, nil)
    }
    return (resource, try map(fd, size))
  }

  public func release(resource: UInt32, address: UnsafeMutableRawPointer?, size: Int) {
    if let address { munmap(address, size) }
    _ = try? withIO { () throws(VenusLost) in try request(.resourceUnref, [resource]) }
  }

  public func createSync(_ initial: UInt64) throws(VenusLost) -> UInt32 {
    try withIO { () throws(VenusLost) -> UInt32 in
      try request(.syncCreate, [UInt32(truncatingIfNeeded: initial), UInt32(truncatingIfNeeded: initial >> 32)])
      return try reply(.syncCreate)[0]
    }
  }

  public func destroySync(_ id: UInt32) {
    _ = try? withIO { () throws(VenusLost) in try request(.syncUnref, [id]) }
  }

  public func readSync(_ id: UInt32) throws(VenusLost) -> UInt64 {
    try withIO { () throws(VenusLost) -> UInt64 in
      try request(.syncRead, [id])
      let r = try reply(.syncRead)
      return UInt64(r[0]) | UInt64(r[1]) << 32
    }
  }

  public func writeSync(_ id: UInt32, _ value: UInt64) throws(VenusLost) {
    try withIO { () throws(VenusLost) in
      try request(.syncWrite, [id, UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }
  }

  /// SUBMIT_CMD2 with one batch (§1.5): its descriptor, the stream, then
  /// the sync list; RING_IDX always, so the syncs mean the work has run.
  public func submit(_ stream: [UInt8], timeline: UInt32, syncs: [(id: UInt32, value: UInt64)]) throws(VenusLost) {
    precondition(stream.count % 4 == 0)
    let streamWords = UInt32(stream.count / 4)
    var body: [UInt32] = [1, 1, 9, streamWords, 9 + streamWords, UInt32(syncs.count), timeline, 0, 0]
    var tail: [UInt32] = []
    for s in syncs { tail += [s.id, UInt32(truncatingIfNeeded: s.value), UInt32(truncatingIfNeeded: s.value >> 32)] }
    body[0] = 1
    try withIO { () throws(VenusLost) in
      guard !broken else { throw VenusLost() }
      try write(header(UInt32(body.count) + streamWords + UInt32(tail.count), .submitCmd2) + words(body) + stream + words(tail))
    }
  }

  public func exportVMO(resource: UInt32) -> UInt32? { nil }
  public var canExportVMOs: Bool { false }

  public func pause(nanoseconds: UInt64) {
    var t = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
    nanosleep(&t, nil)
  }

  /// SYNC_WAIT, then its eventfd polled outside the mutex.
  public func wait(_ syncs: [(id: UInt32, value: UInt64)], any: Bool, timeoutNanoseconds: UInt64) throws(VenusLost) -> Bool {
    let ms = timeoutNanoseconds == .max ? UInt32.max : UInt32(min(timeoutNanoseconds / 1_000_000, UInt64(UInt32.max - 1)))
    let event = try withIO { () throws(VenusLost) -> Int32 in
      var body: [UInt32] = [any ? 1 : 0, ms]
      for s in syncs { body += [s.id, UInt32(truncatingIfNeeded: s.value), UInt32(truncatingIfNeeded: s.value >> 32)] }
      try request(.syncWait, body)
      _ = try reply(.syncWait)
      return try receiveFD()
    }
    defer { close(event) }
    var p = pollfd(fd: event, events: Int16(POLLIN), revents: 0)
    while true {
      let r = poll(&p, 1, ms == .max ? -1 : Int32(min(ms, UInt32(Int32.max))))
      if r < 0 && errno == EINTR { continue }
      guard r >= 0 else { throw VenusLost() }
      return r > 0
    }
  }
}
