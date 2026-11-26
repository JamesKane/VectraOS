// SPDX-License-Identifier: BSD-3-Clause

// The streams of queries (valhall 01 section 1.7 and 02 section 2.8): a timestamp is STORE_STATE of the system timestamp
// (state 0, a 64-bit value that counts at the system timer's frequency, panthor 03 section 3.10) to an address, once
// the stream has drained the work before it. An occlusion query has no stream of its own: its counter is the `OQ`
// register of the draws (PassDraw.occlusionQuery).

public enum TimestampStream {
  /// The stream of the timestamps stored at each of `addresses` in order: the work before it is waited for (every slot),
  /// each store is waited for, and the caches are cleaned for the CPU (02 section 2.9.1's tail).
  public static func build(
    at base: UInt64, capacity: Int, addresses: [UInt64], initialiseQueue: Bool, registers: CSRegisterMap,
    scoreboards: CSScoreboards, chain: StepChain? = nil
  ) throws(CSBuildError) -> CSStream {
    var b = CSBuilder(address: base, capacityBytes: capacity, registers: registers, scoreboards: scoreboards)
    if initialiseQueue { b.initialiseSlotState() }
    b.startStep(chain)
    b.waitAll()
    for a in addresses {
      b.move64(CSRegisterMap.firstScratch, a)
      b.emit(CSInstruction.storeState(address: CSRegisterMap.firstScratch, state: .timestamp))
      b.wait(mask: scoreboards.slotMask(CSScoreboards.loadStoreSlot))
    }
    b.waitAll()
    b.cleanCachesForHost()
    b.endStep(chain)
    return try b.finish()
  }
}
