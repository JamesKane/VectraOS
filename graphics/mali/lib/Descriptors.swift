// SPDX-License-Identifier: BSD-3-Clause

// The records a compute dispatch points the GPU at (chinese-wall's valhall
// 03 sections 3.2, 3.4 and 3.10, and 04): resource table entries, the buffer
// descriptor, the SRT and FAU register values, the shader program descriptor
// and the local storage ("thread storage") descriptor, with 04 section 4.7's
// sizing rules. Each is a value that encodes itself into little-endian words;
// where it lives is the dispatch recipe's.

/// A little-endian image of GPU memory: the records are stored into it at offsets.
public struct MemoryImage: Equatable, Sendable {
  public private(set) var bytes: [UInt8]
  public init(size: Int = 0) { bytes = [UInt8](repeating: 0, count: size) }
  public var count: Int { bytes.count }
  /// Grow to `size` bytes (zero filled).
  public mutating func extend(to size: Int) {
    if size > bytes.count { bytes.append(contentsOf: [UInt8](repeating: 0, count: size - bytes.count)) }
  }
  public mutating func store(_ value: UInt32, at offset: Int) {
    for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32(8 * i)) }
  }
  public mutating func store(_ value: UInt64, at offset: Int) {
    for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * i)) }
  }
  public mutating func store(words: [UInt32], at offset: Int) {
    for (i, w) in words.enumerated() { store(w, at: offset + 4 * i) }
  }
  public mutating func store(words: [UInt64], at offset: Int) {
    for (i, w) in words.enumerated() { store(w, at: offset + 8 * i) }
  }
  public mutating func store(bytes b: [UInt8], at offset: Int) {
    for (i, v) in b.enumerated() { bytes[offset + i] = v }
  }
  public func load32(at offset: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v |= UInt32(bytes[offset + i]) << UInt32(8 * i) }
    return v
  }
  public func load64(at offset: Int) -> UInt64 {
    UInt64(load32(at: offset)) | UInt64(load32(at: offset + 4)) << 32
  }
}

@inline(__always) func alignUp(_ v: Int, _ a: Int) -> Int { (v + a - 1) & ~(a - 1) }
@inline(__always) func isPowerOfTwo(_ v: UInt64) -> Bool { v != 0 && v & (v - 1) == 0 }
func nextPowerOfTwo(_ v: UInt64) -> UInt64 {
  if v <= 1 { return 1 }
  var p: UInt64 = 1
  while p < v { p <<= 1 }
  return p
}
func log2Floor(_ v: UInt64) -> Int { 63 - v.leadingZeroBitCount }
func log2Ceil(_ v: UInt64) -> Int { v <= 1 ? 0 : 64 - (v - 1).leadingZeroBitCount }

public enum DescriptorError: Error, Equatable, Sendable {
  case misaligned
  case outOfRange
}

// MARK: Resource table (03 section 3.2)

/// One 16-byte entry: table n's address, whether it holds 32-byte descriptors, and its size in bytes.
public struct ResourceTableEntry: Equatable, Sendable {
  public var address: UInt64
  public var containsDescriptors: Bool
  public var size: UInt64
  public init(address: UInt64, containsDescriptors: Bool, size: UInt64) {
    self.address = address
    self.containsDescriptors = containsDescriptors
    self.size = size
  }
  /// An entry that exists and is unused.
  public static let unused = ResourceTableEntry(address: 0, containsDescriptors: false, size: 0)

  /// Words 0 and 1: the 56-bit address in w0 and w1[23:0], the flag in w1[24]; words 2 and 3: the size.
  public var words: [UInt32] {
    [
      UInt32(truncatingIfNeeded: address),
      UInt32(truncatingIfNeeded: address >> 32) & 0x00FF_FFFF | (containsDescriptors ? 1 << 24 : 0),
      UInt32(truncatingIfNeeded: size), UInt32(truncatingIfNeeded: size >> 32),
    ]
  }
}

public enum ResourceTable {
  public static let entrySize = 16
  public static let alignment = 64
  public static let maxEntries = 60

  /// The table as bytes: the entries, then unused ones to the next multiple of 4 (a table with one
  /// used entry still has four). An empty list gives no table.
  public static func encode(_ entries: [ResourceTableEntry]) throws(DescriptorError) -> [UInt8] {
    guard entries.count <= maxEntries else { throw .outOfRange }
    if entries.isEmpty { return [] }
    let n = alignUp(entries.count, 4)
    var image = MemoryImage(size: n * entrySize)
    for (i, e) in entries.enumerated() { image.store(words: e.words, at: i * entrySize) }
    return image.bytes
  }

