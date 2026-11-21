// SPDX-License-Identifier: BSD-3-Clause

// Texel buffer access over a test model (valhall 03 3.4.1, 3.5, 12a.5.2, 12a.7, 12b.14): LEA_BUF and LD_CVT, and the
// conversion words ST_CVT is given.
//
//  - `LEA_BUF`: the element's address, `Address + element * Stride`, of the Buffer descriptor the handle names
//    (`DispatchConfig.bufferDescriptor`, a test model: the hardware reads the resource table). Whether it checks the element
//    against the size, and what it returns past it, is open (12a.5.2): the model does not check, and a test reads inside.
//  - `LD_CVT`: reads the element at its address in the format the conversion word names and writes the first `n` channels
//    (the vector size plus one) in the register format (`f32`, `u32` or `s32`; the 16-bit forms are not modelled). The
//    conversion word is the 22-bit pixel format of 05 5.2.1: the component order `[11:0]`, the format index `[19:12]`, sRGB
//    `[20]`. The channels a format lacks come from the component order (05 5.2.3: one component reads (R, 0, 0, 1), two
//    (R, G, 0, 1)), which is the inference of 12b.14.1 that the board test checks; the model follows it.
//  - `ST_CVT` with such a word: `auto32`, the channels' register bits read as the format's own kind (float for the unorm,
//    snorm and float formats, unsigned or signed for the integer ones); an integer above the format's range is saturated
//    (12b.10.4 leaves wrap or saturate open); a block with fewer channels than the format has writes zero for the rest.
//
// The formats are the numeric families of 05 5.2.2 (8, 16 and 32 bits a component, one to four components: unorm, snorm,
// uint, sint, and float at 16 and 32 bits), RGB10 A2 UNORM (67), and the constant format (95). A word of another format, or with the
// sRGB bit, is a fault: the model does not convert it. The words of 12b.12 the model leaves to `StorageFormat`'s codes (the image
// model's: format index 0) take the image path.

/// A Buffer descriptor (03 3.4) as the model has it: where the buffer is, its size in bytes, the element size, and the word 7
/// conversion (the compiler's accesses read that word through `descriptorWord`).
public struct BufferDescriptorModel: Sendable {
  public var base: UInt64
  public var size: UInt64
  public var stride: UInt32
  public var conversion: UInt32

  public init(base: UInt64, size: UInt64, stride: UInt32, conversion: UInt32) {
    self.base = base
    self.size = size
    self.stride = stride
    self.conversion = conversion
  }

  /// The descriptor's 32-bit words (03 3.4.1; arch 11 and later keep the size's high half in word 5).
  public var words: [UInt32] {
    [
      9 | 3 << 4, UInt32(truncatingIfNeeded: size), UInt32(truncatingIfNeeded: base), UInt32(truncatingIfNeeded: base >> 32), stride,
      UInt32(truncatingIfNeeded: size >> 32), 0, conversion,
    ]
  }
}

/// The 22-bit pixel format word (05 5.2.1) of the formats the model converts.
public enum PixelWord {
  public enum Kind: Sendable { case unorm, snorm, uint, sint, float }

  /// The format the word names: its kind, components, bits a component, and the component order; nil for the constant format
  /// (every channel from the order) and a fault for what the model doesn't convert.
  struct Layout {
    var kind: Kind
    var components: Int
    var bits: Int
    var order: Int
    var constant: Bool
    /// Bytes of one texel.
    var bytes: Int { constant ? 0 : kind == .unorm && bits == 10 ? 4 : components * bits / 8 }
  }

  /// A word's index and order.
  public static func make(index: Int, order: Int, srgb: Bool = false) -> UInt32 {
    UInt32(order) | UInt32(index) << 12 | (srgb ? 1 << 20 : 0)
  }

  static func layout(_ word: UInt32) throws -> Layout {
    let order = Int(word & 0xFFF)
    let index = Int(word >> 12 & 0xFF)
    guard word >> 20 & 1 == 0 else { throw Fault.invalid("the conversion word \(word) has the sRGB bit: the model doesn't convert it") }
    if index == 95 { return Layout(kind: .unorm, components: 0, bits: 0, order: order, constant: true) }
    if index == 67 { return Layout(kind: .unorm, components: 4, bits: 10, order: order, constant: false) }
    guard index >= 96 else { throw Fault.invalid("the pixel format index \(index) of conversion word \(word) is not modelled") }
    let group = index & ~31
    let components = (index >> 3 & 3) + 1
    let slot = index & 7
    let kind: Kind
    var bits: Int
    switch slot {
    case 3: bits = 8
    case 4: bits = 16
    case 5: bits = 32
    case 7: bits = group == 160 ? 32 : 16
    default: throw Fault.invalid("the pixel format index \(index) is not modelled")
    }
    switch group {
    case 96: kind = .snorm
    case 128: kind = .uint
    case 160: kind = slot == 7 ? .float : .unorm
    case 192: kind = slot == 7 ? .float : .sint
    default: throw Fault.invalid("the pixel format index \(index) is not modelled")
    }
    if bits == 32 && (kind == .unorm || kind == .snorm) { throw Fault.invalid("32-bit normalised formats are for vertex data only (05 5.2.2)") }
    if slot == 7 && group == 192 { bits = 16 }
    return Layout(kind: kind, components: components, bits: bits, order: order, constant: false)
  }

