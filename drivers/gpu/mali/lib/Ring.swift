// SPDX-License-Identifier: BSD-3-Clause

// The command-stream ring's writer: the kernel's CS instructions and the
// job sequence it writes around a client's stream, the ring's space
// accounting, and completion read from a queue's 64-bit sync object
// (chinese-wall's panthor 07 section 7.2 to 7.4). Pure logic: the words
// are returned, and the caller stores them into the mapped ring.

/// One CS instruction is one 64-bit word whose top byte is its opcode
/// (07 section 7.4.5). Only the instructions the kernel writes.
public enum RingInstruction {
  public static func mov48(_ register: Int, _ immediate: UInt64) -> UInt64 {
    0x01 << 56 | UInt64(register & 0xFF) << 48 | immediate & 0xFFFF_FFFF_FFFF
  }
  public static func mov32(_ register: Int, _ immediate: UInt32) -> UInt64 {
    0x02 << 56 | UInt64(register & 0xFF) << 48 | UInt64(immediate)
  }
  /// Wait on the scoreboard slots in `mask`.
  public static func wait(mask: UInt16) -> UInt64 { 0x03 << 56 | UInt64(mask) << 16 }
  public static func call(address: Int, size: Int) -> UInt64 {
    0x20 << 56 | UInt64(address & 0xFF) << 40 | UInt64(size & 0xFF) << 32
  }
  /// Clean and invalidate the L2 and LSC, no wait, signalling scoreboard 0,
  /// flush ID in register `flushID` (mode 0x233, 07's open question).
  public static func flushCache2(flushID: Int) -> UInt64 {
    0x24 << 56 | UInt64(flushID & 0xFF) << 40 | 0x233
  }
  /// Store the cycle counter (selector 1) or the timestamp (0) at the
  /// address in the register pair `address`.
  public static func storeState(address: Int, cycles: Bool) -> UInt64 {
    0x28 << 56 | UInt64(address & 0xFF) << 40 | (cycles ? 1 << 32 : 0)
  }
  public static let errorBarrier: UInt64 = 0x2F << 56
  /// Add the 64-bit pair `value` to the sync object at `address`: system
  /// scope, error propagated, no wait.
  public static func syncAdd64(address: Int, value: Int) -> UInt64 {
    0x33 << 56 | UInt64(address & 0xFF) << 40 | UInt64(value & 0xFF) << 32 | 0x1
  }
}

/// Which optional rows of the job sequence a job carries (07 section 7.14).
public struct ProfilingKinds: Equatable, Sendable {
  public var cycles: Bool
  public var time: Bool
  public init(cycles: Bool = false, time: Bool = false) {
    self.cycles = cycles
    self.time = time
  }
  public static let none = ProfilingKinds()
}

/// What a queue's CS reports about itself, for the job sequence's registers.
public struct JobSequenceShape: Equatable, Sendable {
  /// RA, the first register of the 64-bit address pair: the top four work
  /// registers are scratch the firmware doesn't keep across a call.
  public let ra: Int
  /// RV, RA + 2.
  public let rv: Int
  /// Every scoreboard slot's bit.
  public let scoreboardMask: UInt16

  /// - Parameters:
  ///   - workRegisters: the CS's work registers (FEATURES bits [7:0] plus one).
  ///   - scoreboards: its scoreboard slots (FEATURES bits [15:8]), 1 to 16.
  public init(workRegisters: Int, scoreboards: Int) {
    // [POLICY] a pair starts on an even register; fewer than 8 registers
    // leave no scratch range, so the pair is r4.
    var r = workRegisters - 4
    if r < 4 { r = 4 }
    ra = r & ~1
    rv = ra + 2
    let n = scoreboards < 1 ? 1 : (scoreboards > 16 ? 16 : scoreboards)
    scoreboardMask = n == 16 ? 0xFFFF : UInt16((1 << n) - 1)
  }
}

public enum JobSequence {
  /// Instructions before padding.
  public static func unpaddedCount(_ p: ProfilingKinds) -> Int {
    11 + (p.cycles ? 4 : 0) + (p.time ? 4 : 0)
  }
  /// Instructions after padding to a whole 64-byte line: 16, or 24 with both.
  public static func paddedCount(_ p: ProfilingKinds) -> Int {
    (unpaddedCount(p) + 7) & ~7
  }

