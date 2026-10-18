// SPDX-License-Identifier: BSD-3-Clause

// Taisce's BlockDevice over a disk's partition (D82): sd(3)'s `data`,
// read and written on the partition channel's ring (D103), each read and
// write waited for, up to the ring's entries under way; or, if the disk
// won't attach one, over Node, a batch moving up to 32 pieces of maxIO
// bytes (a MiB). Its length is the partition's, in Taisce's blocks. Its
// barrier is the unit's ctl's `flush` (D106): every write before it was
// answered, so the flush makes them all durable.

import IPC
import Node
import Sys
import Taisce

/// The partition's channel, shared by copies of the device (Taisce copies
/// devices; the channel is one).
final class Partition {
  static let slots = 16
  static let dataSize = 16 * 131072
  var client: NodeIPC.NodeClient
  var ring: NodeBulkChannel?
  /// The unit's ctl, if the disk has one: where a flush goes.
  var ctl: NodeIPC.NodeClient?

  init(_ client: consuming NodeIPC.NodeClient, ctl: consuming NodeIPC.NodeClient?) {
    self.client = client
    self.ctl = ctl
    ring = try? NodeBulkChannel(attachingTo: &self.client, slots: Self.slots, dataSize: Self.dataSize)
  }
}

public struct NodeDevice: BlockDevice {
  let partition: Partition
  public let blockSize = Layout.blockSize
  public let blockCount: UInt64

  /// A device over `channel`, a partition's file, flushed through `ctl`,
  /// its unit's (none: a disk with nothing to flush).
  public init(_ channel: consuming Handle, ctl: consuming Handle? = nil) throws(TaisceError) {
    var client = NodeIPC.NodeClient(channel: channel)
    let size: UInt64
    do throws(NodeIPC.NodeClient.Failure) { size = try client.stat(fields: NodeIPC.Fields.size).size } catch {
      throw .io(5)  // EIO
    }
    blockCount = size / UInt64(Layout.blockSize)
    let control: NodeIPC.NodeClient?
    switch consume ctl {
    case .some(let h): control = NodeIPC.NodeClient(channel: h)
    case .none: control = nil
    }
    partition = Partition(client, ctl: control)
  }

  /// The pieces of `count` blocks from `block`, at most a batch's worth
  /// each time `body` is called.
  func pieces(_ block: UInt64, count: Int, _ body: ([(offset: UInt64, length: Int)]) throws(TaisceError) -> Void)
    throws(TaisceError)
  {
    guard count >= 0, block <= blockCount, UInt64(count) <= blockCount - block else { throw .outOfRange }
    var offset = block * UInt64(blockSize)
    var left = count * blockSize
    var batch: [(offset: UInt64, length: Int)] = []
    while left > 0 {
      let n = Swift.min(left, NodeIPC.maxIO)
      batch.append((offset, n))
      offset += UInt64(n)
      left -= n
      if batch.count == NodeIPC.maxOps || left == 0 {
        try body(batch)
        batch = []
      }
    }
  }

  func run(_ ops: [NodeIPC.Op]) throws(TaisceError) -> [NodeIPC.Outcome] {
    do throws(NodeIPC.NodeClient.Failure) { return try partition.client.run(ops).results } catch { throw .io(5) }
  }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    if partition.ring != nil {
      guard count >= 0, block <= blockCount, UInt64(count) <= blockCount - block else { throw .outOfRange }
      let n = count * blockSize
      let bytes: [UInt8]
      do throws(NodeBulkChannel.Failure) { bytes = try partition.ring!.read(at: block * UInt64(blockSize), count: n) } catch {
        throw .io(5)
      }
      guard bytes.count == n else { throw .io(5) }
      return bytes
    }
    var out: [UInt8] = []
    out.reserveCapacity(count * blockSize)
    try pieces(block, count: count) { (batch) throws(TaisceError) in
      let results = try run(batch.map { .read(offset: $0.offset, max: UInt32($0.length)) })
      for (r, piece) in zip(results, batch) {
        guard case .data(let d) = r, d.count == piece.length else { throw .io(5) }
        out += d
      }
    }
    return out
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.count % blockSize == 0 else { throw .outOfRange }
    if partition.ring != nil {
      let count = bytes.count / blockSize
      guard block <= blockCount, UInt64(count) <= blockCount - block else { throw .outOfRange }
      let n: Int
      do throws(NodeBulkChannel.Failure) { n = try partition.ring!.write(at: block * UInt64(blockSize), bytes) } catch {
        throw .io(5)
      }
      guard n == bytes.count else { throw .io(5) }
      return
    }
    var at = 0
    try pieces(block, count: bytes.count / blockSize) { (batch) throws(TaisceError) in
      var ops: [NodeIPC.Op] = []
      for piece in batch {
        ops.append(.write(offset: piece.offset, data: Array(bytes[at..<(at + piece.length)])))
        at += piece.length
      }
      let results = try run(ops)
      for (r, piece) in zip(results, batch) {
        guard case .wrote(let n) = r, Int(n) == piece.length else { throw .io(5) }
      }
    }
  }

  /// The unit's `flush`: the writes before it, each answered already,
  /// made durable.
  public mutating func flush() throws(TaisceError) {
    do throws(NodeIPC.NodeClient.Failure) {
      _ = try partition.ctl?.write(offset: 0, Array("flush".utf8))
    } catch {
      throw .io(5)  // EIO
    }
  }
}