  /// The SRT staging register: the table's address with its entry count (a multiple of 4, at most 60,
  /// as the table `encode` writes) in bits [5:0]. 0 for no table.
  public static func pointer(address: UInt64, entryCount: Int) throws(DescriptorError) -> UInt64 {
    if entryCount == 0 { return 0 }
    guard entryCount <= maxEntries, entryCount & 3 == 0 else { throw .outOfRange }
    guard address & 63 == 0, address < 1 << 56 else { throw .misaligned }
    return address | UInt64(entryCount)
  }

  /// A shader's handle: the table number in [31:24], the descriptor's index in [23:0] (03 section 3.2.2).
  public static func handle(table: Int, index: Int) -> UInt32 {
    UInt32(table & 0x3F) << 24 | UInt32(index & 0xFF_FFFF)
  }
}

// MARK: Buffer descriptor (03 section 3.4)

public struct BufferDescriptor: Equatable, Sendable {
  public enum Kind: UInt32, Sendable {
    case simple = 1
    case tilerHeap = 2
    case structure = 3
    case vertexPacket = 4
  }
  public static let size = 32
  public static let typeTag: UInt32 = 9

  public var kind: Kind
  public var address: UInt64
  /// Bytes; arch 11 and later keep the high half in word 5.
  public var byteSize: UInt64
  /// Structure type: the element size in bytes.
  public var stride: UInt32
  /// Texel buffers: the conversion word (word 7, 03 section 3.5): the view format's 22-bit pixel format word. Not read by the hardware.
  public var conversion: UInt32 = 0

  public init(kind: Kind = .simple, address: UInt64, byteSize: UInt64, stride: UInt32 = 0) {
    self.kind = kind
    self.address = address
    self.byteSize = byteSize
    self.stride = stride
  }

  /// A uniform buffer's size is rounded up to 16 bytes, a storage buffer's to 4 (03 section 3.2.4).
  public static func uniform(address: UInt64, byteSize: UInt64) -> BufferDescriptor {
    BufferDescriptor(address: address, byteSize: (byteSize + 15) & ~15)
  }
  public static func storage(address: UInt64, byteSize: UInt64) -> BufferDescriptor {
    BufferDescriptor(address: address, byteSize: (byteSize + 3) & ~3)
  }

  /// Eight words: type in w0[3:0], buffer type in w0[7:4], size low in w1, address in w2 and w3,
  /// the stride in w4 (structure type), size high in w5 (arch 11 and later; arch 10 has 32 bits of size).
  public func words(arch: Int = 12) -> [UInt32] {
    var w = [UInt32](repeating: 0, count: 8)
    w[0] = BufferDescriptor.typeTag | kind.rawValue << 4
    w[1] = UInt32(truncatingIfNeeded: byteSize)
    w[2] = UInt32(truncatingIfNeeded: address)
    w[3] = UInt32(truncatingIfNeeded: address >> 32)
    if kind == .structure { w[4] = stride }
    if arch >= 11 && kind != .tilerHeap { w[5] = UInt32(truncatingIfNeeded: byteSize >> 32) }
    if kind == .structure { w[7] = conversion }
    return w
  }
}

// MARK: FAU pointer (03 section 3.10)

public enum FAUPointer {
  public static let maxWords = 255
  /// The FAU staging register: the 8-byte aligned address in [55:0], the count of 64-bit words in
  /// [63:56]. A zero count gives the zero register (no uniforms).
  public static func value(address: UInt64, words: Int) throws(DescriptorError) -> UInt64 {
    if words == 0 { return 0 }
    guard words <= maxWords else { throw .outOfRange }
    guard address & 7 == 0, address < 1 << 56 else { throw .misaligned }
    return address | UInt64(words) << 56
  }
}

// MARK: Shader program descriptor (04 section 4.2)

/// The registers a shader names, which fix its class (04 section 4.3).
public enum RegisterClass: UInt32, Sendable {
  /// r0 to r63.
  case r64 = 0
  /// r0 to r15 and r48 to r63.
  case r32 = 2
  public var registers: Int { self == .r64 ? 64 : 32 }
}

public struct ShaderProgramDescriptor: Equatable, Sendable {
  public enum Stage: UInt32, Sendable {
    case compute = 1
    case fragment = 2
    case vertex = 3
  }
  public static let size = 32
  public static let alignment = 32
  public static let typeTag: UInt32 = 8