  /// 07 section 7.4.4's sequence for one job, padded with zero words.
  /// - Parameters:
  ///   - profilingSlot: GPU VA of the job's 32-byte profiling slot, used
  ///     when `profiling` is on (+0 cycles before, +8 after, +16 time
  ///     before, +24 after).
  public static func build(
    _ s: JobSequenceShape, flushID: UInt32, streamVA: UInt64, streamSize: UInt32,
    syncVA: UInt64, profilingSlot: UInt64, profiling: ProfilingKinds
  ) -> [UInt64] {
    let ra = s.ra
    let rv = s.rv
    var w: [UInt64] = []
    w.reserveCapacity(24)
    w.append(RingInstruction.mov32(rv, flushID))
    w.append(RingInstruction.flushCache2(flushID: rv))
    if profiling.cycles {
      w.append(RingInstruction.mov48(ra, profilingSlot))
      w.append(RingInstruction.storeState(address: ra, cycles: true))
    }
    if profiling.time {
      w.append(RingInstruction.mov48(ra, profilingSlot &+ 16))
      w.append(RingInstruction.storeState(address: ra, cycles: false))
    }
    w.append(RingInstruction.mov48(ra, streamVA))
    w.append(RingInstruction.mov32(rv, streamSize))
    w.append(RingInstruction.wait(mask: 0x0001))
    w.append(RingInstruction.call(address: ra, size: rv))
    if profiling.cycles {
      w.append(RingInstruction.mov48(ra, profilingSlot &+ 8))
      w.append(RingInstruction.storeState(address: ra, cycles: true))
    }
    if profiling.time {
      w.append(RingInstruction.mov48(ra, profilingSlot &+ 24))
      w.append(RingInstruction.storeState(address: ra, cycles: false))
    }
    w.append(RingInstruction.mov48(ra, syncVA))
    w.append(RingInstruction.mov48(rv, 1))
    w.append(RingInstruction.wait(mask: s.scoreboardMask))
    w.append(RingInstruction.syncAdd64(address: ra, value: rv))
    w.append(RingInstruction.errorBarrier)
    while w.count & 7 != 0 { w.append(0) }
    return w
  }
}

/// A queue's kernel sync object, 64-bit form (07 section 7.2.3).
public struct SyncRecord: Equatable, Sendable {
  public var sequence: UInt64
  /// Non-zero is an error.
  public var status: UInt32
  public init(sequence: UInt64, status: UInt32 = 0) {
    self.sequence = sequence
    self.status = status
  }
  /// From the record's two little-endian words: the sequence, then the
  /// status in the low half (the high half is padding).
  public init(word0: UInt64, word1: UInt64) {
    self.init(sequence: word0, status: UInt32(truncatingIfNeeded: word1))
  }
  /// What termination writes (07 section 7.10.5).
  public static let terminatedStatus: UInt32 = 0xFFFF_FFFF
}

/// Why a job's fence signalled badly (07 section 7.4.6).
public enum FenceError: Equatable, Sendable {
  case none
  case invalid
  case timedOut
  case cancelled
}

public struct FinishedJob: Equatable, Sendable {
  /// The client's cookie for the job.
  public var tag: UInt64
  /// The fence number: the queue's sync sequence this job raises. An empty
  /// job carries the number of the job before it.
  public var sequence: UInt64
  public var error: FenceError
  public var isEmpty: Bool
}

/// One queue's ring: its space, its fence numbers and the jobs in flight.
public struct JobRing: Sendable {
  struct Job: Sendable {
    var tag: UInt64
    var sequence: UInt64
    var isEmpty: Bool
    /// Monotonic ring offsets, [start, end).
    var start: UInt64
    var end: UInt64
    var credits: Int
    var invalid: Bool
  }

  /// Bytes, a power of two from 4 KiB to 64 KiB.
  public let size: Int
  /// Monotonic, never wrapped; INSERT - EXTRACT never passes `size`.
  public private(set) var insert: UInt64 = 0
  /// The last output EXTRACT seen.
  public private(set) var extract: UInt64 = 0
  /// Fence numbers issued, from 1 per non-empty job.
  public private(set) var lastSequence: UInt64 = 0
  public private(set) var completedSequence: UInt64 = 0
  /// Instruction credits: size / 8, less what the jobs in flight hold.
  public private(set) var credits: Int
  var jobs: [Job] = []
  /// Whether a non-zero status has been attributed to a job already: the
  /// sync object keeps it until the next error.
  var statusHandled = false

