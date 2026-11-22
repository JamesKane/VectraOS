// SPDX-License-Identifier: BSD-3-Clause

// Where a compiled shader reads its inputs in the FAU block: data a compiler fills in and a dispatch
// reads, so MaliCore needs no compiler to build the block. The Valhall backend (graphics/compiler/valhall)
// makes it; its header says how the layout is chosen (valhall 14 section 14.7.3: "a different driver can
// choose a different layout if its compiler addresses it consistently").
//
// The order of the block, always:
//
//   1. one slot for each storage or uniform buffer the shader names (set and binding), in ascending
//      (set, binding) order: the buffer's 64-bit GPU address.
//   2. two slots for the number of workgroups (x, y, z, then a pad word), when the shader reads it.
//   3. the byte size of each buffer whose run-time array length the shader reads, one 32-bit word each,
//      in the order of (1), packed from the next slot.
//   3b. the heap handle of element 0 of each storage image binding the shader names, one 32-bit word each, in
//      ascending (set, binding) order.
//   4. the push constants: word n is the API push constant at byte offset 4n, for every word up to the
//      highest the shader reads.
//
// Slots 0 to 127 are reachable (4 pages of 32; valhall 10 section 10.5.3).

/// Where the FAU block holds what the shader reads (the order is in this file's header).
public struct FauLayout: Equatable, Sendable {
  public struct Binding: Equatable, Sendable {
    public var set: Int
    public var binding: Int
    /// The slot of the buffer's 64-bit address.
    public var slot: Int
    /// The 32-bit word of the buffer's byte size, or -1 when the shader reads no run-time array length from it.
    public var sizeWord: Int

    public init(set: Int, binding: Int, slot: Int, sizeWord: Int) {
      self.set = set
      self.binding = binding
      self.slot = slot
      self.sizeWord = sizeWord
    }
  }

  public var bindings: [Binding]
  /// The 32-bit words of the heap handles of the storage images the shader names (element 0 of each binding), in
  /// ascending (set, binding) order, after the size words and before the push constants.
  public var imageBindings: [ImageBinding] = []
  /// The word holding the handle of a sampler for the fetches of plain images (a compute shader's texture access), or -1.
  public var dummySamplerWord = -1
  /// The 32-bit word of the number of workgroups (x, y, z in three consecutive words), or -1.
  public var numWorkgroupsWord: Int
  /// The 32-bit word of push constant word 0, and how many push words the block carries.
  public var pushWord: Int
  public var pushWords: Int
  /// 32-bit words the block needs: the highest word named, plus one, rounded up to a whole slot.
  public var words: Int

  public init() {
    bindings = []
    numWorkgroupsWord = -1
    pushWord = 0
    pushWords = 0
    words = 0
  }

  /// The slots of a block: 64-bit words, as `ComputeDispatchRequest.fau` takes them.
  public var slots: Int { (words + 1) / 2 }

  /// The block for a dispatch: `address(set, binding)` and `size(set, binding)` give each buffer's GPU address and
  /// byte size; `push` the API's push constants (zero-extended or cut to the words the shader reads);
  /// `workgroups` the grid.
  public func block(
    address: (Int, Int) -> UInt64, size: (Int, Int) -> UInt32, push: [UInt32], workgroups: (UInt32, UInt32, UInt32),
    imageHandle: (Int, Int) -> UInt32 = { _, _ in 0 }, dummySampler: UInt32 = 0
  ) -> [UInt64] {
    var w = [UInt32](repeating: 0, count: slots * 2)
    for b in bindings {
      let a = address(b.set, b.binding)
      w[b.slot * 2] = UInt32(truncatingIfNeeded: a)
      w[b.slot * 2 + 1] = UInt32(truncatingIfNeeded: a >> 32)
      if b.sizeWord >= 0 { w[b.sizeWord] = size(b.set, b.binding) }
    }
    for b in imageBindings { w[b.word] = imageHandle(b.set, b.binding) }
    if dummySamplerWord >= 0 { w[dummySamplerWord] = dummySampler }
    if numWorkgroupsWord >= 0 {
      w[numWorkgroupsWord] = workgroups.0
      w[numWorkgroupsWord + 1] = workgroups.1
      w[numWorkgroupsWord + 2] = workgroups.2
    }
    var i = 0
    while i < pushWords {
      w[pushWord + i] = i < push.count ? push[i] : 0
      i += 1
    }
    var out: [UInt64] = []
    var s = 0
    while s < slots {
      out.append(UInt64(w[s * 2]) | UInt64(w[s * 2 + 1]) << 32)
      s += 1
    }
    return out
  }
}
