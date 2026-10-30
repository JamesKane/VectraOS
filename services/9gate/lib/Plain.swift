// SPDX-License-Identifier: BSD-3-Clause

// 9gate's plain listener (D148): 9P2000 with neither Noise IK nor any
// authentication, for peers that speak neither, Linux's v9fs and 9front.
// A ctl line opens it, never anything else:
//
//     plain ADDR ROOT ALLOW...
//
// It takes calls to ADDR (`tcp!*!564`, or one address of ours, which
// net's announce doesn't hold it to, so a call to another is hung up),
// and only from the addresses and prefixes ALLOW names (`192.168.0.25`,
// `192.168.0.0/24`, `fe80::/10`); any other caller is hung up before a
// byte is read. Tauth is refused, as on every export, and the dialect
// is plain 9P2000, never `9P2000.vx`. A caller's Tattach name is
// recorded in status, not trusted: the files are still `none`'s.

import Net
import Node
import Sys

/// The callers a plain listener takes: addresses and prefixes, IPv4's
/// mapped into IPv6.
public struct Allowed: Sendable {
  let prefixes: [(address: IPv6Address, length: Int)]

  /// `words`' addresses and prefixes (an address alone is its own /32 or
  /// /128); nil if there are none, or one isn't either.
  public init?(_ words: [String]) {
    var prefixes: [(address: IPv6Address, length: Int)] = []
    for w in words {
      let b = Array(w.utf8)
      let slash = b.firstIndex(of: 0x2F)
      guard let address = Allowed.address(slash.map { Array(b[..<$0]) } ?? b) else { return nil }
      let v4 = address.mappedIPv4 != nil
      var length = 128
      if let slash {
        let digits = b[(slash + 1)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), digits.count <= 3 else { return nil }
        let n = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        guard n <= (v4 ? 32 : 128) else { return nil }
        length = v4 ? 96 + n : n
      }
      prefixes.append((address, length))
    }
    guard !prefixes.isEmpty else { return nil }
    self.prefixes = prefixes
  }

  /// Whether `a` is in one of them.
  public func admits(_ a: IPv6Address) -> Bool {
    prefixes.contains { a.hasPrefix($0.address, length: $0.length) }
  }

  /// The words, as given but canonical (`10.0.0.0/8`).
  public var text: String {
    var out: [String] = []
    for p in prefixes {
      let v4 = p.address.mappedIPv4
      let whole = p.length == 128
      let bits = v4 != nil ? p.length - 96 : p.length
      out.append((v4?.text ?? p.address.text) + (whole ? "" : "/\(bits)"))
    }
    return out.joined(separator: " ")
  }

  /// An address, IPv4's mapped; nil if `bytes` isn't one.
  static func address(_ bytes: [UInt8]) -> IPv6Address? {
    let text = String(decoding: bytes, as: UTF8.self)
    if let v4 = IPv4Address(text) { return IPv6Address(mapping: v4) }
    return IPv6Address(text)
  }

  /// The host of `host!port` (a conversation's `local` or `remote`).
  static func host(_ text: String) -> IPv6Address? {
    address(Array(text.utf8.prefix { $0 != 0x21 && $0 != 0x0A }))
  }
}

/// A plain listener: what its line said, how it went, and its callers.
final class PlainListener: @unchecked Sendable {
  let address: String
  let root: String
  let allowed: Allowed
  /// The address of ours calls must come to, or nil for any (`*`).
  let local: IPv6Address?
  var state = "announcing"
  /// Callers connected: where from, and the names they attached as.
  var callers: [(id: Int, remote: String, names: [String])] = []
  var nextCaller = 0

  init(address: String, root: String, allowed: Allowed, local: IPv6Address?) {
    self.address = address
    self.root = root
    self.allowed = allowed
    self.local = local
  }

  /// `address`'s host: nil for `*`, the address for one, and `.none` if
  /// it's neither (a name: cs's choice of address, which calls can't be
  /// held to).
  static func local(_ address: String) -> IPv6Address?? {
    let w = address.utf8.split(separator: 0x21, omittingEmptySubsequences: false)
    guard w.count == 3 else { return .none }
    if w[1].elementsEqual("*".utf8) { return .some(nil) }
    guard let a = Allowed.address(Array(w[1])) else { return .none }
    return .some(a)
  }
}

extension GateService {
  /// `plain ADDR ROOT ALLOW...`.
  func plain(_ address: String, root: String, allow: [String]) throws(NodeError) {
    guard let allowed = Allowed(allow), let local = PlainListener.local(address) else { throw .invalid }
    let l = PlainListener(address: address, root: root, allowed: allowed, local: local)
    try lock.withLock { () throws(NodeError) in
      guard !listeners.contains(where: { NodeIPC.same($0.address, address) }),
            !plains.contains(where: { NodeIPC.same($0.address, address) })
      else { throw .exists }
      plains.append(l)
    }
    do throws(Status) {
      _ = try Thread.spawn { [self] in servePlain(l) }
    } catch { throw .io }
  }

  func setPlain(_ l: PlainListener, _ state: String) {
    lock.withLock { l.state = state }
    onChange()
  }

  var plainStatus: String {
    var out = ""
    for l in plains {
      out += "plain \(l.address) \(l.root) \(l.allowed.text) \(l.state)\n"
      for c in l.callers {
        out += "caller \(l.address) \(c.remote)" + c.names.map { " " + $0 }.joined() + "\n"
      }
    }
    return out
  }

  func servePlain(_ l: PlainListener) {
    let a: NetAnnouncement
    do throws(DialError) { a = try namespace.announce(l.address) } catch {
      return setPlain(l, "failed: \(error.reason)")
    }
    setPlain(l, "listening")
    while true {
      let call: NetCall
      do throws(DialError) { call = try namespace.listen(a) } catch {
        return setPlain(l, "failed: \(error.reason)")
      }
      let dir = call.dir
      let remote = text(dir + "/remote")
      guard let from = Allowed.host(remote), l.allowed.admits(from),
            l.local.map({ Allowed.host(text(dir + "/local")) == $0 }) ?? true
      else {
        namespace.reject(call)
        continue
      }
      let c: NetConnection
      do throws(DialError) { c = try namespace.accept(call) } catch { continue }
      guard let stream = Self.stream(namespace, c) else { continue }
      let id = lock.withLock {
        defer { l.nextCaller += 1 }
        l.callers.append((l.nextCaller, String(decoding: remote.utf8.prefix { $0 != 0x0A }, as: UTF8.self), []))
        return l.nextCaller
      }
      onChange()
      do throws(Status) {
        _ = try Thread.spawn { [self] in
          _ = Export.serve(stream, namespace: namespace, root: l.root, extended: false) { [self] uname in
            // The caller's to choose: no space or control byte reaches status.
            guard !uname.isEmpty else { return }
            let name = String(decoding: uname.utf8.map { $0 <= 0x20 || $0 == 0x7F ? 0x3F : $0 }, as: UTF8.self)
            lock.withLock {
              guard let i = l.callers.firstIndex(where: { $0.id == id }),
                    !l.callers[i].names.contains(where: { NodeIPC.same($0, name) })
              else { return }
              l.callers[i].names.append(name)
            }
            onChange()
          }
          lock.withLock { l.callers.removeAll { $0.id == id } }
          onChange()
        }
      } catch {
        lock.withLock { l.callers.removeAll { $0.id == id } }
        stream.close()
      }
    }
  }

  /// A file's text, or nothing.
  func text(_ path: String) -> String {
    guard var f = try? namespace.open(path), let t = try? f.readText() else { return "" }
    return t
  }
}