  public var stage: Stage
  public var registerClass: RegisterClass
  /// Bit n preloads r(48 + n) (04 section 4.4); the stage's values are valhall 14's.
  public var preloadMask: UInt16
  /// Flush to zero mode, 0 to 3 (3 is not to be used).
  public var flushToZeroMode: UInt32
  /// 0 is no limit (arch 12 and later).
  public var maxWarps: UInt16
  /// The first instruction's address: 8-byte aligned (128 by policy), the binary in one 4 GiB window.
  public var binary: UInt64
  /// Fragment stage only (04 section 4.2.3): 0 the sample-to-bit order of the coverage mask follows D3D, 1 the
  /// OpenGL and Vulkan one (the reference driver's choice). Zero for the other stages.
  public var coverageBitmaskType: UInt32

  public init(stage: Stage = .compute, registerClass: RegisterClass, preloadMask: UInt16, flushToZeroMode: UInt32 = 0,
              maxWarps: UInt16 = 0, binary: UInt64, coverageBitmaskType: UInt32 = 0) {
    self.stage = stage
    self.registerClass = registerClass
    self.preloadMask = preloadMask
    self.flushToZeroMode = flushToZeroMode
    self.maxWarps = maxWarps
    self.binary = binary
    self.coverageBitmaskType = coverageBitmaskType
  }

  /// Word 0: type 8 in [3:0], stage in [7:4], the coverage bitmask type (fragment only) in [8], flush to zero in
  /// [18:17], register allocation in [31:30].
  /// Word 1: preload in [15:0], max warps in [31:16]. Words 2 and 3: the binary's address. 4 to 7: zero.
  public var words: [UInt32] {
    [
      ShaderProgramDescriptor.typeTag | stage.rawValue << 4 | (stage == .fragment ? (coverageBitmaskType & 1) << 8 : 0)
        | (flushToZeroMode & 3) << 17 | registerClass.rawValue << 30,
      UInt32(preloadMask) | UInt32(maxWarps) << 16,
      UInt32(truncatingIfNeeded: binary), UInt32(truncatingIfNeeded: binary >> 32),
      0, 0, 0, 0,
    ]
  }
}

// MARK: Local storage descriptor (04 section 4.5)

public struct LocalStorageDescriptor: Equatable, Sendable {
  public static let size = 32
  public static let alignment = 64
  /// WLS Instances' value for "no workgroup memory".
  public static let noWorkgroupMemory: UInt32 = 31

  public enum AddressMode: UInt32, Sendable {
    case flat = 0
    case packed = 1
  }

  /// The stack size class: each thread's stack is 16 << tlsSize bytes. 0 with no base is no stack.
  public var tlsSize: UInt32
  /// 4096-byte aligned, or 0.
  public var tlsBase: UInt64
  public var addressMode: AddressMode
  /// log2 of the instances per core, or 31.
  public var wlsInstances: UInt32
  /// One instance is 2^(scale - 1) bytes.
  public var wlsSizeScale: UInt32
  /// 4096-byte aligned, in one 4 GiB window, or 0.
  public var wlsBase: UInt64

  /// A record for a shader with neither kind of memory: all zero but WLS Instances = 31.
  public static let none = LocalStorageDescriptor(
    tlsSize: 0, tlsBase: 0, addressMode: .flat, wlsInstances: noWorkgroupMemory, wlsSizeScale: 0, wlsBase: 0)

  public init(tlsSize: UInt32, tlsBase: UInt64, addressMode: AddressMode, wlsInstances: UInt32, wlsSizeScale: UInt32,
              wlsBase: UInt64) {
    self.tlsSize = tlsSize
    self.tlsBase = tlsBase
    self.addressMode = addressMode
    self.wlsInstances = wlsInstances
    self.wlsSizeScale = wlsSizeScale
    self.wlsBase = wlsBase
  }

  /// Word 0: TLS size in [4:0]. Word 1: WLS instances in [4:0], size base (zero) in [6:5], size scale in
  /// [12:8]. Words 2 and 3: the TLS base shifted right by 8, 48 bits, with the address mode in word 3's
  /// [31:28]. Words 4 and 5: the WLS base. Words 6 and 7: zero.
  public var words: [UInt32] {
    let tls = tlsBase >> 8
    return [
      tlsSize & 0x1F,
      wlsInstances & 0x1F | (wlsSizeScale & 0x1F) << 8,
      UInt32(truncatingIfNeeded: tls),
      UInt32(truncatingIfNeeded: tls >> 32) & 0xFFFF | addressMode.rawValue << 28,
      UInt32(truncatingIfNeeded: wlsBase), UInt32(truncatingIfNeeded: wlsBase >> 32),
      0, 0,
    ]
  }
}

