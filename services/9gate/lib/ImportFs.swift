// SPDX-License-Identifier: BSD-3-Clause

// fs(4)'s protocol on an import's channels (D151): what 9P2000 and
// 9P2000.vx carry of it. A resize is a wstat of the length, a sync a
// wstat that changes nothing (Plan 9's request to make a file durable),
// and a rename one within a directory, or a Trename between two when the
// server speaks 9P2000.vx; typed attributes are 9P2000.vx's Tgetattrs,
// Tsetattr and Tdelattr. Each goes on a thread of its own, the call's
// reply held until it is done, as a batch's is: the dispatcher never
// waits on the network. The rest of fs's protocol (listings with
// attributes, queries, maps) answers `unsupported` until an extension
// carries it.

import Fs
import IPC
import NineP
import Node
import Sys

/// Which fs call a held reply answers.
enum FsCall: Sendable {
  case resize, fileSync, directorySync, rename, setAttribute, removeAttribute
  /// The attribute got.
  case getAttribute(FsIPC.Attribute)
}

extension ImportSession: FsIPC.FileHandler, FsIPC.DirectoryHandler {
  mutating func getAttribute(_ name: String) throws(FsIPC.FsError) -> FsIPC.Attribute {
    let fid = state.fid
    try held { (gate: Import) throws(FsIPC.FsError) -> FsCall in
      let all: [VxAttribute]
      do throws(GateError) { all = try gate.attributes(fid) } catch { throw Import.fsCode(error) }
      guard let a = all.first(where: { NodeIPC.same($0.name, name) }) else { throw .notFound }
      return .getAttribute(FsIPC.Attribute(name: a.name, kind: a.kind, value: a.value))
    }
    // Held: the reply goes when the thread is done.
    return FsIPC.Attribute(name: name, kind: 0, value: [])
  }

  mutating func setAttribute(_ attribute: FsIPC.Attribute) throws(FsIPC.FsError) {
    let fid = state.fid, a = VxAttribute(name: attribute.name, kind: attribute.kind, value: attribute.value)
    try held { (gate: Import) throws(FsIPC.FsError) -> FsCall in
      do throws(GateError) { try gate.withExtension { () throws(GateError) in try gate.client.setattr(fid, a) } } catch {
        throw Import.fsCode(error)
      }
      return .setAttribute
    }
  }

  mutating func removeAttribute(_ name: String) throws(FsIPC.FsError) {
    let fid = state.fid
    try held { (gate: Import) throws(FsIPC.FsError) -> FsCall in
      do throws(GateError) { try gate.withExtension { () throws(GateError) in try gate.client.delattr(fid, name) } } catch {
        throw Import.fsCode(error)
      }
      return .removeAttribute
    }
  }
  mutating func map() throws(FsIPC.FsError) -> FsIPC.FileMap { throw .unsupported }
  mutating func capability(writable: Bool) throws(FsIPC.FsError) -> Handle { throw .unsupported }
  mutating func list(cursor: UInt64, max: UInt32, attributes: [String]) throws(FsIPC.FsError) -> FsIPC.Listing {
    throw .unsupported
  }
  mutating func wholeListing(attributes: [String]) throws(FsIPC.FsError) -> Handle { throw .unsupported }
  mutating func query(_ text: String, scan: Bool) throws(FsIPC.FsError) -> [FsIPC.Match] { throw .unsupported }
  mutating func live(_ text: String, scan: Bool) throws(FsIPC.FsError) -> Handle { throw .unsupported }
  mutating func declareIndex(_ name: String, kind: UInt8, caseless: Bool) throws(FsIPC.FsError) { throw .unsupported }
  mutating func indices() -> [FsIPC.IndexInfo] { [] }