  /// For each stored position, the logical channel (0 R, 1 G, 2 B, 3 A) it holds, or nil where it is ignored (05 5.2.3).
  static func stored(_ order: Int) -> [Int?] {
    guard order <= 28 else { return [0, 1, 2, 3] }
    let rgb: [Int] = [[0, 1, 2], [1, 0, 2], [2, 1, 0]][min(order >> 1 & 3, 2)]
    switch order >> 3 & 3 {
    case 0: return [rgb[0], rgb[1], rgb[2], 3]
    case 1: return [3, rgb[0], rgb[1], rgb[2]]
    case 2: return [rgb[0], rgb[1], rgb[2], nil]
    default: return [nil, rgb[0], rgb[1], rgb[2]]
    }
  }

  /// A texel's channels as register bits of the register format (0 f32, 1 u32, 2 s32), from its bytes.
  static func decode(_ word: UInt32, _ bytes: [UInt8], register: Int, channels n: Int) throws -> [UInt32] {
    let l = try layout(word)
    let one: UInt32 = register == 0 ? Float(1).bitPattern : 1
    var logical = [UInt32](repeating: 0, count: 4)
    if l.order >= 226 {
      // Orders that replicate or constant: R from the first component, A from the first or the second.
      let first = l.constant ? nil : try component(l, bytes, 0, register)
      let second = l.constant || l.components < 2 ? nil : try component(l, bytes, 1, register)
      switch l.order {
      case 226: logical = [UInt32](repeating: first ?? 0, count: 4)
      case 227: logical = [first ?? 0, first ?? 0, first ?? 0, one]
      case 228: logical = [first ?? 0, first ?? 0, first ?? 0, second ?? 0]
      case 229: logical = [0, 0, 0, first ?? 0]
      case 230: logical = [0, 0, 0, one]
      case 231: logical = [0, 0, 0, 0]
      default: throw Fault.invalid("the component order \(l.order) is not modelled")
      }
    } else {
      logical = [0, 0, 0, one]
      if l.bits == 10 {
        // RGB10 A2: R in the low ten bits, then G, B, and A in the top two.
        var raw: UInt32 = 0
        for k in 0..<4 { raw |= UInt32(bytes[k]) << UInt32(8 * k) }
        let values: [UInt32] = [raw & 0x3FF, raw >> 10 & 0x3FF, raw >> 20 & 0x3FF, raw >> 30]
        let top: [Float] = [1023, 1023, 1023, 3]
        let layout = stored(l.order)
        for (p, c) in layout.enumerated() where c != nil && p < 4 {
          let v = values[p]
          logical[c!] = register == 0 ? (Float(v) / top[p]).bitPattern : v
        }
      } else {
        let layout = stored(l.order)
        for (p, c) in layout.enumerated() {
          guard let c, p < l.components else { continue }
          logical[c] = try component(l, bytes, p, register)
        }
      }
    }
    return Array(logical.prefix(n))
  }

  private static func component(_ l: Layout, _ b: [UInt8], _ k: Int, _ register: Int) throws -> UInt32 {
    var raw: UInt64 = 0
    let size = l.bits / 8
    for i in 0..<size { raw |= UInt64(b[k * size + i]) << UInt64(8 * i) }
    func signed(_ v: UInt64) -> Int64 {
      let shift = UInt64(64 - l.bits)
      return Int64(bitPattern: v << shift) >> Int64(shift)
    }
    switch l.kind {
    case .float:
      let f: Float = l.bits == 32 ? Float(bitPattern: UInt32(raw)) : Float(FPFormat.f16.decode(UInt32(raw)))
      return register == 0 ? f.bitPattern : register == 1 ? UInt32(max(0, min(f, 4.2e9))) : UInt32(bitPattern: Int32(max(-2.1e9, min(f, 2.1e9))))
    case .unorm:
      let max = Float(UInt64(1) << UInt64(l.bits) - 1)
      return register == 0 ? (Float(raw) / max).bitPattern : UInt32(truncatingIfNeeded: raw)
    case .snorm:
      let max = Float((UInt64(1) << UInt64(l.bits - 1)) - 1)
      return register == 0 ? Swift.max(Float(signed(raw)) / max, -1).bitPattern : UInt32(bitPattern: Int32(truncatingIfNeeded: signed(raw)))
    case .uint:
      return register == 0 ? Float(raw).bitPattern : UInt32(truncatingIfNeeded: raw)
    case .sint:
      return register == 0 ? Float(signed(raw)).bitPattern : UInt32(bitPattern: Int32(truncatingIfNeeded: signed(raw)))
    }
  }

