// SPDX-License-Identifier: BSD-3-Clause

// fs(4)'s protocol on an import's channels (D151): what 9P2000 and
// 9P2000.vx carry of it. A resize is a wstat of the length, a sync a
// wstat that changes nothing (Plan 9's request to make a file durable),
// and a rename one within a directory, or a Trename between two when the
// server speaks 9P2000.vx. Each goes on a thread of its own, the call's
// reply held until it is done, as a batch's is: the dispatcher never
// waits on the network. The rest of fs's protocol (typed attributes,
// listings with them, queries, maps) answers `unsupported` until an
// extension carries it.

import Fs
import IPC
import NineP
import Node
import Sys

/// Which fs call a held reply answers.
enum FsCall: Sendable {
  case resize, fileSync, directorySync, rename
}

extension ImportSession: FsIPC.FileHandler, FsIPC.DirectoryHandler {
  mutating func getAttribute(_ name: String) throws(FsIPC.FsError) -> FsIPC.Attribute { throw .unsupported }
  mutating func setAttribute(_ attribute: FsIPC.Attribute) throws(FsIPC.FsError) { throw .unsupported }
  mutating func removeAttribute(_ name: String) throws(FsIPC.FsError) { throw .unsupported }
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
    try held(.resize) { (gate: Import) throws(FsIPC.FsError) in
      do throws(GateError) { try gate.client.wstat(fid, d) } catch { throw Import.fsCode(error) }
    }
  }

  mutating func sync() throws(FsIPC.FsError) {
    let fid = state.fid
    try held(state.directory ? .directorySync : .fileSync) { (gate: Import) throws(FsIPC.FsError) in
      do throws(GateError) { try gate.client.wstat(fid, Dir.unchanged) } catch { throw Import.fsCode(error) }
    }
  }

  mutating func rename(_ from: String, to: String) throws(FsIPC.FsError) {
    let source = NodeIPC.names(from), target = NodeIPC.names(to)
    guard !source.isEmpty, !target.isEmpty, NodeIPC.isValidName(target[target.count - 1]) else { throw .badName }
    let fid = state.fid
    try held(.rename) { (gate: Import) throws(FsIPC.FsError) in try gate.rename(at: fid, source, to: target) }
  }

  /// Runs `body` on a thread of its own, this call's reply held until it
  /// is done: `call`'s reply, or its error.
  func held(_ call: FsCall, _ body: @escaping @Sendable (Import) throws(FsIPC.FsError) -> Void) throws(FsIPC.FsError) {
    guard let header = state.deferral.hold() else { throw .io }
    let gate = self.gate, state = self.state
    do throws(Status) {
      try gate.workers.run {
        do throws(FsIPC.FsError) {
          try body(gate)
          state.pushFs(header, call, code: 0)
        } catch {
          state.pushFs(header, call, code: error.rawValue)
        }
      }
    } catch {
      state.pushFs(header, call, code: FsIPC.FsError.io.rawValue)
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

  /// fs's error for a 9P failure: the server's text read back.
  static func fsCode(_ e: GateError) -> FsIPC.FsError {
    guard case .error(let text) = e else { return .io }
    return Errors.fsCode(text)
  }
}
