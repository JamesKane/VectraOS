// SPDX-License-Identifier: BSD-3-Clause

// Plan 9's dial(2) over a namespace's /net (D79): `dial`, `announce`,
// `listen`, `accept` and `reject`, with dial strings, `tcp!10.0.2.2!7`.
// Each is the files ip(3) serves: a clone opened for a conversation, a
// ctl line, the conversation's data. A network's `net` is `tcp`. Hosts
// and services are numbers here; names are /net/cs's to translate.
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
    let (proto, host, service) = try Namespace.split(address)
    var c = try clone(proto)
    let dir = c.dir
    let command = "connect \(host)!\(service)" + (local.map { " " + $0 } ?? "")
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
    let (proto, host, service) = try Namespace.split(address)
    var a = try clone(proto)
    do throws(NodeIPC.NodeClient.Failure) {
      try a.ctl.writeText("announce \(host)!\(service)")
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
      throw DialError("listen: \(error)")
    }
    guard !number.isEmpty, let slash = announced.dir.utf8.lastIndex(of: 0x2F) else {
      throw DialError("listen hungup")
    }
    return NetCall(ctl: listen, dir: String(announced.dir[..<slash]) + "/" + number)
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

  /// A new conversation of `proto`: its ctl and directory.
  func clone(_ proto: String) throws(DialError) -> NetAnnouncement {
    var ctl = try netOpen("/net/\(proto)/clone")
    let number: String
    do throws(NodeIPC.NodeClient.Failure) {
      number = try ctl.readText()
    } catch {
      throw DialError("/net/\(proto)/clone: \(error)")
    }
    guard !number.isEmpty else { throw DialError("/net/\(proto)/clone: no conversation") }
    return NetAnnouncement(ctl: ctl, dir: "/net/\(proto)/\(number)")
  }

  func netOpen(_ path: String) throws(DialError) -> NodeIPC.NodeClient {
    do throws(NamespaceError) { return try open(path) } catch { throw DialError("\(path): \(error)") }
  }

  /// What the conversation's err says went wrong, or the failure itself.
  func reason(_ dir: String, _ error: NodeIPC.NodeClient.Failure) -> String {
    var err = try? netOpen(dir + "/err")
    let text = (try? err?.readText()) ?? ""
    return text.isEmpty ? "\(error)" : text
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