// MARK: Device limits and sizing (04 section 4.7, 16 section 16.4)

/// What the sizing rules read of the GPU (valhall 16 section 16.3): THREAD_MAX_THREADS,
/// THREAD_MAX_WORKGROUP_SIZE, THREAD_FEATURES' register count and task count, and the
/// cores that exist.
public struct ComputeLimits: Equatable, Sendable {
  public var maxThreadsPerCore: UInt32
  public var maxThreadsPerWorkgroup: UInt32
  /// 32-bit registers in a core's file: THREAD_FEATURES[21:0].
  public var registersPerCore: UInt32
  /// Concurrent tasks per core: THREAD_FEATURES[31:24], not zero.
  public var tasksPerCore: UInt32
  public var shaderPresent: UInt64

  public init(maxThreadsPerCore: UInt32, maxThreadsPerWorkgroup: UInt32, registersPerCore: UInt32, tasksPerCore: UInt32,
              shaderPresent: UInt64) {
    self.maxThreadsPerCore = maxThreadsPerCore
    self.maxThreadsPerWorkgroup = maxThreadsPerWorkgroup
    self.registersPerCore = registersPerCore
    self.tasksPerCore = tasksPerCore
    self.shaderPresent = shaderPresent
  }

  /// From the registers as the driver reports them: THREAD_MAX_THREADS, THREAD_MAX_WORKGROUP_SIZE and
  /// THREAD_FEATURES ([21:0] registers, [31:24] tasks), and the cores that exist (valhall 16 section 16.4.2).
  public init(maxThreads: UInt32, maxWorkgroupSize: UInt32, threadFeatures: UInt32, shaderPresent: UInt64) {
    self.init(maxThreadsPerCore: maxThreads, maxThreadsPerWorkgroup: maxWorkgroupSize,
              registersPerCore: threadFeatures & 0x3F_FFFF, tasksPerCore: threadFeatures >> 24 & 0xFF,
              shaderPresent: shaderPresent)
  }

  /// Whether every figure the sizing divides by or multiplies with is there (a GPU that read none gives zeros).
  public var isUsable: Bool {
    maxThreadsPerCore > 0 && maxThreadsPerWorkgroup > 0 && registersPerCore > 0 && tasksPerCore > 0 && shaderPresent != 0
  }

  public var coreCount: Int { shaderPresent.nonzeroBitCount }
  /// The highest core id plus one: storage is indexed by core id, so a mask with gaps needs room for them.
  public var coreRange: Int { 64 - shaderPresent.leadingZeroBitCount }

  /// Resident threads for a shader of a register class: min(workgroup limit, core limit, registers / class).
  public func residentThreads(_ c: RegisterClass) -> UInt32 {
    min(maxThreadsPerWorkgroup, maxThreadsPerCore, registersPerCore / UInt32(c.registers))
  }
}

public enum ThreadStorageSizing {
  /// TLS Size: 0 for no stack, else ceil(log2(ceil(stackBytes / 16))) (04 section 4.7.2).
  public static func tlsField(stackBytes: UInt32) -> UInt32 {
    if stackBytes == 0 { return 0 }
    return UInt32(log2Ceil((UInt64(stackBytes) + 15) / 16))
  }
  /// Bytes of stack per thread: 16 << field, or 0 for no stack.
  public static func perThreadBytes(stackBytes: UInt32) -> UInt64 {
    stackBytes == 0 ? 0 : 16 << UInt64(tlsField(stackBytes: stackBytes))
  }
  /// The allocation: per thread * threads per core * core range, to be 4096-byte aligned.
  public static func tlsTotal(stackBytes: UInt32, limits: ComputeLimits) -> UInt64 {
    perThreadBytes(stackBytes: stackBytes) * UInt64(limits.maxThreadsPerCore) * UInt64(limits.coreRange)
  }

  /// One instance's bytes: next power of two of max(shared, 128) (04 section 4.7.3); 0 for none.
  public static func wlsInstanceBytes(sharedBytes: UInt32) -> UInt64 {
    sharedBytes == 0 ? 0 : nextPowerOfTwo(UInt64(max(sharedBytes, 128)))
  }
  /// WLS Size Scale: log2(instance bytes) + 1.
  public static func wlsSizeScale(sharedBytes: UInt32) -> UInt32 {
    sharedBytes == 0 ? 0 : UInt32(log2Floor(wlsInstanceBytes(sharedBytes: sharedBytes))) + 1
  }

