// SPDX-License-Identifier: BSD-3-Clause

// Plan 9's dial(2) over a namespace's /net (D79): `dial`, `announce`,
// `listen`, `accept` and `reject`, with dial strings, `tcp!10.0.2.2!7`.
// Each is the files ip(3) serves: a clone opened for a conversation, a
// ctl line, the conversation's data. /net/cs translates a dial string
// into the clone files and addresses to call, names and all, and `dial`
// tries each until one answers; with no /net/cs, the network (`net` is
// `tcp`), host and service are used as they are, numbers.
//
//     var c = try ns.dial("tcp!10.0.2.2!7")
//     _ = try c.data.write(offset: 0, Array("hello".utf8))
//
//     let a = try ns.announce("tcp!*!7")
//     var call = try ns.listen(a)
//     var c = try ns.accept(call)

import IPC

/// Why a dial failed, as Plan 9's errstr says it.
public struct DialError: Error, Equatable, Sendable {
  public var reason: String
  public init(_ reason: String) { self.reason = reason }
}

/// A conversation: its ctl and data channels, and its directory
/// (`/net/tcp/4`).
public struct NetConnection: ~Copyable {
  public var ctl: NodeIPC.NodeClient
  public var data: NodeIPC.NodeClient
  public let dir: String
}

/// An announced conversation: its ctl, which holds the announcement while
/// open, and its directory.
public struct NetAnnouncement: ~Copyable {
  public var ctl: NodeIPC.NodeClient
  public let dir: String
}

/// A call that `listen` gave: the new conversation's ctl (listen's
/// channel, which holds it) and directory.
public struct NetCall: ~Copyable {
  public var ctl: NodeIPC.NodeClient
  public let dir: String
}

extension Namespace {
  /// Dials `address` (`net!host!service`): the connection, once
  /// established. `local`, a port, is UDP's own.
  public func dial(_ address: String, local: String? = nil) throws(DialError) -> NetConnection {
    var failure = DialError("can't translate address")
    for (clone, destination) in try translate(address) {
      do throws(DialError) {
        return try call(clone, destination, local: local)
      } catch {
        failure = error
      }
    }
    throw failure
  }

  /// Calls `destination` through a conversation of the network whose
  /// clone is `clone`.
  func call(_ clone: String, _ destination: String, local: String?) throws(DialError) -> NetConnection {
    var c = try self.clone(clone)
    let dir = c.dir
    let command = "connect \(destination)" + (local.map { " " + $0 } ?? "")
    do throws(NodeIPC.NodeClient.Failure) {
      try c.ctl.writeText(command)
    } catch {
      throw DialError(reason(dir, error))
    }
    let data = try netOpen(dir + "/data")
    return NetConnection(ctl: c.ctl, data: data, dir: dir)
  }

  /// Announces `address` (`net!*!service`, or a host of ours): calls to it
  /// come through `listen`.
  public func announce(_ address: String) throws(DialError) -> NetAnnouncement {
    guard let first = try translate(address).first else { throw DialError("can't translate address") }
    var a = try self.clone(first.0)
    do throws(NodeIPC.NodeClient.Failure) {
      try a.ctl.writeText("announce \(first.1)")
    } catch {
      throw DialError(reason(a.dir, error))
    }
    return a
  }

  /// Waits for a call to `announced`.
  public func listen(_ announced: borrowing NetAnnouncement) throws(DialError) -> NetCall {
    var listen = try netOpen(announced.dir + "/listen")
    let number: String
    do throws(NodeIPC.NodeClient.Failure) {
      number = try listen.readText()
    } catch {
      throw DialError("listen: \(NamespaceError(error).text)")
    }
    guard !number.isEmpty, let slash = announced.dir.utf8.lastIndex(of: 0x2F) else {
      throw DialError("listen hungup")
    }
    return NetCall(ctl: listen, dir: String(decoding: announced.dir.utf8[..<slash], as: UTF8.self) + "/" + number)
  }

