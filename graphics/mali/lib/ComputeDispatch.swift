// SPDX-License-Identifier: BSD-3-Clause

// A compute dispatch as a recipe (valhall 01 section 1.9.2, 02 sections 2.2.3
// and 2.9.1, 04): given a compiled shader and what to run it over, it lays the
// shader program descriptor, the local storage descriptor, the resource table
// and its buffer descriptors, the FAU words, the shader binary and the command
// stream into one block of GPU memory, and returns the block's bytes and the
// stream's address and size for `CSFContext.submit`. Pure: the caller allocates
// the block (and the thread and workgroup memory a shader needs), writes the
// bytes into it and submits. Nothing here touches the GPU.

/// What the compiler hands the driver for a compute shader: the contract between
/// `graphics/compiler/valhall` and MaliCore. The compiler fills it; MaliCore reads
/// nothing of the binary but its length.
public struct ComputeShader: Equatable, Sendable {
  /// The shader's instructions, 64-bit words in the order of valhall 10: the first is the entry. Every
  /// path ends in an instruction with the `end` flow, so a binary never runs past its last word.
  public var code: [UInt64]
  /// 32 if every register the shader names is in r0 to r15 or r48 to r63, else 64 (04 section 4.3).
  public var registerClass: RegisterClass
  /// Bit n: r(48 + n) is preloaded (04 section 4.4); compute's values are 14 section 14.2.1's.
  public var preloadMask: UInt16
  /// The workgroup size the shader was compiled for (the module's local size).
  public var workgroupSize: Dim3
  /// Bytes of stack and spill per thread; 0 for none (04 section 4.7.2).
  public var stackBytes: UInt32
  /// Bytes of workgroup memory the shader uses; 0 for none (04 section 4.7.3).
  public var workgroupMemoryBytes: UInt32
  /// 32-bit words of the FAU block the shader reads (the highest word it names, plus one); the driver
  /// writes at least ceil(n / 2) 64-bit words (14 section 14.7.3).
  public var fauWords: UInt32
  /// Whether nothing the shader does can observe two workgroups sharing a warp: no workgroup memory, no
  /// workgroup-scope barrier, no subgroup operation, no read of the subgroup index (01 section 1.9.2).
  public var allowsWorkgroupMerging: Bool
  /// The SPD's flush-to-zero mode (04 section 4.2.4).
  public var flushToZeroMode: UInt32

  public init(code: [UInt64], registerClass: RegisterClass, preloadMask: UInt16, workgroupSize: Dim3,
              stackBytes: UInt32 = 0, workgroupMemoryBytes: UInt32 = 0, fauWords: UInt32 = 0,
              allowsWorkgroupMerging: Bool = false, flushToZeroMode: UInt32 = 0) {
    self.code = code
    self.registerClass = registerClass
    self.preloadMask = preloadMask
    self.workgroupSize = workgroupSize
    self.stackBytes = stackBytes
    self.workgroupMemoryBytes = workgroupMemoryBytes
    self.fauWords = fauWords
    self.allowsWorkgroupMerging = allowsWorkgroupMerging
    self.flushToZeroMode = flushToZeroMode
  }
}

public enum DispatchError: Error, Equatable, Sendable {
  case descriptor(DescriptorError)
  case stream(CSBuildError)
  /// The block is too small: `needed` bytes against `capacity`.
  case noRoom(needed: Int, capacity: Int)
  case emptyShader
  /// The FAU block is shorter than the shader's `fauWords` need.
  case fauTooShort
  /// A grid axis is zero, or a size exceeds the device's workgroup limit.
  case badGrid
  /// The shader needs stack or workgroup memory and no limits or no base address were given.
  case needsLimits
  /// The thread or workgroup memory is not 4096-byte aligned.
  case storageMisaligned
  case arch(Int)
}

