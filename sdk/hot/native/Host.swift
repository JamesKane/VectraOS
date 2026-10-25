// SPDX-License-Identifier: BSD-3-Clause

// Hot reload's host (hotreload(2), D122): the state block, mapped at the
// same address in every run, and the image, a file the host watches. At a
// frame's end the host looks at the file (at most every 50 ms); if it has
// changed it loads a fresh copy (system/ld's, made runnable with the
// program's VMEX resource, its manifest's `reload`), and calls the new copy
// from the next frame on. An image whose state hash isn't the block's is
// refused, unless it exports `hot_migrate`, which is given the block and
// the hash it holds. Old copies stay loaded.

import CroiRuntime
import Ld
import Node
import Sys

@safe public struct HotHost {
  public enum Failure: Error {
    case noVmex
    case block(Status)
    case image(String)
  }

  /// The state block's address, the same in every run: 128 GiB, above
  /// what the loader and the heap use.
  public static let address: UInt = 0x20_0000_0000
  /// The root VMAR's base (the kernel's UserLayout).
  static let rootBase: UInt = 0x20_0000
  public static let blockSize = 1 << 20

  public let block: UnsafeMutableRawPointer
  let namespace: Namespace
  let directory: String, name: String
  let vmex: UInt32
  /// The file as last seen, and when it was looked at.
  var seen: NodeIPC.Stat?
  var looked: Int64 = 0
  /// The copy running: its `hot_frame`, and how many were loaded.
  var frameFunction: UInt = 0
  public private(set) var loads = 0
  /// The last load's time, file seen changed to new code running (ns).
  public private(set) var lastLoad: Int64 = 0
  /// Why the last image was refused, if it was.
  public private(set) var refused: String?

  typealias Size = @convention(c) () -> Int
  typealias Hash = @convention(c) () -> UInt64
  typealias Frame = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
  typealias Migrate = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Bool

  /// A host for the image at `path` in `namespace`, its state block mapped
  /// (zeroed the first time), and the image loaded.
  public init(image path: String, namespace: Namespace) throws(Failure) {
    guard let vmex = Startup.current.take(HandleType.info(HandleType.resource(.system), 3))?.release() else { throw .noVmex }
    self.vmex = vmex
    self.namespace = namespace
    let bytes = Array(path.utf8)
    let slash = bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1
    directory = slash > 0 ? String(decoding: bytes[..<slash], as: UTF8.self) : "/"
    name = String(decoding: bytes[(slash + 1)...], as: UTF8.self)
    do throws(Status) {
      let vmo = try VMO.create(size: Self.blockSize)
      let mapped = unsafe try Self.map(vmo)
      unsafe block = mapped
    } catch {
      throw .block(error)
    }
    guard let stat = Self.stat(namespace, directory, name) else { throw .image("\(path): not found") }
    try load(stat)
  }

  static func map(_ vmo: borrowing Handle) throws(Status) -> UnsafeMutableRawPointer {
    var at: UInt64 = 0
    let r = unsafe croi_vmar_map(td_runtime_vmar_root,
                                 UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE | CROI_VM_SPECIFIC),
                                 UInt64(address - rootBase), vmo.raw, 0, UInt64(blockSize), &at)
    guard r == 0 else { throw Status(rawValue: Int32(truncatingIfNeeded: r)) ?? .noMemory }
    return unsafe UnsafeMutableRawPointer(bitPattern: UInt(at))!
  }

  static func stat(_ ns: Namespace, _ directory: String, _ name: String) -> NodeIPC.Stat? {
    guard var dir = try? ns.open(directory) else { return nil }
    return try? dir.stat(name)
  }

  /// The image `stat` describes, loaded: its state checked against the
  /// block, or migrated; then it runs from the next frame.
  mutating func load(_ stat: NodeIPC.Stat) throws(Failure) {
    seen = stat
    let path = directory + "/" + name
    let memory: NodeIPC.Memory
    do throws(NamespaceError) { memory = try namespace.memory(path, executable: false) } catch {
      throw .image("\(path): can't be read")
    }
    guard let index = DynamicLinker.openFresh(memory.vmo.raw, size: memory.size, name: name, vmex: vmex) else {
      throw .image(DynamicLinker.takeFailure() ?? "\(name): can't be loaded")
    }
    _ = consume memory
    guard let size = DynamicLinker.symbol("hot_state_size", in: index),
      let hash = DynamicLinker.symbol("hot_state_hash", in: index),
      let frame = DynamicLinker.symbol("hot_frame", in: index)
    else { throw .image("\(name): exports no hot_state_size, hot_state_hash or hot_frame") }
    let need = unsafe unsafeBitCast(size, to: Size.self)()
    let newHash = unsafe unsafeBitCast(hash, to: Hash.self)()
    guard need + 16 <= Self.blockSize else { throw .image("\(name): its state, \(need) bytes, is too big") }
    // The block's header: the hash its state has, then the state.
    let header = unsafe block.assumingMemoryBound(to: UInt64.self)
    let held = unsafe header[0]
    if held != 0 && held != newHash {
      guard let migrate = DynamicLinker.symbol("hot_migrate", in: index),
        unsafe unsafeBitCast(migrate, to: Migrate.self)(block + 16, held)
      else {
        throw .image("\(name): its state's layout isn't the block's, and it has no hot_migrate that takes it")
      }
    }
    unsafe header[0] = newHash
    frameFunction = frame
    loads += 1
  }

  /// Runs a frame in the image; then, if the file has changed, loads it
  /// (refused, the old copy runs on). The image's result.
  public mutating func frame(_ f: inout HotFrame, now: Int64) -> Int32 {
    let result = withUnsafeMutablePointer(to: &f) { p in
      unsafe unsafeBitCast(frameFunction, to: Frame.self)(block + 16, UnsafeMutableRawPointer(p))
    }
    if now - looked >= 50_000_000 {
      looked = now
      if let s = Self.stat(namespace, directory, name), !Self.same(s, seen) {
        let started = Clock.monotonic()
        do throws(Failure) {
          try load(s)
          lastLoad = Clock.monotonic() - started
          refused = nil
        } catch {
          refused = Self.describe(error)
        }
      }
    }
    return result
  }

  /// The same file, unchanged: its qid, size and time (not its name: a
  /// String's == needs Unicode tables tier 0 hasn't).
  static func same(_ a: NodeIPC.Stat, _ b: NodeIPC.Stat?) -> Bool {
    guard let b else { return false }
    return a.qid == b.qid && a.size == b.size && a.modified == b.modified
  }

  public static func describe(_ e: Failure) -> String {
    switch e {
    case .noVmex: "no VMEX resource (the manifest's `reload`)"
    case .block(let s): "no state block at its address (\(s.rawValue))"
    case .image(let why): why
    }
  }
}