  /// The most instances a core uses at once (04 section 4.7.4): the workgroups of a task (the core's
  /// threads over its tasks, rounded up, over the workgroup's threads, rounded up) times the tasks,
  /// as a power of two.
  public static func instancesPerCoreLimit(workgroupThreads: UInt32, limits: ComputeLimits) -> UInt64 {
    let tasks = UInt64(max(limits.tasksPerCore, 1))
    let threadsTask = UInt64(limits.maxThreadsPerCore) / tasks
    let w = UInt64(max(workgroupThreads, 1))
    let wgTask = max((threadsTask + w - 1) / w, 1)
    return nextPowerOfTwo(wgTask * tasks)
  }

  /// WLS Instances (a power of two): min(next power of two of each grid axis multiplied, the core limit);
  /// `grid` nil for an indirect dispatch, which takes the core limit.
  public static func wlsInstances(
    workgroupThreads: UInt32, grid: (x: UInt32, y: UInt32, z: UInt32)?, limits: ComputeLimits
  ) -> UInt64 {
    let limit = instancesPerCoreLimit(workgroupThreads: workgroupThreads, limits: limits)
    guard let g = grid else { return limit }
    let wanted = nextPowerOfTwo(UInt64(g.x)) * nextPowerOfTwo(UInt64(g.y)) * nextPowerOfTwo(UInt64(g.z))
    return min(wanted, limit)
  }

  /// The allocation: instance bytes * instances * core range, 4096-byte aligned, in one 4 GiB window.
  public static func wlsTotal(sharedBytes: UInt32, instances: UInt64, limits: ComputeLimits) -> UInt64 {
    wlsInstanceBytes(sharedBytes: sharedBytes) * instances * UInt64(limits.coreRange)
  }
}

// MARK: Compute run state (01 section 1.9.2)

/// A workgroup count or size.
public struct Dim3: Equatable, Sendable {
  public var x: UInt32
  public var y: UInt32
  public var z: UInt32
  public init(_ x: UInt32, _ y: UInt32 = 1, _ z: UInt32 = 1) {
    self.x = x
    self.y = y
    self.z = z
  }
  public var product: UInt64 { UInt64(x) * UInt64(y) * UInt64(z) }
}

public enum ComputeRunState {
  /// WG_SIZE (register 33): each axis minus 1, 10 bits each, at [9:0], [19:10] and [29:20]; bit 31 allows
  /// the hardware to merge workgroups into one warp.
  public static func workgroupSizeWord(_ size: Dim3, allowMerging: Bool) throws(DescriptorError) -> UInt32 {
    guard size.x >= 1, size.y >= 1, size.z >= 1, size.x <= 1024, size.y <= 1024, size.z <= 1024 else {
      throw .outOfRange
    }
    return (size.x - 1) | (size.y - 1) << 10 | (size.z - 1) << 20 | (allowMerging ? 1 << 31 : 0)
  }

  /// One task's shape: `increment` workgroups along `axis` (0 X, 1 Y, 2 Z), a task covering every
  /// workgroup of the axes before it.
  public struct Task: Equatable, Sendable {
    public var increment: UInt32
    public var axis: Int
    public init(increment: UInt32, axis: Int) {
      self.increment = increment
      self.axis = axis
    }
  }

  /// The sizing policy of 01 section 1.9.2. T is the shader's resident threads divided by the tasks per
  /// core, rounded up; w the threads of one workgroup. The increment starts at max(1, T / w), capped at
  /// the workgroups per core when the grid is spread evenly over the cores (rounded up); it starts on
  /// X, and while it exceeds the grid along the axis it moves to the next axis and is divided by that
  /// grid size (rounding down, at least 1). The field is 14 bits.
  public static func task(
    workgroup: Dim3, grid: Dim3, registerClass: RegisterClass, limits: ComputeLimits
  ) -> Task {
    let resident = UInt64(limits.residentThreads(registerClass))
    let tasks = UInt64(max(limits.tasksPerCore, 1))
    let t = (resident + tasks - 1) / tasks
    let w = max(workgroup.product, 1)
    var inc = max(1, t / w)
    let cores = UInt64(max(limits.coreCount, 1))
    let perCore = max(1, (grid.product + cores - 1) / cores)
    inc = min(inc, perCore)
    var axis = 0
    let sizes = [UInt64(grid.x), UInt64(grid.y), UInt64(grid.z)]
    while axis < 2 && inc > sizes[axis] && sizes[axis] > 0 {
      inc = max(1, inc / sizes[axis])
      axis += 1
    }
    return Task(increment: UInt32(min(inc, 0x3FFF)), axis: axis)
  }
}