/// A dispatch of one shader (01 section 1.9.2).
public struct ComputeDispatchRequest: Sendable {
  public var shader: ComputeShader
  /// Workgroups.
  public var grid: Dim3
  /// The FAU block's 64-bit words: system values and push constants, as the compiler addresses them.
  public var fau: [UInt64]
  /// Buffer descriptors for table 0, in index order (03 section 3.4). Empty: the shader reads no resources.
  public var buffers: [BufferDescriptor]
  /// The thread storage and workgroup memory, allocated by the caller at the sizes `ComputeSizing` gives
  /// (4096-byte aligned; workgroup memory inside one 4 GiB window). 0 for none.
  public var threadStorage: UInt64
  public var workgroupMemory: UInt64
  /// The GPU's limits; nil when unknown, which takes one workgroup per task and no per-core limit, and
  /// refuses a shader that needs stack or workgroup memory.
  public var limits: ComputeLimits?
  /// Whether the stream asks for the compute resource first (REQ_RESOURCE, once per queue; 02 section 2.9.3).
  public var requestComputeResource: Bool
  /// Whether the stream sets the queue's slot state first (02 section 2.2.3).
  public var initialiseQueue: Bool
  /// A dispatch whose grid is three 32-bit words at this address when the stream runs. As the driver the spec was read
  /// from does (01 section 1.9.2), the stream loads the words into `JOB_SIZE_X/Y/Z` itself and issues RUN_COMPUTE (never
  /// RUN_COMPUTE_INDIRECT, which hangs), on the X axis; and it copies them into the FAU block's number of workgroups
  /// where the shader reads them (`numWorkgroupsWord`, a 32-bit word index in the block; -1 for none). `grid` is then
  /// only a placeholder.
  public var indirectGrid: UInt64?
  public var numWorkgroupsWord: Int = -1
  /// The storage images' descriptors (table 2 of the resource table): their address and size in bytes.
  public var storageTable: (address: UInt64, bytes: Int)?
  /// The heap's textures and samplers (table 1 of the resource table), for a shader that samples.
  public var heapTable: (address: UInt64, bytes: Int)?
  /// The dispatch's place in its submission's chain of steps (StepChain), if it has one.
  public var chain: StepChain?

  public init(shader: ComputeShader, grid: Dim3, fau: [UInt64] = [], buffers: [BufferDescriptor] = [],
              threadStorage: UInt64 = 0, workgroupMemory: UInt64 = 0, limits: ComputeLimits? = nil,
              requestComputeResource: Bool = true, initialiseQueue: Bool = true) {
    self.shader = shader
    self.grid = grid
    self.fau = fau
    self.buffers = buffers
    self.threadStorage = threadStorage
    self.workgroupMemory = workgroupMemory
    self.limits = limits
    self.requestComputeResource = requestComputeResource
    self.initialiseQueue = initialiseQueue
  }
}

/// What the dispatch needs beyond its own block (04 sections 4.7.2 to 4.7.4), for a caller to allocate.
public struct ComputeSizing: Equatable, Sendable {
  public var tlsField: UInt32
  public var tlsBytes: UInt64
  public var wlsInstancesLog2: UInt32
  public var wlsSizeScale: UInt32
  public var wlsBytes: UInt64

  public static func of(shader: ComputeShader, grid: Dim3?, limits: ComputeLimits) -> ComputeSizing {
    let tls = ThreadStorageSizing.tlsField(stackBytes: shader.stackBytes)
    let tlsBytes = ThreadStorageSizing.tlsTotal(stackBytes: shader.stackBytes, limits: limits)
    guard shader.workgroupMemoryBytes != 0 else {
      return ComputeSizing(tlsField: tls, tlsBytes: tlsBytes, wlsInstancesLog2: LocalStorageDescriptor.noWorkgroupMemory,
                           wlsSizeScale: 0, wlsBytes: 0)
    }
    let threads = UInt32(truncatingIfNeeded: shader.workgroupSize.product)
    let g = grid.map { (x: $0.x, y: $0.y, z: $0.z) }
    let instances = ThreadStorageSizing.wlsInstances(workgroupThreads: threads, grid: g, limits: limits)
    return ComputeSizing(
      tlsField: tls, tlsBytes: tlsBytes, wlsInstancesLog2: UInt32(log2Floor(instances)),
      wlsSizeScale: ThreadStorageSizing.wlsSizeScale(sharedBytes: shader.workgroupMemoryBytes),
      wlsBytes: ThreadStorageSizing.wlsTotal(sharedBytes: shader.workgroupMemoryBytes, instances: instances, limits: limits))
  }
}

