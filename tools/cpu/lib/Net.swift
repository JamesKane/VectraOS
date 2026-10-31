// SPDX-License-Identifier: BSD-3-Clause

// The terminal's net/ (D104): the dev machine's own sockets as ip(3)'s
// files, so a cpu session that binds /mnt/term/net over its /net dials
// out through the dev machine.
//
//     net/cs              a dial string written, `/net/tcp/clone ADDRESS!PORT`
//                         answers read, one a read (the dev machine's lookup)
//     net/tcp/clone       opened, a new conversation's ctl
//     net/tcp/N/ctl       its number; takes `connect ADDRESS!PORT`, `hangup`
//                         and `close`
//     net/tcp/N/data      its bytes: a read waits for some, one recv
//     net/tcp/N/local     ADDRESS!PORT, and remote the same
//     net/tcp/N/status    its state, then qin and qout
//     net/tcp/N/err       why it last failed
//
// A conversation ends when the last fid open on it is clunked. TCP only,
// and only calls out: UDP, `announce`, ipifc and iproute are refused.

import HostSystem

/// A conversation's file.
enum NetFile: String, CaseIterable {
  case ctl, data, err, local, remote, status
}

/// Runs what it is given one at a time, in the order given, on a thread
/// of its own while it has any: a conversation's reads, and its writes,
/// which the node may send several of at once (its ring's entries).
final class InOrder: @unchecked Sendable {
  let lock = Lock()
  var queued: [@Sendable () -> Void] = []
  var running = false

  func run(_ body: @escaping @Sendable () -> Void) {
    let start = lock.withLock { () -> Bool in
      queued.append(body)
      if running { return false }
      running = true
      return true
    }
    if start { spawn { [self] in drain() } }
  }

  func drain() {
    while true {
      let next = lock.withLock { () -> (@Sendable () -> Void)? in
        guard !queued.isEmpty else {
          running = false
          return nil
        }
        return queued.removeFirst()
      }
      guard let next else { return }
      next()
    }
  }
}

/// A TCP conversation: its socket once connected, and how many of the
/// node's fids hold it open.
final class NetConversation: @unchecked Sendable {
  let number: Int
  let lock = Lock()
  var fd: Int32 = -1
  var holders = 0
  var state = "Closed"
  var err = ""
  let reads = InOrder(), writes = InOrder()

  init(_ number: Int) { self.number = number }
}

final class TerminalNet: @unchecked Sendable {
  let lock = Lock()
  var conversations: [NetConversation] = []

  /// A conversation no fid holds, or a new one, held by the caller.
  func clone() -> NetConversation {
    lock.withLock {
      let c = conversations.first { c in c.lock.withLock { c.holders == 0 && c.fd < 0 } }
        ?? NetConversation(conversations.count)
      if c.number == conversations.count { conversations.append(c) }
      c.lock.withLock { c.holders += 1 }
      return c
    }
  }

  /// Conversation `n`, if it is in use.
  func conversation(_ n: Int) -> NetConversation? {
    lock.withLock {
      guard n >= 0, n < conversations.count else { return nil }
      let c = conversations[n]
      return c.lock.withLock { c.holders > 0 } ? c : nil
    }
  }

  /// The numbers of the conversations in use.
  func inUse() -> [Int] {
    lock.withLock { conversations.filter { c in c.lock.withLock { c.holders > 0 } }.map(\.number) }
  }

  func hold(_ c: NetConversation) { c.lock.withLock { c.holders += 1 } }

  /// A fid on `c` clunked: the last ends it, its socket closed (a read
  /// waiting in it ends first).
  func release(_ c: NetConversation) {
    let fd = c.lock.withLock { () -> Int32 in
      c.holders -= 1
      guard c.holders == 0 else { return -1 }
      defer {
        c.fd = -1
        c.state = "Closed"
        c.err = ""
      }
      return c.fd
    }
    if fd >= 0 {
      shutdown(fd, Int32(SHUT_RDWR))
      HostSystem.close(fd)
    }
  }

  // MARK: ctl

  func control(_ c: NetConversation, _ line: String) throws(Refusal) {
    let words = line.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    switch words.first {
    case "connect" where words.count >= 2:
      try connect(c, words[1])
    case "hangup":
      let fd = c.lock.withLock { () -> Int32 in
        c.state = "Closed"
        return c.fd
      }
      if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
    case "close":
      let fd = c.lock.withLock { c.fd }
      if fd >= 0 { shutdown(fd, Int32(SHUT_WR)) }
    case "keepalive", "ttl", "tos", "ignoreadvice":
      break
    case "announce", "bind", "headers":
      throw .unsupported
    default:
      throw .invalid
    }
  }