  public init?(size: Int) {
    guard size >= 4096, size <= 65536, size & (size - 1) == 0 else { return nil }
    self.size = size
    credits = size / 8
  }

  public var inFlight: Int { jobs.count }

  /// Where the `index`th word of what is written at `at` lands in the ring
  /// (the copy wraps).
  public func byteOffset(at: UInt64, word index: Int) -> Int {
    Int((at &+ UInt64(index) &* 8) & UInt64(size - 1))
  }

  /// Note the CS's output EXTRACT (read when a group is suspended or its
  /// status updated).
  public mutating func observe(extract e: UInt64) {
    if e > extract && e <= insert { extract = e }
  }

  /// Take space and a fence number for a job of `words` instructions (a
  /// multiple of 8). Returns the monotonic INSERT it starts at, or nil
  /// when there are not the credits (07 section 7.4.2).
  public mutating func reserve(words: Int, tag: UInt64) -> (start: UInt64, sequence: UInt64)? {
    guard words > 0, words & 7 == 0, words <= credits else { return nil }
    credits -= words
    lastSequence += 1
    let start = insert
    insert += UInt64(words) * 8
    jobs.append(Job(tag: tag, sequence: lastSequence, isEmpty: false, start: start, end: insert,
                    credits: words, invalid: false))
    return (start, lastSequence)
  }

  /// A job with no stream: done when every earlier job is; the ring is
  /// left alone. Returns it finished when nothing is in flight, else nil
  /// and it waits.
  public mutating func reserveEmpty(tag: UInt64) -> FinishedJob? {
    if jobs.isEmpty {
      return FinishedJob(tag: tag, sequence: lastSequence, error: .none, isEmpty: true)
    }
    jobs.append(Job(tag: tag, sequence: lastSequence, isEmpty: true, start: insert, end: insert,
                    credits: 0, invalid: false))
    return nil
  }

  /// A CS fault: the job whose range holds EXTRACT is invalid (07 section
  /// 7.10.2). Returns whether one did.
  @discardableResult
  public mutating func fault(atExtract e: UInt64) -> Bool {
    for i in 0..<jobs.count where !jobs[i].isEmpty && jobs[i].start <= e && e < jobs[i].end {
      jobs[i].invalid = true
      statusHandled = true
      return true
    }
    return false
  }

  /// Signal every job the sync object has reached (07 section 7.4.6), in
  /// order, and return its credits.
  ///
  /// [POLICY] A non-zero status with no job already marked by a fault
  /// marks the newest job this update finishes: the ERROR_BARRIER ends
  /// an error at its job, so it is the one the stream ran last.
  public mutating func complete(_ record: SyncRecord) -> [FinishedJob] {
    var done: [FinishedJob] = []
    var n = 0
    while n < jobs.count && jobs[n].sequence <= record.sequence { n += 1 }
    if n == 0 { return done }
    var marked = false
    for i in 0..<n where jobs[i].invalid { marked = true }
    let wasHandled = statusHandled
    if record.status == 0 {
      statusHandled = false
    } else if !statusHandled {
      statusHandled = true
    }
    if record.status != 0 && !marked && !wasHandled {
      var i = n - 1
      while i >= 0 {
        if !jobs[i].isEmpty {
          jobs[i].invalid = true
          break
        }
        i -= 1
      }
    }
    for i in 0..<n {
      let j = jobs[i]
      credits += j.credits
      done.append(FinishedJob(tag: j.tag, sequence: j.sequence, error: j.invalid ? .invalid : .none,
                              isEmpty: j.isEmpty))
    }
    jobs.removeFirst(n)
    if record.sequence > completedSequence && record.sequence <= lastSequence {
      completedSequence = record.sequence
    }
    return done
  }

  /// A group's end: every job in flight signals with `error`, except one
  /// a fault already marked; the credits all come back.
  public mutating func abort(error: FenceError) -> [FinishedJob] {
    var done: [FinishedJob] = []
    for j in jobs {
      credits += j.credits
      done.append(FinishedJob(tag: j.tag, sequence: j.sequence, error: j.invalid ? .invalid : error,
                              isEmpty: j.isEmpty))
    }
    jobs.removeAll()
    completedSequence = lastSequence
    return done
  }
}
