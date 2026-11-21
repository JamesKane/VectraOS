// SPDX-License-Identifier: BSD-3-Clause

// A transport that runs no GPU, for the Mali backend's tests: buffers are
// host memory, a submit is recorded and its signals raised at once, so the
// backend's own logic (addresses, plans, the streams it lays out, the order
// of its calls) is checked where the GPU isn't.

import GPUCore
import GPUCoreMali

final class FakeBuffer: MaliBuffer {
  let size: Int
  let pointer: UnsafeMutableRawPointer
  init(size: Int) {
    self.size = size
    pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
  }
  deinit { pointer.deallocate() }
  func store(_ value: UInt64, at offset: Int) { pointer.storeBytes(of: value, toByteOffset: offset, as: UInt64.self) }
}

final class FakeTransport: MaliTransport {
  var info = MaliGPUInfo(
    gpuID: 0xC000_0000, workRegisters: 96, unpreservedRegisters: 16, scoreboards: 8, shaderPresent: 0xFFF, maxThreads: 2048,
    maxWorkgroupSize: 1024, threadFeatures: 0x0801_0000, name: "fake mali")
  var nextID: UInt32 = 1
  var userRange: UInt64 = 0
  var bound: [(address: UInt64, buffer: FakeBuffer)] = []
  var groups: [UInt32: [UInt32]] = [:]
  var syncs: [UInt32: UInt64] = [:]
  var submits: [(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)], signals: [(sync: UInt32, value: UInt64)])] = []
  var created = 0
  var destroyed = 0
  var failSubmit = false
  /// At each submit: the words of each job's stream, and of every bound buffer (the work is "done" at once, and its memory let go).
  var streams: [[UInt64]] = []
  var memory: [[UInt32]] = []

  func createVM() throws(GPUError) -> (id: UInt32, userRange: UInt64) { (nextID, userRange) }
  func destroyVM(_ vm: UInt32) {}

  func createBuffer(size: Int) throws(GPUError) -> any MaliBuffer {
    created += 1
    return FakeBuffer(size: size)
  }

  func destroyBuffer(_ buffer: any MaliBuffer) { destroyed += 1 }

  func bind(vm: UInt32, buffer: any MaliBuffer, address: UInt64) throws(GPUError) {
    bound.append((address, buffer as! FakeBuffer))
  }

  func unbind(vm: UInt32, address: UInt64, size: Int) { bound.removeAll { $0.address == address } }

  func createGroup(vm: UInt32, ringSizes: [UInt32]) throws(GPUError) -> UInt32 {
    nextID += 1
    groups[nextID] = ringSizes
    return nextID
  }

  func destroyGroup(_ group: UInt32) { groups[group] = nil }
  func groupState(_ group: UInt32) -> UInt32 { 0 }

  func createSync() throws(GPUError) -> UInt32 {
    nextID += 1
    syncs[nextID] = 0
    return nextID
  }

  func destroySync(_ sync: UInt32) { syncs[sync] = nil }
  func readSync(_ sync: UInt32) -> UInt64 { syncs[sync] ?? 0 }
  func raiseSync(_ sync: UInt32, to value: UInt64) { if (syncs[sync] ?? 0) < value { syncs[sync] = value } }
  func wait(sync: UInt32, value: UInt64, timeoutNanoseconds: UInt64) -> Bool { (syncs[sync] ?? 0) >= value }

  func submit(group: UInt32, jobs: [MaliJob], waits: [(sync: UInt32, value: UInt64)],
              signals: [(sync: UInt32, value: UInt64)]) throws(GPUError) {
    if failSubmit { throw .failed("submit", code: -1) }
    submits.append((group, jobs, waits, signals))
    for j in jobs { if let s = stream(of: j) { streams.append(s) } }
    for (_, b) in bound { memory.append((0..<b.size / 4).map { b.pointer.load(fromByteOffset: $0 * 4, as: UInt32.self) }) }
    for s in signals { raiseSync(s.sync, to: s.value) }
  }

  /// The words of the stream a job names, read from the buffer it is in.
  func stream(of job: MaliJob) -> [UInt64]? {
    for (address, buffer) in bound where job.address >= address && job.address + UInt64(job.size) <= address + UInt64(buffer.size) {
      let offset = Int(job.address - address)
      return (0..<Int(job.size) / 8).map { buffer.pointer.load(fromByteOffset: offset + $0 * 8, as: UInt64.self) }
    }
    return nil
  }
}
