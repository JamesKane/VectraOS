// SPDX-License-Identifier: BSD-3-Clause

// Conveniences for fs clients: paths, files made and opened, whole reads
// and writes, and typed attribute values.
//
//     var data = FsIPC.DirectoryClient(channel: try namespace.connect("/data"))
//     var song = try data.makeFile("song.flac")
//     try song.write(bytes)
//     try song.setAttribute(.int64("Audio:Year", 1993))

import IPC
import Node

extension FsIPC.DirectoryClient {
  public typealias NodeFailure = NodeIPC.NodeClient.Failure

  /// A channel to the node at `path` below this directory.
  public mutating func walk(to path: String) throws(NodeFailure) -> Handle {
    try node { (c: inout NodeIPC.NodeClient) throws(NodeFailure) in try c.open(path).takeChannel() }
  }

  public mutating func directory(_ path: String) throws(NodeFailure) -> FsIPC.DirectoryClient {
    FsIPC.DirectoryClient(channel: try walk(to: path))
  }

  public mutating func file(_ path: String) throws(NodeFailure) -> FsIPC.FileClient {
    FsIPC.FileClient(channel: try walk(to: path))
  }

  /// A new, empty file `name` here.
  public mutating func makeFile(_ name: String) throws(NodeFailure) -> FsIPC.FileClient {
    FsIPC.FileClient(channel: try make(name, .file))
  }

  /// A new, empty directory `name` here.
  public mutating func makeDirectory(_ name: String) throws(NodeFailure) -> FsIPC.DirectoryClient {
    FsIPC.DirectoryClient(channel: try make(name, .directory))
  }

  mutating func make(_ name: String, _ kind: NodeIPC.NodeKind) throws(NodeFailure) -> Handle {
    try node { (c: inout NodeIPC.NodeClient) throws(NodeFailure) in try c.create(name, kind: kind).takeChannel() }
  }

  /// Every entry, with the attributes named.
  public mutating func listAll(attributes: [String] = []) throws(IPCError<FsIPC.FsError>) -> [FsIPC.Entry] {
    var out: [FsIPC.Entry] = []
    var cursor: UInt64 = 0
    while true {
      let batch = try list(cursor: cursor, max: 256, attributes: attributes)
      out += batch.entries
      if batch.done { return out }
      cursor = batch.next
    }
  }
}

extension FsIPC.FileClient {
  public typealias NodeFailure = NodeIPC.NodeClient.Failure

  /// The whole file.
  public mutating func readAll() throws(NodeFailure) -> [UInt8] {
    try node { (c: inout NodeIPC.NodeClient) throws(NodeFailure) in try c.readAll() }
  }

  /// Writes `bytes` from `offset`, in Node-sized pieces.
  public mutating func write(_ bytes: [UInt8], at offset: UInt64 = 0) throws(NodeFailure) {
    try node { (c: inout NodeIPC.NodeClient) throws(NodeFailure) in
      var done = 0
      repeat {
        let piece = Array(bytes[done..<Swift.min(bytes.count, done + NodeIPC.maxIO)])
        done += Int(try c.write(offset: offset + UInt64(done), piece))
      } while done < bytes.count
    }
  }
}

extension FsIPC.Attribute {
  public static func int64(_ name: String, _ value: Int64) -> FsIPC.Attribute {
    FsIPC.Attribute(name: name, kind: 2, value: withUnsafeBytes(of: value.littleEndian) { unsafe Array($0) })
  }

  public static func string(_ name: String, _ value: String) -> FsIPC.Attribute {
    FsIPC.Attribute(name: name, kind: 1, value: Array(value.utf8))
  }

  public var int64Value: Int64? {
    guard kind == 2, value.count == 8 else { return nil }
    return Int64(bitPattern: value.reversed().reduce(0) { $0 << 8 | UInt64($1) })
  }

  public var stringValue: String? { kind == 1 ? String(decoding: value, as: UTF8.self) : nil }
}