  mutating func resize(_ size: UInt64) throws(FsIPC.FsError) {
    var change = Dir.unchanged
    change.length = size
    let fid = state.fid, d = change
    try held { (gate: Import) throws(FsIPC.FsError) -> FsCall in
      do throws(GateError) { try gate.client.wstat(fid, d) } catch { throw Import.fsCode(error) }
      return .resize
    }
  }

  mutating func sync() throws(FsIPC.FsError) {
    let fid = state.fid
    let call: FsCall = state.directory ? .directorySync : .fileSync
    try held { (gate: Import) throws(FsIPC.FsError) -> FsCall in
      do throws(GateError) { try gate.client.wstat(fid, Dir.unchanged) } catch { throw Import.fsCode(error) }
      return call
    }
  }

  mutating func rename(_ from: String, to: String) throws(FsIPC.FsError) {
    let source = NodeIPC.names(from), target = NodeIPC.names(to)
    guard !source.isEmpty, !target.isEmpty, NodeIPC.isValidName(target[target.count - 1]) else { throw .badName }
    let fid = state.fid
    try held { (gate: Import) throws(FsIPC.FsError) -> FsCall in
      try gate.rename(at: fid, source, to: target)
      return .rename
    }
  }

  /// Runs `body` on a thread of its own, this call's reply held until it
  /// is done: the reply `body` says, or its error.
  func held(_ body: @escaping @Sendable (Import) throws(FsIPC.FsError) -> FsCall) throws(FsIPC.FsError) {
    guard let header = state.deferral.hold() else { throw .io }
    let gate = self.gate, state = self.state
    do throws(Status) {
      try gate.workers.run {
        do throws(FsIPC.FsError) {
          state.pushFs(header, try body(gate), code: 0)
        } catch {
          state.pushFs(header, .resize, code: error.rawValue)
        }
      }
    } catch {
      state.pushFs(header, .resize, code: FsIPC.FsError.io.rawValue)
    }
  }
}

extension Import {
  /// `source` (names below the directory at `fid`) moved to `target`: a
  /// wstat of its name within one directory, else 9P2000.vx's Trename.
  func rename(at fid: UInt32, _ source: [String], to target: [String]) throws(FsIPC.FsError) {
    let file = client.fid()
    do throws(GateError) {
      let walked = try client.walk(fid, file, source)
      guard walked.count == source.count else { throw GateError.error(Errors.text(.notFound)) }
    } catch {
      client.release(file)
      throw Self.fsCode(error)
    }
    defer { client.clunk(file) }
    let name = target[target.count - 1]
    if source.dropLast().elementsEqual(target.dropLast(), by: { NodeIPC.same($0, $1) }) {
      var d = Dir.unchanged
      d.name = name
      do throws(GateError) { try client.wstat(file, d) } catch { throw Self.fsCode(error) }
      return
    }
    guard client.extended else { throw .unsupported }
    let dir = client.fid()
    do throws(GateError) {
      let walked = try client.walk(fid, dir, Array(target.dropLast()))
      guard walked.count == target.count - 1 else { throw GateError.error(Errors.text(.notFound)) }
    } catch {
      client.release(dir)
      throw Self.fsCode(error)
    }
    defer { client.clunk(dir) }
    do throws(GateError) { try client.rename(file, into: dir, as: name) } catch { throw Self.fsCode(error) }
  }

  /// `fid`'s file's typed attributes: none from a server without
  /// 9P2000.vx.
  func attributes(_ fid: UInt32) throws(GateError) -> [VxAttribute] {
    guard client.extended else { return [] }
    return try client.getattrs(fid)
  }

  /// `body`, a 9P2000.vx call: `unsupported` from a server without it.
  func withExtension(_ body: () throws(GateError) -> Void) throws(GateError) {
    guard client.extended else { throw .error(Errors.text(.unsupported)) }
    try body()
  }

  /// fs's error for a 9P failure: the server's text read back.
  static func fsCode(_ e: GateError) -> FsIPC.FsError {
    guard case .error(let text) = e else { return .io }
    return Errors.fsCode(text)
  }
}
