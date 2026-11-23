// SPDX-License-Identifier: BSD-3-Clause

// A transport that runs no GPU, for the Mali backend's tests: buffers are
// host memory, a submit is recorded and its signals raised at once, so the
// backend's own logic (addresses, plans, the streams it lays out, the order
// of its calls) is checked where the GPU isn't.

import GPUCore
import GPUCoreMali

// Shared by the Mali backend's tests (graphics/core/mali/tests) and the Vulkan layer's (graphics/vulkan/layer-tests).

public final class FakeBuffer: MaliBuffer {
  public let size: Int
  public let pointer: UnsafeMutableRawPointer
  public let cpuCached: Bool
  /// How many times the CPU's cache was cleaned and invalidated over the buffer.
  public var maintenance = 0
  public func cleanInvalidate() { maintenance += 1 }
  /// How many handles were exported.
  public var exports = 0
  public func exportVMO() -> UInt32? {
    exports += 1
    return UInt32(1000 + exports)
  }
  /// How many mappable handles were exported (a window's image, memory).
  public var mappableExports = 0
  public func exportMappableVMO() -> UInt32? {
    mappableExports += 1
    return UInt32(2000 + mappableExports)
  }
  public init(size: Int, cpuCached: Bool = false) {
    self.cpuCached = cpuCached
    self.size = size
    pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
  }
  deinit { pointer.deallocate() }
  public func store(_ value: UInt64, at offset: Int) { pointer.storeBytes(of: value, toByteOffset: offset, as: UInt64.self) }
}

