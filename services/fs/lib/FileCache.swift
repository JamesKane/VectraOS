// SPDX-License-Identifier: BSD-3-Clause

// A client's mapped files (M3l): a file's data mapped read-only from the
// fs service (File.map, Mapped.swift), and a cache of them by path, so
// opening and reading a file that was read before is a copy from memory.
// An entry is used for as long as its header says it holds: the service
// marks it gone when the file is unlinked or anything is renamed, and
// replaced when it outgrows its VMO, and the cache then looks the path up
// again. Files fs won't map (directories, files over 64 MiB) are read
// through Node.
//
//     let files = FileCache(namespace)
//     let bytes = try files.read("/data/notes.txt", count: 4096)

import IPC
import Node

/// One file's mapped data.
public final class MappedData: @unchecked Sendable {
  let mapping: Mapping
  let header: MappedHeader

  public init(vmo: consuming Handle) throws(Status) {
    let size = try VMO.size(vmo)
    let mapping = try VMO.map(vmo, length: size, writable: false)
    header = unsafe MappedHeader(unsafe: mapping.address)
    self.mapping = mapping
    guard header.magic == MappedFile.magic else { throw .wrongType }
  }

  /// Up to `count` bytes from `offset`; nil once the mapping no longer
  /// holds (look the file up again).
  public func read(offset: UInt64 = 0, count: Int) -> [UInt8]? { header.read(offset: offset, count: count) }

  public var size: UInt64 { header.size }
  public var isCurrent: Bool { header.flags == 0 }
}

extension FsIPC.FileClient {
  /// The file's data, mapped.
  public mutating func mapped() throws(IPCError<FsIPC.FsError>) -> MappedData {
    let vmo = try map()
    do throws(Status) { return try MappedData(vmo: vmo) } catch { throw .transport(error) }
  }
}

/// Mapped files by path, through a namespace.
public final class FileCache: @unchecked Sendable {
  public enum Failure: Error, Equatable, Sendable {
    case namespace(NamespaceError)
    case fs(FsIPC.FsError)
    case transport(Status)
  }

  let namespace: Namespace
  let lock = Lock()
  /// By path, ascending.
  var entries: [(path: String, data: MappedData)] = []
  public private(set) var hits = 0
  public private(set) var misses = 0

  /// Keeps at most `capacity` files mapped.
  public let capacity: Int

  public init(_ namespace: Namespace, capacity: Int = 256) {
    self.namespace = namespace
    self.capacity = capacity
  }

  public var count: Int { lock.withLock { entries.count } }

  func index(_ path: String) -> (found: Bool, at: Int) {
    var lo = 0, hi = entries.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if entries[mid].path.utf8.lexicographicallyPrecedes(path.utf8) { lo = mid + 1 } else { hi = mid }
    }
    return (lo < entries.count && entries[lo].path.utf8.elementsEqual(path.utf8), lo)
  }

  /// Up to `count` bytes of the file at `path` from `offset`.
  public func read(_ path: String, offset: UInt64 = 0, count: Int) throws(Failure) -> [UInt8] {
    for _ in 0..<3 {
      let data = try lock.withLock { () throws(Failure) -> MappedData in
        let (found, at) = index(path)
        if found {
          hits += 1
          return entries[at].data
        }
        misses += 1
        let data = try open(path)
        if entries.count >= capacity { entries.removeFirst() }
        let (_, slot) = index(path)
        entries.insert((path, data), at: slot)
        return data
      }
      if let bytes = data.read(offset: offset, count: count) { return bytes }
      lock.withLock {
        let (found, at) = index(path)
        if found, entries[at].data === data { entries.remove(at: at) }
      }
    }
    throw .fs(.io)
  }

  /// The whole file at `path`.
  public func readAll(_ path: String) throws(Failure) -> [UInt8] {
    try read(path, count: MappedFile.largest)
  }

  /// Forgets every mapping (after the namespace's mounts change).
  public func clear() { lock.withLock { entries.removeAll() } }

  func open(_ path: String) throws(Failure) -> MappedData {
    let channel: Handle
    do throws(NamespaceError) { channel = try namespace.connect(path) } catch { throw .namespace(error) }
    var file = FsIPC.FileClient(channel: channel)
    do throws(IPCError<FsIPC.FsError>) {
      return try file.mapped()
    } catch {
      switch error {
      case .remote(let e): throw .fs(e)
      case .transport(let s): throw .transport(s)
      case .wire: throw .transport(.internal)
      }
    }
  }
}
