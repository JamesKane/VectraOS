// SPDX-License-Identifier: BSD-3-Clause

// The memory a submission lays out and lets go of when it is done (gpucore(2), "The Mali backend"): the steps' blocks,
// their streams, a transfer's parameters, the frame shaders' heaps, thread and workgroup storage. A buffer made and bound
// for each would be two calls to the driver to make and two to let go, for every step of every frame; instead they are
// carved out of a few large chunks, made once, bound once in one 4 GiB window (a render pass's blend shaders are called by
// 32-bit addresses), and used again once the timeline has passed every submission that used them.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

/// Part of a chunk of the arena, as a buffer: the chunk's mapping from `offset`, `size` bytes.
final class ArenaSlice: MaliBuffer {
  let chunk: any MaliBuffer
  let offset: Int
  let size: Int
  init(_ chunk: any MaliBuffer, offset: Int, size: Int) {
    self.chunk = chunk
    self.offset = offset
    self.size = size
  }
  var pointer: UnsafeMutableRawPointer { unsafe chunk.pointer.advanced(by: offset) }
  func store(_ value: UInt64, at offset: Int) { chunk.store(value, at: self.offset + offset) }
  var cpuCached: Bool { false }
  func cleanInvalidate() {}
  func exportVMO() -> UInt32? { nil }
}

/// The arena's chunks: each is used from its start, and starts again once the submissions that used it are done.
struct TransientArena {
  struct Chunk {
    let region: Region
    var used = 0
    /// The timeline value of the last submission that took memory from it.
    var lastUse: UInt64 = 0
  }
  var chunks: [Chunk] = []
  var current = -1
  /// A chunk's size; a larger request gets a chunk of its own size, which is kept and used again like the others.
  static let chunkBytes = 4 << 20
  /// More than this many idle chunks are let go of.
  static let keptChunks = 4
}

extension MaliDevice {
  /// `bytes` of memory for the submission being made (its timeline value `signal`), write-combining and inside one 4 GiB
  /// window, aligned to 4 KiB: held until the timeline passes `signal`, with no call to the driver unless the arena grows.
  func transient(_ bytes: Int, alignment: Int = 4096) throws(GPUError) -> Region {
    let size = max((bytes + 63) & ~63, 64)
    let value = rule.lastSignalled
    func carve(_ i: Int) -> Region {
      let at = (arena.chunks[i].used + alignment - 1) & ~(alignment - 1)
      arena.chunks[i].used = at + size
      arena.chunks[i].lastUse = value
      let c = arena.chunks[i].region
      return Region(buffer: ArenaSlice(c.buffer, offset: at, size: size), address: c.address + UInt64(at), size: size, transient: true)
    }
    func fits(_ i: Int) -> Bool {
      ((arena.chunks[i].used + alignment - 1) & ~(alignment - 1)) + size <= arena.chunks[i].region.size
    }
    if arena.current >= 0 && fits(arena.current) { return carve(arena.current) }
    // A chunk no submission still running uses starts again.
    let done = completed
    for i in 0..<arena.chunks.count where i != arena.current && arena.chunks[i].lastUse <= done {
      arena.chunks[i].used = 0
      if fits(i) {
        arena.current = i
        return carve(i)
      }
    }
    let region = try makeRegion(max(size + alignment, TransientArena.chunkBytes), window: true)
    arena.chunks.append(TransientArena.Chunk(region: region))
    arena.current = arena.chunks.count - 1
    // Idle chunks past the few kept are let go of.
    var idle = 0
    var i = 0
    while i < arena.chunks.count {
      if i != arena.current && arena.chunks[i].lastUse <= done {
        idle += 1
        if idle > TransientArena.keptChunks {
          release([arena.chunks[i].region])
          arena.chunks.remove(at: i)
          if arena.current > i { arena.current -= 1 }
          continue
        }
      }
      i += 1
    }
    return carve(arena.current)
  }

  /// Memory for the submission being made: the arena's, or a buffer of its own held until the submission is done where it is
  /// more than half a chunk.
  func scratch(_ bytes: Int, held: inout [Region]) throws(GPUError) -> Region {
    if bytes <= TransientArena.chunkBytes / 2 { return try transient(bytes) }
    let r = try makeRegion(bytes, window: true)
    held.append(r)
    return r
  }

  /// Thread storage (stacks and spills) or workgroup memory for a step: one region of each kind for the device, as large as
  /// the largest step has needed, since no two steps ever run at once (each waits for the one before it on the GPU). A
  /// step that needs more makes it again; the old one goes once the work submitted before is done.
  func stepStorage(_ bytes: Int, workgroup: Bool, held: inout [Region]) throws(GPUError) -> UInt64 {
    if let r = workgroup ? workgroupStorage : threadStorage, r.size >= bytes { return r.address }
    let r = try makeRegion(bytes, window: true)
    if let old = workgroup ? workgroupStorage : threadStorage { held.append(old) }
    if workgroup { workgroupStorage = r } else { threadStorage = r }
    return r.address
  }

  /// Gives back the end of the latest piece the arena carved, past `used` of its bytes, when it is still the chunk's last.
  func trimTransient(_ region: Region, used: Int) {
    guard region.transient, arena.current >= 0 else { return }
    let c = arena.chunks[arena.current]
    guard region.address >= c.region.address, region.address + UInt64(region.size) == c.region.address + UInt64(c.used) else { return }
    arena.chunks[arena.current].used = Int(region.address - c.region.address) + min(max((used + 63) & ~63, 64), region.size)
  }

  /// Copies a recipe's bytes into a region at once.
  func put(_ image: MemoryImage, into region: Region) {
    let n = min(image.count, region.size)
    guard n > 0 else { return }
    let to = unsafe region.buffer.pointer
    unsafe image.bytes.withUnsafeBytes { src in
      unsafe to.copyMemory(from: src.baseAddress!, byteCount: n)
    }
  }
}