  /// Calls `destination`, ADDRESS!PORT; waits until it answers.
  func connect(_ c: NetConversation, _ destination: String) throws(Refusal) {
    guard c.lock.withLock({ c.fd < 0 }) else { throw Refusal("already connected") }
    guard let bang = destination.lastIndex(of: "!") else { throw .invalid }
    let host = String(destination[..<bang]), port = String(destination[destination.index(after: bang)...])
    var hints = addrinfo()
    hints.ai_socktype = streamSocket
    var found: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, port, &hints, &found) == 0, let first = found else { throw .invalid }
    defer { freeaddrinfo(first) }
    var why: Int32 = ECONNREFUSED
    var at: UnsafeMutablePointer<addrinfo>? = first
    while let a = at {
      at = a.pointee.ai_next
      let fd = openSocket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
      guard fd >= 0 else { continue }
      guard HostSystem.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 else {
        why = errno
        HostSystem.close(fd)
        continue
      }
      // The conversation may have ended meanwhile: then the call goes too.
      let kept = c.lock.withLock { () -> Bool in
        guard c.holders > 0 else { return false }
        c.fd = fd
        c.state = "Established"
        c.err = ""
        return true
      }
      if !kept { HostSystem.close(fd) }
      return
    }
    let text = why == ETIMEDOUT ? "connection timed out" : why == ECONNREFUSED ? "connection refused"
      : String(cString: strerror(why))
    c.lock.withLock { c.err = text }
    throw Refusal(text)
  }

  // MARK: data

  /// What has arrived, at most `max` bytes, waiting until something has;
  /// none at the end.
  func read(_ c: NetConversation, max: Int) throws(Refusal) -> [UInt8] {
    let fd = c.lock.withLock { c.fd }
    guard fd >= 0 else { throw Refusal("not connected") }
    var buffer = [UInt8](repeating: 0, count: max)
    while true {
      let got = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, max, 0) }
      if got >= 0 { return Array(buffer[0..<got]) }
      if errno == EINTR { continue }
      // A conversation ended under the read: its end.
      if c.lock.withLock({ c.fd < 0 }) { return [] }
      throw Refusal.errno()
    }
  }

  /// All of `data`, sent.
  func write(_ c: NetConversation, _ data: [UInt8]) throws(Refusal) -> UInt32 {
    let fd = c.lock.withLock { c.fd }
    guard fd >= 0 else { throw Refusal("not connected") }
    var at = 0
    while at < data.count {
      let n = data.withUnsafeBytes { send(fd, $0.baseAddress! + at, data.count - at, sendNoSignal) }
      if n < 0 {
        if errno == EINTR { continue }
        throw Refusal("connection closed")
      }
      at += n
    }
    return UInt32(data.count)
  }

  // MARK: The other files

  func text(_ c: NetConversation, _ file: NetFile) -> String {
    switch file {
    case .ctl: return "\(c.number)"
    case .err: return c.lock.withLock { c.err }
    case .status: return c.lock.withLock { c.state } + " qin 0 qout 0\n"
    case .local, .remote:
      let fd = c.lock.withLock { c.fd }
      guard fd >= 0 else { return "::!0\n" }
      var address = sockaddr_storage()
      var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let got = withUnsafeMutablePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          file == .local ? getsockname(fd, $0, &size) : getpeername(fd, $0, &size)
        }
      }
      return got == 0 ? Self.name(address) + "\n" : "::!0\n"
    case .data: return ""
    }
  }

  /// ADDRESS!PORT, as Plan 9 writes them.
  static func name(_ address: sockaddr_storage) -> String {
    var a = address
    var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    var port: UInt16 = 0
    withUnsafePointer(to: &a) { p in
      if Int32(address.ss_family) == AF_INET {
        p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in
          var addr = s.pointee.sin_addr
          _ = inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
          port = UInt16(bigEndian: s.pointee.sin_port)
        }
      } else {
        p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in
          var addr = s.pointee.sin6_addr
          _ = inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count))
          port = UInt16(bigEndian: s.pointee.sin6_port)
        }
      }
    }
    return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "!\(port)"
  }

  // MARK: cs

  /// cs's answers to a dial string, `net!host!service` (`net` is TCP):
  /// each address the dev machine finds for it.
  func translate(_ query: String) throws(Refusal) -> [String] {
    let parts = query.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else { throw .invalid }
    guard parts[0] == "net" || parts[0] == "tcp" else { throw .unsupported }
    let host = parts[1] == "*" ? "::" : parts[1]
    let service = parts.count > 2 ? parts[2] : ""
    var hints = addrinfo()
    hints.ai_socktype = streamSocket
    var found: UnsafeMutablePointer<addrinfo>?
    let r = getaddrinfo(host, service.isEmpty ? nil : service, &hints, &found)
    guard r == 0, let first = found else {
      // -5 is glibc's EAI_NODATA, which Swift doesn't import: a name with no address.
      throw r == EAI_SERVICE ? .invalid : r == EAI_NONAME || r == -5 ? .notFound : .io
    }
    defer { freeaddrinfo(first) }
    var answers: [String] = []
    var at: UnsafeMutablePointer<addrinfo>? = first
    while let a = at {
      at = a.pointee.ai_next
      var address = sockaddr_storage()
      withUnsafeMutableBytes(of: &address) { b in
        b.copyMemory(from: UnsafeRawBufferPointer(start: a.pointee.ai_addr, count: Int(a.pointee.ai_addrlen)))
      }
      let line = "/net/tcp/clone " + Self.name(address)
      if !answers.contains(line) { answers.append(line) }
    }
    return answers
  }
}
