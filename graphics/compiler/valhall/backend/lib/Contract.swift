// SPDX-License-Identifier: BSD-3-Clause

// What the Valhall backend takes and gives (D174 section 3): the options, the
// errors, the compiled shader, and the FAU layout, which is the contract
// between the compiler and the driver that dispatches the shader.
//
// The FAU block is an array of 64-bit slots the shader reads through user FAU
// sources (valhall 10.5.3, 14.7). The compiler chooses where each value sits
// (14.7.3: "a different driver can choose a different layout if its compiler
// addresses it consistently"); `FauLayout` is the compiler's answer, and
// `FauLayout.block(...)` builds the block from it. The order, always:
//
//   1. one slot for each storage or uniform buffer the shader names (set and
//      binding), in ascending (set, binding) order: the buffer's 64-bit GPU
//      address. A shader of one buffer has its address in slot 0, as the
//      bring-up shader's does.
//   2. two slots for the number of workgroups (x, y, z, then a pad word),
//      when the shader reads it.
//   3. the byte size of each buffer whose run-time array length the shader
//      reads, one 32-bit word each, in the order of (1), packed from the
//      next slot.
//   4. the push constants, from the next slot: word n is the API push
//      constant at byte offset 4n, for every word up to the highest the
//      shader reads.
//
// Slots 0 to 127 are reachable (4 pages of 32; 10.5.3). A shader that needs
// more is refused (`fauOverflow`).

import MaliCore
import ShaderCompiler
import ValhallISA

public enum BackendError: Error, Equatable {
  /// The IR or the SPIR-V behind it holds something the backend does not select (the text says what).
  case unsupported(String)
  /// The IR is malformed, or the shader breaks a rule the backend relies on.
  case invalidIR(String)
  /// More values live at once than the registers hold, and spilling could not help.
  case outOfRegisters
  /// The FAU layout needs more than 128 slots.
  case fauOverflow
  /// Stack or spill slots past what a 16-bit offset reaches.
  case stackOverflow
  /// A bug: a rule of the ISA validator broke on the backend's own output (the first violation's text).
  case invalidOutput(String)
  /// Front-end errors, with the front end's text.
  case frontEnd(String)
}

public struct BackendOptions: Sendable {
  /// The arch major to compile for (valhall 17 for 14; 12 is the Immortalis-G720's).
  public var arch: Int
  /// Allocate in class 32 when the shader fits (valhall 15.2.3); false: always class 64.
  public var preferClass32: Bool
  /// Allocate no more than this many registers, in allocation order, to force spills in tests (nil: all).
  public var registerLimit: Int?
  /// The SPD's flush-to-zero mode the shader will run with (valhall 04.2.4).
  public var flushToZeroMode: UInt32
  /// Run the ISA validator over the output and fail with `invalidOutput` when a rule breaks.
  public var validate: Bool

  public init(
    arch: Int = 12, preferClass32: Bool = true, registerLimit: Int? = nil, flushToZeroMode: UInt32 = 0, validate: Bool = true
  ) {
    self.arch = arch
    self.preferClass32 = preferClass32
    self.registerLimit = registerLimit
    self.flushToZeroMode = flushToZeroMode
    self.validate = validate
  }
}

/// Where the FAU block holds what the shader reads (the order is in this file's header).
public struct FauLayout: Equatable, Sendable {
  public struct Binding: Equatable, Sendable {
    public var set: Int
    public var binding: Int
    /// The slot of the buffer's 64-bit address.
    public var slot: Int
    /// The 32-bit word of the buffer's byte size, or -1 when the shader reads no run-time array length from it.
    public var sizeWord: Int
  }

  public var bindings: [Binding]
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
    address: (Int, Int) -> UInt64, size: (Int, Int) -> UInt32, push: [UInt32], workgroups: (UInt32, UInt32, UInt32)
  ) -> [UInt64] {
    var w = [UInt32](repeating: 0, count: slots * 2)
    for b in bindings {
      let a = address(b.set, b.binding)
      w[b.slot * 2] = UInt32(truncatingIfNeeded: a)
      w[b.slot * 2 + 1] = UInt32(truncatingIfNeeded: a >> 32)
      if b.sizeWord >= 0 { w[b.sizeWord] = size(b.set, b.binding) }
    }
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

/// A shader the backend made.
public struct CompiledShader: Sendable {
  /// What MaliCore dispatches.
  public var shader: ComputeShader
  public var layout: FauLayout
  /// The instructions the words encode, for tests and listings.
  public var instructions: [Instruction]
  /// Registers the allocation used (the highest number plus one) and the spill slots it made.
  public var registersUsed: Int
  public var spillSlots: Int

  /// The listing, one instruction a line (valhall 10.14).
  public var listing: String {
    var s = ""
    for i in instructions {
      s += ISATable.shared.disassemble(i) + "\n"
    }
    return s
  }
}