public final class FakeTransport: MaliTransport {
  public init() {}
  public var info = MaliGPUInfo(
    gpuID: 0xC000_0000, workRegisters: 96, unpreservedRegisters: 16, scoreboards: 8, shaderPresent: 0xFFF, maxThreads: 2048,
    maxWorkgroupSize: 1024, threadFeatures: 0x0801_0000, name: "fake mali")
  public var nextID: UInt32 = 1
  public var userRange: UInt64 = 0
  public var bound: [(address: UInt64, buffer: FakeBuffer)] = []
  public var groups: [UInt32: [UInt32]] = [:]
  public var syncs: [UInt32: UInt64] = [:]
  public var submits: [(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)], signals: [(sync: UInt32, value: UInt64)])] = []
  public var created = 0
  public var destroyed = 0
  public var failSubmit = false
  /// At each submit: the words of each job's stream, and of every bound buffer (the work is "done" at once, and its memory let go).
  public var streams: [[UInt64]] = []
  public var memory: [[UInt32]] = []
  /// The regions the VM mapped at the last submit.
  public var boundAtSubmit: [(address: UInt64, size: Int)] = []

  public func createVM() throws(GPUError) -> (id: UInt32, userRange: UInt64) { (nextID, userRange) }
  public func destroyVM(_ vm: UInt32) {}

  public func createBuffer(size: Int, cpuCached: Bool) throws(GPUError) -> any MaliBuffer {
    created += 1
    return FakeBuffer(size: size, cpuCached: cpuCached)
  }

  public func destroyBuffer(_ buffer: any MaliBuffer) { destroyed += 1 }

  /// The addresses bound cacheable for the GPU.
  public var cacheableBound: [UInt64] = []
  public func bind(vm: UInt32, buffer: any MaliBuffer, address: UInt64, gpuCacheable: Bool) throws(GPUError) {
    bound.append((address, buffer as! FakeBuffer))
    if gpuCacheable { cacheableBound.append(address) }
  }

  public func unbind(vm: UInt32, address: UInt64, size: Int) { bound.removeAll { $0.address == address } }

  public func createGroup(vm: UInt32, ringSizes: [UInt32]) throws(GPUError) -> UInt32 {
    nextID += 1
    groups[nextID] = ringSizes
    return nextID
  }

  public func destroyGroup(_ group: UInt32) { groups[group] = nil }
  /// What every group reports as its state (0: running; a fatal fault sets bit 1).
  public var groupFault: UInt32 = 0
  public func groupState(_ group: UInt32) -> UInt32 { groups[group] == nil ? 0 : groupFault }

  public func createSync() throws(GPUError) -> UInt32 {
    nextID += 1
    syncs[nextID] = 0
    return nextID
  }

  public func destroySync(_ sync: UInt32) { syncs[sync] = nil }
  public func readSync(_ sync: UInt32) -> UInt64 { syncs[sync] ?? 0 }
  public func raiseSync(_ sync: UInt32, to value: UInt64) { if (syncs[sync] ?? 0) < value { syncs[sync] = value } }
  public func wait(sync: UInt32, value: UInt64, timeoutNanoseconds: UInt64) -> Bool { (syncs[sync] ?? 0) >= value }
  /// A sync's handle: its id plus 7000, for a test to see which sync it names.
  public func syncHandle(_ sync: UInt32) -> UInt32? { syncs[sync] == nil ? nil : 7000 + sync }

  public func submit(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)],
              signals: [(sync: UInt32, value: UInt64)]) throws(GPUError) {
    if failSubmit { throw .failed("submit", code: -1) }
    submits.append((group, jobs, waits, signals))
    boundAtSubmit = bound.map { (address: $0.address, size: $0.buffer.size) }
    for j in jobs { if let s = stream(of: j) { streams.append(s); storeTimestamps(s) } }
    for (_, b) in bound { memory.append((0..<b.size / 4).map { b.pointer.load(fromByteOffset: $0 * 4, as: UInt32.self) }) }
    for s in signals { raiseSync(s.sync, to: s.value) }
  }

  /// The clock the device calibrates timestamps against, and the frequency the fake GPU's timestamp counter runs at.
  /// A call of `nanoseconds` takes 10 us of it, a pause what it is asked for.
  public var clock: UInt64 = 1_000_000_000
  public var timerHertz: UInt64 = 1_000_000_000
  public func nanoseconds() -> UInt64 {
    clock += 10_000
    return clock
  }
  public func pause(nanoseconds: UInt64) { clock += nanoseconds }
  /// What the CPU's counter register reads: nil is the fake GPU's own frequency (the platform where the two agree), 0 is a
  /// CPU that can't say.
  public var cpuCounterHertz: UInt64?
  public func counterFrequency() -> UInt64 { cpuCounterHertz ?? timerHertz }
  /// The timestamps of the fake GPU's counter the streams stored.
  public var timestampsStored: [UInt64] = []

  /// What the GPU does for STORE_STATE of the timestamp (opcode 40, state 0): MOVE48 and MOVE32 are followed to know the
  /// address register, and the counter's value is stored there.
  func storeTimestamps(_ words: [UInt64]) {
    var registers = [UInt64](repeating: 0, count: 256)
    for w in words {
      let op = w >> 56
      if op == 1 {
        registers[Int(w >> 48 & 0xFF)] = w & 0xFFFF_FFFF_FFFF
      } else if op == 2 {
        registers[Int(w >> 48 & 0xFF) + 1] = w & 0xFFFF_FFFF
      } else if op == 40, w >> 32 & 0xFF == 0 {
        let address = registers[Int(w >> 40 & 0xFF)] &+ UInt64(UInt16(truncatingIfNeeded: w))
        let ticks = clock / 1000 * (timerHertz / 1_000_000)
        timestampsStored.append(ticks)
        clock += 1000  // the counter moves on
        for (base, buffer) in bound where address >= base && address + 8 <= base + UInt64(buffer.size) {
          buffer.pointer.storeBytes(of: ticks, toByteOffset: Int(address - base), as: UInt64.self)
        }
      }
    }
  }

  /// The words of the stream a job names, read from the buffer it is in.
  public func stream(of job: MaliJob) -> [UInt64]? {
    for (address, buffer) in bound where job.address >= address && job.address + UInt64(job.size) <= address + UInt64(buffer.size) {
      let offset = Int(job.address - address)
      return (0..<Int(job.size) / 8).map { buffer.pointer.load(fromByteOffset: offset + $0 * 8, as: UInt64.self) }
    }
    return nil
  }
}
