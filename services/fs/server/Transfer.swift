// SPDX-License-Identifier: BSD-3-Clause

// Send and receive (S2, D153 §2): fs's `send`, where a write of `[A] B`
// (snapshots' names) starts a stream of the changes from A to B, or of
// all of B, read from it in order; and `receive/<sys>`, where a stream
// written is applied to the volume's `recv/<sys>`, which then takes a
// snapshot. One stream an open. Served on the volume's thread by Node
// alone, as the snapshots are.

import Fs
import IPC
import Node
import Sys
import Taisce

/// Where a transfer channel is.
enum TransferPlace {
  case send
  case receiving
  case receive([UInt8])
}

/// One open's stream: one sending, or one being received.
final class TransferState {
  var stream: SendStream?
  var receiver: Receiver?
  /// The offset the next read or write must be at: streams go in order.
  var at: UInt64 = 0
  var failed = false
}

extension FsService {
  /// Channels to `send` and to `receive`.
  public func sendRoot() throws(NodeError) -> Handle { try transferChannel(.send) }
  public func receiveRoot() throws(NodeError) -> Handle { try transferChannel(.receiving) }

  /// `send` and `receive` served on channels made before the volume was
  /// mounted.
  public func serveSend(_ channel: consuming Handle) throws(Status) { try serveTransfer(channel, .send) }
  public func serveReceive(_ channel: consuming Handle) throws(Status) { try serveTransfer(channel, .receiving) }

  func serveTransfer(_ channel: consuming Handle, _ place: TransferPlace) throws(Status) {
    try dispatcher.add(NodeIPC.NodeServer(channel: channel,
                                          impl: TransferSession(service: self, place: place, state: TransferState())))
  }

  func transferChannel(_ place: TransferPlace) throws(NodeError) -> Handle {
    do throws(Status) {
      let ends = try Channel.create()
      try serveTransfer(ends.b, place)
      return ends.a
    } catch {
      throw .io
    }
  }

  /// A send's start: `[A] B`, snapshots' names.
  func startSend(_ state: TransferState, _ spec: [UInt8]) throws(NodeError) {
    guard state.stream == nil else { throw .exists }
    let words = spec.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 }).map { Array($0) }
    guard words.count == 1 || words.count == 2 else { throw .invalid }
    let all = snapshotList()
    func named(_ name: [UInt8]) throws(NodeError) -> SnapshotRecord {
      guard let s = all.first(where: { $0.name == name }) else { throw .notFound }
      return s
    }
    let from = words.count == 2 ? try named(words[0]) : nil
    let to = try named(words[words.count - 1])
    do throws(TaisceError) {
      state.stream = try fs.send(from: from, to: to)
    } catch {
      throw Self.nodeError(error)
    }
  }

  func readSend(_ state: TransferState, offset: UInt64, max: UInt32) throws(NodeError) -> [UInt8] {
    guard state.stream != nil else { throw .invalid }
    guard offset == state.at else { throw .invalid }
    do throws(TaisceError) {
      let bytes = try fs.read(&state.stream!, max: Swift.min(Int(max), NodeIPC.maxIO))
      state.at += UInt64(bytes.count)
      return bytes
    } catch {
      throw Self.nodeError(error)
    }
  }

  /// The volume's `recv/<sys>`, made if it isn't there.
  func receiveDirectory(_ sys: [UInt8]) throws(TaisceError) -> UInt64 {
    let root = FileSystem<VolumeDevice>.root
    func here(_ dir: UInt64, _ name: [UInt8]) throws(TaisceError) -> UInt64 {
      do throws(TaisceError) {
        return try fs.lookup(dir, name)
      } catch .notFound {
        return try fs.create(dir, name, .directory, mode: 0o755, now: Self.now)
      }
    }
    return try here(try here(root, Array("recv".utf8)), sys)
  }

  func writeReceive(_ state: TransferState, _ sys: [UInt8], offset: UInt64, _ data: [UInt8]) throws(NodeError)
    -> UInt32
  {
    guard !state.failed, offset == state.at else { throw .invalid }
    let name = String(decoding: sys, as: UTF8.self)
    do throws(TaisceError) {
      if state.receiver == nil {
        // Writes behind first: the stream's writes go to the volume.
        _ = writeBackAll()
        state.receiver = fs.receiver(into: try receiveDirectory(sys))
      }
      defer {
        for ino in state.receiver!.touched { cacheGone(ino) }
        cacheRenamed()
      }
      try fs.receive(&state.receiver!, data, now: Self.now)
      state.at += UInt64(data.count)
      if state.receiver!.done {
        let s = try fs.takeSnapshot(now: Self.now)
        commits += 1
        noteRequest("receive " + name + " to txg \(state.receiver!.to) done, snap " + String(decoding: s.name, as: UTF8.self))
      }
    } catch {
      state.failed = true
      noteRequest("receive " + name + " failed: " + Self.words(error))
      changed()
      throw Self.nodeError(error)
    }
    changed()
    return UInt32(data.count)
  }

  /// The volume's `recv/`'s directories.
  func received() -> [[UInt8]] {
    do throws(TaisceError) {
      let recv = try fs.lookup(FileSystem<VolumeDevice>.root, Array("recv".utf8))
      return try fs.list(recv).filter { $0.entry.type == .directory }.map { $0.entry.name }
    } catch {
      return []
    }
  }
}

