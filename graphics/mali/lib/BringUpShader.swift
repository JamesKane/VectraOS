// SPDX-License-Identifier: BSD-3-Clause

// A compute shader written by hand, for the board before the compiler exists:
// each invocation stores its global invocation id (x) at index x of a buffer
// whose address is the first FAU slot. It is two instructions, each derived
// from valhall's encoding tables (10, 11b, 12a, 13) field by field in
// `BringUpShader.words`; graphics/mali/tests checks the composer against
// every literal word the spec prints for the same instructions.
//
//   r60            global invocation id x (preloaded: mask bit 12; 14 section 14.2.1)
//   u0             FAU slot 0: the output buffer's 64-bit address
//
//   SHADD.u64 [r0:r1], u0, [r60:r61].w0, shift:2    ; r0:r1 = buffer + (id << 2)
//   STORE.i32.slot0.end @r60, [r0:r1], offset:0     ; *(u32 *)(r0:r1) = id, then end
//
// The register class is 64 (r0 to r63): 04 section 4.3 and 14 section 14.1.2
// disagree on whether a class 32 shader may name r60, and class 64 is right
// under both. The shader has no divergence, so no instruction carries
// `reconverge`; the STORE carries `end` (13 section 13.6.6: valid with the
// store outstanding).

public enum BringUpShader {
  // MARK: The 64-bit instruction word (10 section 10.2.1)

  /// flow [62:59], FAU page [58:57], class [56:52], opcode 1 [51:48], destination width / staging
  /// control [47:46], destination / staging register [45:40], low 40 bits class-specific.
  static func word(flow: UInt64 = 0, page: UInt64 = 0, class cls: UInt64, opcode1: UInt64, control: UInt64,
                   register: UInt64, low: UInt64) -> UInt64 {
    flow << 59 | page << 57 | cls << 52 | opcode1 << 48 | control << 46 | register << 40 | low
  }

  /// Source byte (10 section 10.5.1): `00` register, bit 6 last use; `10` user FAU, slot in [5:1], word in [0].
  public static func registerSource(_ r: Int, lastUse: Bool = false) -> UInt64 { (lastUse ? 0x40 : 0) | UInt64(r & 0x3F) }
  public static func fauSource(slot: Int, word: Int = 0) -> UInt64 { 0x80 | UInt64(slot & 0x1F) << 1 | UInt64(word & 1) }

  /// SHADD.u64 D, S0, S1.widen, shift:N (11b section 11b.3.5): class D2 = 26, data type u64 = 3 in
  /// opcode 1, opcode 2 = 7 at [19:16], shift at [22:20], widen of src1 at [29:26] (w0 = 8), destination
  /// width fixed 3.
  public static func shadd64(dst: Int, src0: UInt64, src1: UInt64, widenW0: Bool, shift: Int) -> UInt64 {
    word(class: 26, opcode1: 3, control: 3, register: UInt64(dst),
         low: (widenW0 ? 8 : 0) << 26 | UInt64(shift & 7) << 20 | 7 << 16 | src1 << 8 | src0)
  }

  /// STORE.i32.slot0 (12a section 12a.4): class S2 = 6, opcode 1 = 1, staging control read = 1, memory width
  /// i32 = 3 at [29:27], staging count 1 at [35:33], slot at [32:30], the address a 64-bit source in [7:0],
  /// the 16-bit signed offset at [23:8].
  public static func store(
    width: UInt64, count: UInt64, data: Int, address: UInt64, offset: Int16 = 0, slot: Int = 0, flow: UInt64 = 0
  ) -> UInt64 {
    word(flow: flow, class: 6, opcode1: 1, control: 1, register: UInt64(data),
         low: count << 33 | UInt64(slot & 7) << 30 | width << 27 | UInt64(UInt16(bitPattern: offset)) << 8 | address)
  }
  public static func storeI32(data: Int, address: UInt64, offset: Int16 = 0, slot: Int = 0, flow: UInt64 = 0) -> UInt64 {
    store(width: 3, count: 1, data: data, address: address, offset: offset, slot: slot, flow: flow)
  }

  /// The flow value `end` (10 section 10.9.2).
  public static let flowEnd: UInt64 = 15

  // MARK: The shader

  /// The preload mask: r60, the global invocation id x, is bit 12.
  public static let preloadMask: UInt16 = 1 << 12

  /// `SHADD.u64 [r0:r1], u0, [r60:r61].w0, shift:2`: 0x01A3_C000_2027_3C80. Derivation: class 26 at
  /// [56:52] and u64's 3 at [51:48] give 0x01A3 in the top 16 bits; the destination width 3 at [47:46] and
  /// destination r0 at [45:40] give 0xC000; shift 2 at [22:20] and opcode 2 = 7 at [19:16] give 0x27 at
  /// bits [23:16]; widen w0 = 8 at [29:26] gives 0x2000_0000; src1 = r60 = 0x3C at [15:8]; src0 = FAU slot
  /// 0, word 0 = 0x80 at [7:0]. The same instruction with slot 1 as src0 is the spec's printed example
  /// 0x01A3_C000_2027_3C82.
  public static var addressWord: UInt64 {
    shadd64(dst: 0, src0: fauSource(slot: 0), src1: registerSource(60), widenW0: true, shift: 2)
  }

  /// `STORE.i32.slot0.end @r60, [r0:r1], offset:0`: 0x7861_7C02_1800_0000. Derivation: flow `end` = 15 at
  /// [62:59] gives 0x7800; class 6 at [56:52] and opcode 1 = 1 at [51:48] give 0x0061; staging control
  /// `read` = 1 at [47:46] gives 0x4000 and the staging register r60 = 0x3C at [45:40] gives 0x3C00, so
  /// bits [47:32] are 0x7C00 before the count; staging count 1 at [35:33] gives 0x0002, so 0x7C02; memory
  /// width i32 = 3 at [29:27] gives 0x1800_0000; slot 0 at [32:30]; offset 0; src0 = the pair r0 = 0x00.
  /// The spec prints `STORE.i128.slot0.end @r4:..:r7, [r0^:r1^]` as 0x7861_4408_3800_0040, built the same way.
  public static var storeWord: UInt64 {
    storeI32(data: 60, address: registerSource(0), flow: flowEnd)
  }

  public static var words: [UInt64] { [addressWord, storeWord] }

  /// The shader as the compiler's contract has it: workgroup size 16 x 1 x 1 (one warp), a FAU of one
  /// 64-bit word, no stack, no workgroup memory.
  public static func globalIDStore(workgroupSize: Dim3 = Dim3(16)) -> ComputeShader {
    ComputeShader(code: words, registerClass: .r64, preloadMask: preloadMask, workgroupSize: workgroupSize,
                  stackBytes: 0, workgroupMemoryBytes: 0, fauWords: 2, allowsWorkgroupMerging: false)
  }
}
