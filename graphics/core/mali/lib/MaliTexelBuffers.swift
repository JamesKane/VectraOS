// SPDX-License-Identifier: BSD-3-Clause

// The heap's texel buffers on Mali (D174; gpucore(2), malicore(2); valhall 03 3.2.4, 3.4.1, 3.5 and 12b.14).
//
// A texel buffer is one Buffer descriptor (type 9, buffer type 3, 32 bytes) in the same resource table as the storage images, table
// 2: the images take slots 0 to 1023 of it, the uniform texel buffers (the heap's binding 3) the next 1024 and the storage texel
// buffers (binding 4) the 1024 after, so a binding's handle is `handle(table: 2, index: base)` and element `j` of its array is
// that plus `j` (`Heap.storageBase`, `texelBufferBase` and `storageTexelBufferBase`). The descriptor's words are the address of
// the view's first texel, its range in bytes, the texel's size in bytes as the stride, and in word 7 the view format's 22-bit pixel
// format word, which a compiled shader reads (12b.14.1) and passes to `LD_CVT` and `ST_CVT`. The snapshot of table 2 a dispatch
// gets runs to the highest slot written, so the arrays a program does not use cost nothing.

import GPUCore

#if canImport(MaliCore)
  import MaliCore
#endif

extension PixelFormat {
  /// The pixel format word of 05 5.3.1 a texel buffer of the format is read and written in: the format index and the component
  /// order (a one-component format reads (R, 0, 0, 1), a two-component one (R, G, 0, 1): order RGB1), and the texel's size.
  /// nil for a format with no such word (depth and stencil, compressed, and the sRGB ones, which no texel buffer is).
  var texelBufferFormat: TexelFormat? {
    func f(_ index: UInt32, _ order: UInt32, _ bytes: Int) -> TexelFormat { TexelFormat(index: index, order: order, bytesPerTexel: bytes) }
    switch self {
    case .r8: return f(163, 16, 1)
    case .r8snorm: return f(99, 16, 1)
    case .r8uint: return f(131, 16, 1)
    case .r8sint: return f(195, 16, 1)
    case .rg8: return f(171, 16, 2)
    case .rg8snorm: return f(107, 16, 2)
    case .rg8uint: return f(139, 16, 2)
    case .rg8sint: return f(203, 16, 2)
    case .rgba8: return f(187, 0, 4)
    case .rgba8snorm: return f(123, 0, 4)
    case .rgba8uint: return f(155, 0, 4)
    case .rgba8sint: return f(219, 0, 4)
    case .bgra8: return f(187, 4, 4)
    case .r16float: return f(199, 16, 2)
    case .r16uint: return f(132, 16, 2)
    case .r16sint: return f(196, 16, 2)
    case .rg16float: return f(207, 16, 4)
    case .rg16uint: return f(140, 16, 4)
    case .rg16sint: return f(204, 16, 4)
    case .rgba16float: return f(223, 0, 8)
    case .rgba16uint: return f(156, 0, 8)
    case .rgba16sint: return f(220, 0, 8)
    case .r32float: return f(167, 16, 4)
    case .r32uint: return f(133, 16, 4)
    case .r32sint: return f(197, 16, 4)
    case .rg32float: return f(175, 16, 8)
    case .rg32uint: return f(141, 16, 8)
    case .rg32sint: return f(205, 16, 8)
    case .rgba32float: return f(191, 0, 16)
    case .rgba32uint: return f(157, 0, 16)
    case .rgba32sint: return f(221, 0, 16)
    case .rgb10a2unorm: return f(67, 0, 4)
    case .rg11b10float: return f(89, 16, 4)
    case .rgb9e5: return f(91, 16, 4)
    default: return nil
    }
  }

  /// What a texel buffer of the format may be (valhall 05 5.3.7: the formats of the storage and texel-buffer column), with atomics on the
  /// 32-bit one-channel integers, which the compiler takes (a view is of a client's memory, mapped cacheable for the GPU).
  var texelBufferCapabilities: (uniform: Bool, storage: Bool, atomic: Bool)? {
    guard texelBufferFormat != nil else { return nil }
    return (true, true, self == .r32uint || self == .r32sint)
  }
}

extension MaliDevice {
  /// Puts a uniform texel buffer in slot `index` of the heap's binding 3 (table 2, from `Heap.texelBufferBase`).
  public func writeTexelBuffer(_ index: UInt32, _ view: BufferView) throws(GPUError) {
    guard index < UInt32(Heap.texelBufferSlots) else { throw .invalid("texel buffer slot \(index)") }
    if let e = view.check(for: .uniform, limits: baseLimits) { throw e }
    try putBufferDescriptor(Heap.texelBufferBase + Int(index), view)
  }

  /// Puts a storage texel buffer in slot `index` of the heap's binding 4 (table 2, from `Heap.storageTexelBufferBase`).
  public func writeStorageTexelBuffer(_ index: UInt32, _ view: BufferView) throws(GPUError) {
    guard index < UInt32(Heap.storageTexelBufferSlots) else { throw .invalid("storage texel buffer slot \(index)") }
    if let e = view.check(for: .storage, limits: baseLimits) { throw e }
    try putBufferDescriptor(Heap.storageTexelBufferBase + Int(index), view)
  }

  func putBufferDescriptor(_ slot: Int, _ view: BufferView) throws(GPUError) {
    guard memories[view.memory.handle] != nil else { throw .invalid("memory that isn't this device's") }
    guard let format = view.format.texelBufferFormat else { throw .unsupported("a texel buffer of \(view.format)") }
    var d = BufferDescriptor(
      kind: .structure, address: view.memory.address + UInt64(view.offset), byteSize: UInt64(view.range),
      stride: UInt32(format.bytesPerTexel))
    d.conversion = format.word
    let words = d.words(arch: transport.info.arch)
    let first = slot * Heap.entryWords
    if storageWords.count < first + Heap.entryWords {
      storageWords.append(contentsOf: [UInt32](repeating: 0, count: first + Heap.entryWords - storageWords.count))
    }
    for (i, w) in words.enumerated() { storageWords[first + i] = w }
  }

  func enableTexelBuffers() {
    baseLimits.features.uniformTexelBuffers = true
    baseLimits.features.storageTexelBuffers = true
    baseLimits.heapTexelBuffers = UInt32(Heap.texelBufferSlots)
    baseLimits.heapStorageTexelBuffers = UInt32(Heap.storageTexelBufferSlots)
    baseLimits.maxTexelBufferElements = 1 << 27
    for f in PixelFormat.all {
      guard let c = f.texelBufferCapabilities else { continue }
      var caps = baseLimits.formats(f)
      caps.texelBuffer = c.uniform
      caps.storageTexelBuffer = c.storage
      caps.storageTexelBufferAtomic = c.atomic
      baseLimits.setFormat(f, caps)
    }
  }
}