/// One channel to `send`, `receive` or one of its names.
struct TransferSession: NodeIPC.NodeHandler {
  let service: FsService
  let place: TransferPlace
  let state: TransferState

  mutating func batch(_ ops: [NodeIPC.Op], open: Bool) -> NodeIPC.Reply {
    var results: [NodeIPC.Outcome] = []
    guard ops.count <= NodeIPC.maxOps else { return failed(results, 0, .tooManyOps) }
    var at = place
    for i in ops.indices {
      do throws(NodeError) {
        switch ops[i] {
        case .walk(let names):
          var qids: [NodeIPC.Qid] = []
          for name in names {
            at = try step(at, name)
            qids.append(Self.qid(at))
          }
          results.append(.walked(qids))
        case .stat: results.append(.stat(Self.stat(at)))
        case .readdir(let cursor, _, _):
          guard case .receiving = at else { throw .notDirectory }
          let names = cursor == 0 ? service.received() : []
          results.append(.dir(NodeIPC.DirBatch(entries: names.map { Self.stat(.receive($0)) }, next: 1, done: true)))
        case .read(let offset, let max):
          guard case .send = at else { throw .invalid }
          results.append(.data(try service.readSend(state, offset: offset, max: max)))
        case .write(let offset, let data):
          switch at {
          case .send:
            try service.startSend(state, data)
            results.append(.wrote(UInt32(data.count)))
          case .receive(let sys):
            results.append(.wrote(try service.writeReceive(state, sys, offset: offset, data)))
          case .receiving: throw .isDirectory
          }
        case .create(let name, let kind):
          guard case .receiving = at, kind == .file else { throw .denied }
          at = try step(at, name)
          results.append(.created(Self.qid(at)))
        case .watch: throw .unsupported
        case .remove: throw .denied
        }
      } catch {
        return failed(results, i, error)
      }
    }
    guard open else { return NodeIPC.Reply(results: results, failure: nil, node: nil) }
    do throws(NodeError) {
      return NodeIPC.Reply(results: results, failure: nil, node: try service.transferChannel(at))
    } catch {
      return failed(results, ops.count, error)
    }
  }

  func failed(_ results: [NodeIPC.Outcome], _ index: Int, _ error: NodeError) -> NodeIPC.Reply {
    NodeIPC.Reply(results: results, failure: NodeIPC.Failure(index: UInt32(index), code: error.rawValue), node: nil)
  }

  func step(_ at: TransferPlace, _ name: String) throws(NodeError) -> TransferPlace {
    if NodeIPC.same(name, "..") { if case .receive = at { return .receiving } else { return at } }
    guard NodeIPC.isValidName(name) else { throw .badName }
    guard case .receiving = at else { throw .notDirectory }
    return .receive(Array(name.utf8))
  }

  static func qid(_ at: TransferPlace) -> NodeIPC.Qid {
    switch at {
    case .send: NodeIPC.Qid(path: 1 << 63 | 1 << 61 | 1, version: 0, kind: .file)
    case .receiving: NodeIPC.Qid(path: 1 << 63 | 1 << 61 | 2, version: 0, kind: .directory)
    case .receive(let n):
      NodeIPC.Qid(path: 1 << 63 | 1 << 61 | 1 << 32 | n.reduce(UInt64(0)) { ($0 &* 31 &+ UInt64($1)) & 0xFFFF_FFFF },
                  version: 0, kind: .file)
    }
  }

  static func stat(_ at: TransferPlace) -> NodeIPC.Stat {
    let name: String
    switch at {
    case .send: name = "send"
    case .receiving: name = "receive"
    case .receive(let n): name = String(decoding: n, as: UTF8.self)
    }
    return NodeIPC.Stat(qid: qid(at), name: name, size: 0, modified: 0, attributes: [])
  }

  mutating func openAhead(_ ops: [NodeIPC.Op], max: UInt32) -> NodeIPC.Ahead { NodeIPC.Ahead(batch(ops, open: true)) }
  func openFid(_ ops: [NodeIPC.Op], fid: UInt32, ahead: UInt32, clunk: [UInt32]) throws(NodeError) -> NodeIPC.Ahead {
    throw .unsupported
  }
  func fidBatch(_ fid: UInt32, _ ops: [NodeIPC.Op], open: Bool, clunk: [UInt32]) throws(NodeError) -> NodeIPC.Reply {
    throw .unsupported
  }
  func clunk(_ fids: [UInt32]) throws(NodeError) { throw .unsupported }
  func attach(_ bulk: consuming NodeIPC.Bulk) throws(NodeError) { throw .unsupported }
  func memory(executable: Bool) throws(NodeError) -> NodeIPC.Memory { throw .unsupported }
  /// A truncate, which rc's `>` asks of what it opens: nothing to cut.
  func wstat(_ change: NodeIPC.Wstat) throws(NodeError) {
    guard change.name == nil, change.modified == nil, change.size == nil || change.size == 0 else { throw .denied }
  }

  /// The same place, with a stream of its own.
  func clone(_ channel: consuming Handle) {
    _ = try? service.dispatcher.add(NodeIPC.NodeServer(channel: channel,
                                                       impl: TransferSession(service: service, place: place,
                                                                             state: TransferState())))
  }
}