/// A dispatch laid out in GPU memory.
public struct ComputeDispatchImage: Equatable, Sendable {
  /// The block's bytes, to be stored at `base`.
  public var memory: MemoryImage
  public var base: UInt64
  public var spd: UInt64
  public var tsd: UInt64
  public var resourceTable: UInt64
  public var tables: UInt64
  public var fau: UInt64
  public var shader: UInt64
  /// The stream: its address and size are the job's.
  public var stream: CSStream
  /// The staging register values the stream loads, as the stream decoder reads them back.
  public var srtRegister: UInt64
  public var fauRegister: UInt64
}

public enum ComputeDispatch {
  /// The alignment of the block, and of each record in it (the stream's is 64; the binary's 128 by policy).
  public static let blockAlignment = 4096

  /// The registers the recipe uses beyond the staging registers 0 to 39: a zero for the flush id.
  public static func build(
    at base: UInt64, capacity: Int, request r: ComputeDispatchRequest, registers: CSRegisterMap,
    scoreboards: CSScoreboards, arch: Int = 12
  ) throws(DispatchError) -> ComputeDispatchImage {
    guard arch >= 11 else { throw .arch(arch) }
    guard !r.shader.code.isEmpty else { throw .emptyShader }
    let s = r.shader
    guard r.grid.x > 0, r.grid.y > 0, r.grid.z > 0, s.workgroupSize.product > 0,
      s.workgroupSize.product <= UInt64(r.limits?.maxThreadsPerWorkgroup ?? 1024)
    else { throw .badGrid }
    guard (s.fauWords + 1) / 2 <= UInt32(r.fau.count) else { throw .fauTooShort }
    guard base & 63 == 0 else { throw .descriptor(.misaligned) }

    // Layout, relative to the base: the descriptors first (each at its own alignment), the binary at
    // 128, the stream last.
    var offset = 0
    func place(_ size: Int, _ align: Int) -> Int {
      offset = alignUp(offset, align)
      let at = offset
      offset += size
      return at
    }
    let spdAt = place(ShaderProgramDescriptor.size, ShaderProgramDescriptor.alignment)
    let tsdAt = place(LocalStorageDescriptor.size, LocalStorageDescriptor.alignment)
    var tableBytes: [UInt8] = []
    var tableAt = 0
    var entriesAt = 0
    let hasTable = !r.buffers.isEmpty || r.storageTable != nil || r.heapTable != nil
    if hasTable {
      // Table 0 is the buffers' descriptors, table 2 the storage images' (the heap's second array).
      var entries = [ResourceTableEntry](repeating: .unused, count: DescriptorHeap.tableEntries)
      if !r.buffers.isEmpty {
        tableAt = place(r.buffers.count * BufferDescriptor.size, 32)
        entries[0] = ResourceTableEntry(address: base + UInt64(tableAt), containsDescriptors: true,
                                        size: UInt64(r.buffers.count * BufferDescriptor.size))
      }
      if let h = r.heapTable {
        entries[DescriptorHeap.tableNumber] = ResourceTableEntry(address: h.address, containsDescriptors: true, size: UInt64(h.bytes))
      }
      if let s = r.storageTable {
        entries[DescriptorHeap.storageTableNumber] = ResourceTableEntry(
          address: s.address, containsDescriptors: true, size: UInt64(s.bytes))
      }
      do throws(DescriptorError) { tableBytes = try ResourceTable.encode(entries) } catch { throw .descriptor(error) }
      entriesAt = place(tableBytes.count, ResourceTable.alignment)
    }
    let fauAt = place(max(r.fau.count, 0) * 8, 8)
    let codeAt = place(s.code.count * 8, 128)
    let streamAt = place(0, 64)

    // The stream, whose size doesn't depend on where the records are.
    var b = CSBuilder(address: base + UInt64(streamAt), capacityBytes: max(capacity - streamAt, 0), registers: registers,
                      scoreboards: scoreboards)
    let spdVA = base + UInt64(spdAt)
    let tsdVA = base + UInt64(tsdAt)
    var srt: UInt64 = 0
    var fauReg: UInt64 = 0
    do throws(DescriptorError) {
      if hasTable { srt = try ResourceTable.pointer(address: base + UInt64(entriesAt), entryCount: 4) }
      fauReg = try FAUPointer.value(address: base + UInt64(fauAt), words: r.fau.count)
    } catch { throw .descriptor(error) }

    let task: ComputeRunState.Task
    var epLimit: UInt8 = 0
    if r.indirectGrid != nil, let lim = r.limits {
      // The grid isn't known when the stream is built: the increment the spec's substitute uses (01 section 1.9.2), the
      // threads of a task over the workgroup's, rounded up, on the X axis (the hardware clamps it to the grid).
      let tasks = UInt64(max(lim.tasksPerCore, 1))
      let perTask = UInt64(lim.maxThreadsPerCore) / tasks
      let w = max(s.workgroupSize.product, 1)
      task = ComputeRunState.Task(increment: UInt32(min(max((perTask + w - 1) / w, 1), 0x3FFF)), axis: 0)
      epLimit = arch >= 12 ? UInt8(min(lim.tasksPerCore, 255)) : 0
    } else if let lim = r.limits {
      task = ComputeRunState.task(workgroup: s.workgroupSize, grid: r.grid, registerClass: s.registerClass, limits: lim)
      // Arch 12 and later only: arch 10 and 11 need 0 (valhall 16 section 16.5).
      epLimit = arch >= 12 ? UInt8(min(lim.tasksPerCore, 255)) : 0
    } else {
      task = ComputeRunState.Task(increment: 1, axis: 0)
    }
    let wgWord: UInt32
    do throws(DescriptorError) {
      wgWord = try ComputeRunState.workgroupSizeWord(s.workgroupSize, allowMerging: s.allowsWorkgroupMerging
                                                      && s.workgroupMemoryBytes == 0)
    } catch { throw .descriptor(error) }

    if r.initialiseQueue { b.initialiseSlotState() }
    b.startStep(r.chain)
    if r.requestComputeResource { b.requestResources(.compute) }
    b.move64(CSRegisterMap.srt(), srt)
    b.move64(CSRegisterMap.fau(), fauReg)
    b.move64(CSRegisterMap.spd(), spdVA)
    b.move64(CSRegisterMap.tsd(), tsdVA)
    b.move32(CSRegisterMap.globalAttributeOffset, 0)
    b.move32(CSRegisterMap.workgroupSize, wgWord)
    for i in 0..<3 { b.move32(CSRegisterMap.jobOffsetX + i, 0) }
    if let args = r.indirectGrid {
      // The grid's three words from memory into JOB_SIZE_X/Y/Z, and into the FAU block where the shader reads them.
      let argRegister = CSRegisterMap.firstScratch
      b.move64(argRegister, args)
      b.emit(CSInstruction.loadMultiple(base: CSRegisterMap.jobSizeX, address: argRegister, mask: 0b111))
      b.wait(mask: scoreboards.slotMask(CSScoreboards.loadStoreSlot))
      if r.numWorkgroupsWord >= 0 {
        b.move64(argRegister + 2, base + UInt64(fauAt))
        b.emit(CSInstruction.storeMultiple(base: CSRegisterMap.jobSizeX, address: argRegister + 2,
                                           offset: Int16(r.numWorkgroupsWord * 4), mask: 0b111))
        b.wait(mask: scoreboards.slotMask(CSScoreboards.loadStoreSlot))
      }
      // 06 section 6.4.7: a grid with a zero dimension does no work, and the run is not issued for one (the hardware's
      // answer to it is no source's to say): the stream branches over it.
      for axis in 0..<3 {
        b.emit(CSInstruction.branch(.equal, register: CSRegisterMap.jobSizeX + axis, offset: Int16(3 - axis)))
      }
    } else {
      b.move32(CSRegisterMap.jobSizeX, r.grid.x)
      b.move32(CSRegisterMap.jobSizeX + 1, r.grid.y)
      b.move32(CSRegisterMap.jobSizeX + 2, r.grid.z)
    }
    b.emit(CSInstruction.runCompute(taskIncrement: task.increment, taskAxis: task.axis, epLimit: epLimit))
    // The tail (02 section 2.9.1): every slot drained, the caches cleaned for the CPU.
    b.stepTail(r.chain)
    b.endStep(r.chain)
    let stream: CSStream
    do throws(CSBuildError) { stream = try b.finish() } catch { throw .stream(error) }

    let total = streamAt + stream.size
    guard total <= capacity else { throw .noRoom(needed: total, capacity: capacity) }

    // The local storage: no memory of either kind, or what the caller allocated.
    var tsd = LocalStorageDescriptor.none
    if s.stackBytes != 0 || s.workgroupMemoryBytes != 0 {
      guard let lim = r.limits else { throw .needsLimits }
      let sizing = ComputeSizing.of(shader: s, grid: r.indirectGrid == nil ? r.grid : nil, limits: lim)
      if s.stackBytes != 0 {
        guard r.threadStorage != 0 else { throw .needsLimits }
        guard r.threadStorage & 4095 == 0 else { throw .storageMisaligned }
        tsd.tlsSize = sizing.tlsField
        tsd.tlsBase = r.threadStorage
        tsd.addressMode = .packed
      }
      if s.workgroupMemoryBytes != 0 {
        guard r.workgroupMemory != 0 else { throw .needsLimits }
        guard r.workgroupMemory & 4095 == 0 else { throw .storageMisaligned }
        tsd.wlsInstances = sizing.wlsInstancesLog2
        tsd.wlsSizeScale = sizing.wlsSizeScale
        tsd.wlsBase = r.workgroupMemory
      }
    }

    var m = MemoryImage(size: total)
    m.store(words: ShaderProgramDescriptor(
      stage: .compute, registerClass: s.registerClass, preloadMask: s.preloadMask, flushToZeroMode: s.flushToZeroMode,
      binary: base + UInt64(codeAt)).words, at: spdAt)
    m.store(words: tsd.words, at: tsdAt)
    for (i, d) in r.buffers.enumerated() { m.store(words: d.words(arch: arch), at: tableAt + i * BufferDescriptor.size) }
    if !tableBytes.isEmpty { m.store(bytes: tableBytes, at: entriesAt) }
    m.store(words: r.fau, at: fauAt)
    m.store(words: s.code, at: codeAt)
    m.store(words: stream.words, at: streamAt)
    return ComputeDispatchImage(
      memory: m, base: base, spd: spdVA, tsd: tsdVA, resourceTable: !hasTable ? 0 : base + UInt64(entriesAt),
      tables: r.buffers.isEmpty ? 0 : base + UInt64(tableAt), fau: r.fau.isEmpty ? 0 : base + UInt64(fauAt),
      shader: base + UInt64(codeAt), stream: stream, srtRegister: srt, fauRegister: fauReg)
  }
}
