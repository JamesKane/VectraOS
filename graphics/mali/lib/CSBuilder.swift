// SPDX-License-Identifier: BSD-3-Clause

// A user command stream's builder: instructions appended into a stream that
// lives in a GPU buffer at a known address, the register and scoreboard
// conventions valhall 02 gives user streams (sections 2.1.3, 2.2.3, 2.3.1 and
// 2.10), and what the kernel's job sequence leaves to the user: the top
// registers are its scratch (panthor 07 section 7.4.4), a job's stream
// starts 64-byte aligned, and a stream ends by returning (the kernel waits
// for every slot and signals the job's sync object).

public enum CSBuildError: Error, Equatable, Sendable {
  /// The stream is longer than the space for it.
  case overflow(words: Int, capacity: Int)
  case empty
  /// The stream's address isn't 64-byte aligned.
  case misaligned
  /// A register the stream names is one the kernel clobbers, or beyond the file.
  case register(Int)
}

/// Which registers a user stream may use (02 section 2.10, arch 12 and later: 128 registers).
public struct CSRegisterMap: Equatable, Sendable {
  /// The stream's work registers, and of them the top `unpreserved` that a job's call clobbers (at least 4).
  public var workRegisters: Int
  public var unpreserved: Int

  public init(workRegisters: Int, unpreserved: Int) {
    self.workRegisters = workRegisters
    self.unpreserved = max(unpreserved, 4)
  }

  /// Registers 0 to 39 stage a compute run (01 section 1.9.2); 0 to 65 an IDVS run.
  public static let computeStagingEnd = 40
  /// The first scratch register (02 section 2.10: 66 to 115 on arch 12; 66 to 83 on arch 10 and 11).
  public static let firstScratch = 66

  /// One past the highest register a user stream may touch.
  public var usableEnd: Int { workRegisters - unpreserved }
  public func isUsable(_ r: Int) -> Bool { r >= 0 && r < usableEnd }
  /// The compute staging pairs (01 section 1.9.2): SRT_n at 0 + 2n, FAU_n at 8 + 2n, SPD_n at 16 + 2n, TSD_n at 24 + 2n.
  public static func srt(_ n: Int = 0) -> Int { 2 * n }
  public static func fau(_ n: Int = 0) -> Int { 8 + 2 * n }
  public static func spd(_ n: Int = 0) -> Int { 16 + 2 * n }
  public static func tsd(_ n: Int = 0) -> Int { 24 + 2 * n }
  public static let globalAttributeOffset = 32
  public static let workgroupSize = 33
  public static let jobOffsetX = 34
  public static let jobSizeX = 37
}

/// The scoreboard slot roles (02 section 2.3.1) for a queue of `count` slots (8 on arch 10, 16 after).
public struct CSScoreboards: Equatable, Sendable {
  public var count: Int
  public init(count: Int) { self.count = min(max(count, 1), 16) }

  /// Loads, stores and immediate cache flushes.
  public static let loadStoreSlot = 0
  /// Deferred sync-object updates.
  public static let deferredSyncSlot = 1
  /// Cache flushes a later deferred operation waits for.
  public static let deferredFlushSlot = 2
  /// The first slot endpoint work (RUN_*) rotates through.
  public static let firstRotating = 3

  public var allSlots: UInt16 { count >= 16 ? 0xFFFF : UInt16((1 << count) - 1) }
  public var rotatingSlots: UInt16 { allSlots & ~0x7 }
  public func slotMask(_ slot: Int) -> UInt16 { UInt16(1) << UInt16(slot) }
}

public struct CSStream: Equatable, Sendable {
  /// GPU address of the first instruction: 64-byte aligned.
  public var address: UInt64
  public var words: [UInt64]
  /// Bytes: a multiple of 8, as `CSFContext.submit`'s job size.
  public var size: Int { words.count * 8 }
}

public struct CSBuilder: Sendable {
  public let address: UInt64
  public let capacityWords: Int
  public let registers: CSRegisterMap
  public let scoreboards: CSScoreboards
  public private(set) var words: [UInt64] = []
  private var badRegister: Int?

  /// - Parameters:
  ///   - address: where the stream will be in the GPU's address space (64-byte aligned).
  ///   - capacityBytes: the room there is for it.
  public init(address: UInt64, capacityBytes: Int, registers: CSRegisterMap, scoreboards: CSScoreboards) {
    self.address = address
    capacityWords = capacityBytes / 8
    self.registers = registers
    self.scoreboards = scoreboards
    words.reserveCapacity(64)
  }