  /// The bytes of a texel from a block of channels (R, G, B, A in order, as `auto32` register bits), in the word's format.
  static func encode(_ word: UInt32, _ block: [UInt32]) throws -> [UInt8] {
    let l = try layout(word)
    if l.constant { return [] }
    func channel(_ c: Int) -> UInt32 { c < block.count ? block[c] : 0 }
    let layout = stored(l.order)
    if l.bits == 10 {
      let top: [Float] = [1023, 1023, 1023, 3]
      var raw: UInt32 = 0
      var shift: UInt32 = 0
      for p in 0..<4 {
        let width: UInt32 = p == 3 ? 2 : 10
        var v: UInt32 = 0
        if let c = layout[p] {
          let x = Float(bitPattern: channel(c))
          v = x.isNaN ? 0 : UInt32(min(max((x * top[p]).rounded(.toNearestOrEven), 0), top[p]))
        }
        raw |= v << shift
        shift += width
      }
      return (0..<4).map { UInt8(truncatingIfNeeded: raw >> UInt32(8 * $0)) }
    }
    var out: [UInt8] = []
    for p in 0..<l.components {
      var bits: UInt32 = 0
      if p < layout.count, let c = layout[p] { bits = channel(c) }
      let v = try pack(l, bits)
      for i in 0..<l.bits / 8 { out.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i))) }
    }
    return out
  }

  private static func pack(_ l: Layout, _ bits: UInt32) throws -> UInt64 {
    let x = Float(bitPattern: bits)
    switch l.kind {
    case .float:
      return l.bits == 32 ? UInt64(bits) : UInt64(FPFormat.f16.encode(Double(x), .nearestEven))
    case .unorm:
      let max = Float(UInt64(1) << UInt64(l.bits) - 1)
      return x.isNaN ? 0 : UInt64(Swift.min(Swift.max((x * max).rounded(.toNearestOrEven), 0), max))
    case .snorm:
      let max = Float((UInt64(1) << UInt64(l.bits - 1)) - 1)
      let v = x.isNaN ? 0 : Int64(Swift.min(Swift.max((x * max).rounded(.toNearestOrEven), -max), max))
      return UInt64(bitPattern: v) & ((UInt64(1) << UInt64(l.bits)) - 1)
    case .uint:
      return Swift.min(UInt64(bits), (UInt64(1) << UInt64(l.bits)) - 1)
    case .sint:
      let hi = (Int64(1) << Int64(l.bits - 1)) - 1
      let v = Swift.min(Swift.max(Int64(Int32(bitPattern: bits)), -hi - 1), hi)
      return UInt64(bitPattern: v) & ((UInt64(1) << UInt64(l.bits)) - 1)
    }
  }
}

extension Executor {
  /// LEA_BUF.
  func leaBuf(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    guard let model = cfg.bufferDescriptor else { throw Fault.invalid("LEA_BUF: the run has no buffer descriptor model") }
    let element = UInt64(try src32(w, lane, ins, ins.s0))
    let handle = try src32(w, lane, ins, ins.s1)
    guard let d = model(handle) else { throw Fault.invalid("LEA_BUF: handle \(handle) names no buffer of the model") }
    let a = d.base &+ element &* UInt64(d.stride)
    try issueResult(w, lane, first: Int(ins.dst), [UInt32(truncatingIfNeeded: a), UInt32(truncatingIfNeeded: a >> 32)], slot: Int(ins.slot))
  }

  /// LD_CVT.
  func loadConverted(_ w: Warp, _ lane: Int, _ ins: Instr) throws {
    let addr = try address(w, lane, ins)
    let conv = try src32(w, lane, ins, ins.s2)
    let n = Int(ins.imm)
    // The register format: f32 2, s32 4, u32 6 (12a.7; auto32 0 is for stores).
    let register: Int
    switch ins.special {
    case 2: register = 0
    case 6: register = 1
    case 4: register = 2
    default: throw Fault.invalid("LD_CVT: register format \(ins.special) is not modelled (f32, u32 and s32 are)")
    }
    var out = [UInt32](repeating: 0, count: n)
    if !isDiscarded(w, lane) || ins.access == 3 {
      let layout = try PixelWord.layout(conv)
      let bytes = try layout.constant ? [] : readMem(addr, layout.bytes)
      out = try PixelWord.decode(conv, bytes, register: register, channels: n)
    }
    try issueResult(w, lane, first: Int(ins.dst), out, slot: Int(ins.slot))
  }
}