  /// Takes `call`: its data opened.
  public func accept(_ call: consuming NetCall) throws(DialError) -> NetConnection {
    let data = try netOpen(call.dir + "/data")
    let dir = call.dir
    return NetConnection(ctl: call.ctl, data: data, dir: dir)
  }

  /// Refuses `call`: hung up, as Plan 9's reject does.
  public func reject(_ call: consuming NetCall) {
    var ctl = try? open(call.dir + "/ctl")
    try? ctl?.writeText("hangup")
    _ = consume call
  }

  /// A new conversation from the clone file at `path`: its ctl and
  /// directory.
  func clone(_ path: String) throws(DialError) -> NetAnnouncement {
    var ctl = try netOpen(path)
    let number: String
    do throws(NodeIPC.NodeClient.Failure) {
      number = try ctl.readText()
    } catch {
      throw DialError("\(path): \(NamespaceError(error).text)")
    }
    guard !number.isEmpty, let slash = path.utf8.lastIndex(of: 0x2F) else {
      throw DialError("\(path): no conversation")
    }
    return NetAnnouncement(ctl: ctl, dir: String(decoding: path.utf8[..<slash], as: UTF8.self) + "/" + number)
  }

  /// Where to call `address`: each clone file and the address to write
  /// its conversation's ctl, as /net/cs gives them; with no /net/cs, the
  /// network's clone and the host and service as they are.
  func translate(_ address: String) throws(DialError) -> [(String, String)] {
    let (proto, host, service) = try Namespace.split(address)
    guard var cs = try? open("/net/cs") else { return [("/net/\(proto)/clone", "\(host)!\(service)")] }
    do throws(NodeIPC.NodeClient.Failure) {
      _ = try cs.write(offset: 0, Array((address.utf8.first == 0x21 ? "net" + address : address).utf8))
    } catch {
      switch error {
      case .remote(.notFound): throw DialError("can't translate address")
      case .remote(.invalid): throw DialError("can't translate service")
      case .remote(.io): throw DialError("temporary problem: dns failure")
      default: throw DialError("/net/cs: \(NamespaceError(error).text)")
      }
    }
    var out: [(String, String)] = []
    while let reply = try? cs.read(offset: 0, max: 256), !reply.isEmpty {
      guard let space = reply.firstIndex(of: 0x20) else { continue }
      out.append((String(decoding: reply[..<space], as: UTF8.self),
                  String(decoding: reply[(space + 1)...], as: UTF8.self)))
    }
    return out
  }

  /// The value of `attr` in the database's entry for the system `name`
  /// (cs's `!sys=NAME` query, ndb(8)): a swarm member's `key` (D152);
  /// nil if cs has no such entry, or the entry no such attribute.
  public func ndbValue(sys name: String, attr: String) -> String? {
    guard var cs = try? open("/net/cs"), (try? cs.write(offset: 0, Array("!sys=\(name)".utf8))) != nil else { return nil }
    let wanted = Array((attr + "=").utf8)
    while let reply = try? cs.read(offset: 0, max: 1024), !reply.isEmpty {
      for pair in reply.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A }) where pair.starts(with: wanted) {
        return String(decoding: pair.dropFirst(wanted.count), as: UTF8.self)
      }
    }
    return nil
  }

  func netOpen(_ path: String) throws(DialError) -> NodeIPC.NodeClient {
    do throws(NamespaceError) { return try open(path) } catch { throw DialError("\(path): \(error.text)") }
  }

  /// What the conversation's err says went wrong, or the failure itself.
  func reason(_ dir: String, _ error: NodeIPC.NodeClient.Failure) -> String {
    var err = try? netOpen(dir + "/err")
    let text = (try? err?.readText()) ?? ""
    return text.isEmpty ? NamespaceError(error).text : text
  }

  /// A dial string's network (`net` is TCP), host and service.
  static func split(_ address: String) throws(DialError) -> (String, String, String) {
    let parts = address.utf8.split(separator: 0x21, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { throw DialError("bad address: \(address)") }
    let net = parts[0].utf8.elementsEqual("net".utf8) || parts[0].isEmpty ? "tcp" : parts[0]
    return (net, parts[1], parts[2])
  }
}