  public var count: Int { words.count }

  private mutating func use(_ r: Int, pair: Bool = false) {
    let top = pair ? r + 1 : r
    if (!registers.isUsable(r) || !registers.isUsable(top)) && badRegister == nil { badRegister = r }
    precondition(!pair || r & 1 == 0, "a 64-bit register operand starts at an even register")
  }

  /// Append an instruction word. Registers in it are the caller's to have checked (the helpers below do).
  public mutating func emit(_ word: UInt64) { words.append(word) }

  // MARK: Registers

  public mutating func move32(_ r: Int, _ value: UInt32) {
    use(r)
    emit(CSInstruction.mov32(r, value))
  }
  /// A 64-bit value into the pair at `r`: MOVE48 for what fits 48 bits, then MOVE32 of the high word.
  public mutating func move64(_ r: Int, _ value: UInt64) {
    use(r, pair: true)
    emit(CSInstruction.mov48(r, value & 0xFFFF_FFFF_FFFF))
    if value >> 48 != 0 { emit(CSInstruction.mov32(r + 1, UInt32(truncatingIfNeeded: value >> 32))) }
  }

  // MARK: Scoreboards (02 section 2.2.3, step 2, arch 11 and later)

  /// A queue's initial slot state: endpoint work on the first rotating slot, waits on that slot, loads and
  /// stores on slot 0, deferred operations on slot 1, and the stream mask the rotating slots but that one.
  public mutating func initialiseSlotState() {
    let first = CSScoreboards.firstRotating
    emit(CSInstruction.setState(.endpointSlot, immediate: UInt32(first)))
    emit(CSInstruction.setState(.waitMask, immediate: UInt32(scoreboards.slotMask(first))))
    emit(CSInstruction.setState(.otherSlot, immediate: UInt32(CSScoreboards.loadStoreSlot)))
    emit(CSInstruction.setState(.deferredSlot, immediate: UInt32(CSScoreboards.deferredSyncSlot)))
    emit(CSInstruction.setState(.streamMask, immediate: UInt32(scoreboards.rotatingSlots & ~scoreboards.slotMask(first))))
  }

  public mutating func requestResources(_ r: CSResources) { emit(CSInstruction.requestResources(r)) }
  public mutating func wait(mask: UInt16) { emit(CSInstruction.wait(mask: mask)) }
  /// WAIT on every slot.
  public mutating func waitAll() { emit(CSInstruction.wait(mask: scoreboards.allSlots)) }
  /// Wait for the endpoint slot the initial state selects: every RUN_* the stream issued.
  public mutating func waitForRuns() { emit(CSInstruction.wait(mask: scoreboards.slotMask(CSScoreboards.firstRotating))) }

  // MARK: Caches (01 section 1.8, 02 sections 2.5.2 and 2.9.1)

  /// Whether the clean at the end of a stream also invalidates the GPU's caches (so the next stream reads what the CPU wrote since, in
  /// memory the GPU maps cacheable): on while all memory is GPU-cacheable.
  public nonisolated(unsafe) static var cleanInvalidates = false

  /// Clean the L2 and the LSC so the CPU sees what the GPU wrote, and wait for it: the stream tail's step
  /// 3. The flush id's register holds zero (a user driver's value). With `cleanInvalidates` the L2 and LSC are also
  /// invalidated and the read-only caches too.
  public mutating func cleanCachesForHost() {
    let scratch = CSRegisterMap.firstScratch
    move32(scratch, 0)
    let invalidating = unsafe CSBuilder.cleanInvalidates
    emit(CSInstruction.flushCache2(l2: invalidating ? .cleanInvalidate : .clean, lsc: invalidating ? .cleanInvalidate : .clean,
                                   other: invalidating ? .invalidate : .none, flushIDRegister: scratch,
                                   signalSlot: CSScoreboards.loadStoreSlot))
    wait(mask: scoreboards.slotMask(CSScoreboards.loadStoreSlot))
  }

  // MARK: Finishing

  public func finish() throws(CSBuildError) -> CSStream {
    if let r = badRegister { throw .register(r) }
    if words.isEmpty { throw .empty }
    if address & 63 != 0 { throw .misaligned }
    if words.count > capacityWords { throw .overflow(words: words.count, capacity: capacityWords) }
    return CSStream(address: address, words: words)
  }
}
