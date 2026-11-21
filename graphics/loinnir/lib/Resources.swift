// SPDX-License-Identifier: BSD-3-Clause

// Loinnir's resources (sdk.md §5): memory reached by GPU address, and
// textures as indices into one global bindless heap. There are no vertex
// buffers or descriptor sets to manage: a draw gets one root pointer, and
// shaders read everything else through it.

import GPUCore

/// Where an allocation lives.
public enum MemoryKind: Sendable {
  /// CPU-written, GPU-read: per-frame data, uploads.
  case upload
  /// GPU-only: the fastest for the GPU.
  case device
  /// GPU-written, CPU-read: results to inspect.
  case readback

  var core: MemoryIntent {
    switch self {
    case .upload: .upload
    case .device: .device
    case .readback: .readback
    }
  }
}

/// GPU memory, with its address for shaders and, where the CPU can map it,
/// a pointer.
@safe public struct GPUAllocation: @unchecked Sendable {
  public let address: UInt64
  public let pointer: UnsafeMutableRawPointer?
  public let size: Int
  let memory: GPUMemory

  init(_ memory: GPUMemory) {
    address = memory.address
    unsafe pointer = unsafe memory.pointer
    size = memory.size
    self.memory = memory
  }
}

public enum TextureFormat: Sendable {
  case rgba8, bgra8, r8
  /// bgra8 whose bytes are sRGB: sampled and blended in light (D110).
  case bgra8srgb

  var core: PixelFormat {
    switch self {
    case .rgba8: .rgba8
    case .bgra8: .bgra8
    case .bgra8srgb: .bgra8srgb
    case .r8: .r8
    }
  }
  var bytesPerPixel: Int { self == .r8 ? 1 : 4 }
}

/// A texture: `index` is its place in the heap, which shaders use.
public struct Texture: Hashable, Sendable {
  public let index: UInt32
  public let width: Int32
  public let height: Int32
  public let format: TextureFormat
}

extension Loinnir {
  /// Frees a texture once the GPU is past the work submitted so far; its
  /// heap index can then be another's.
  public func free(_ texture: Texture) {
    guard let image = textures[texture.index] else { return }
    textures[texture.index] = nil
    core.destroy(image)
    retiredSlots.append((timelineValue, texture.index))
    reclaim()
  }

  /// Frees memory once the GPU is past the work submitted so far.
  public func free(_ allocation: GPUAllocation) {
    core.free(allocation.memory)
    reclaim()
  }

  /// `bytes` of memory of `kind`, with its GPU address.
  public func alloc(_ kind: MemoryKind, bytes: Int) throws(LoinnirError) -> GPUAllocation {
    do { return GPUAllocation(try core.allocate(kind.core, bytes: bytes)) } catch { throw LoinnirError(error) }
  }

  /// A texture of `format`, in the heap. With `renderTarget`, it can also
  /// be rendered into (`render(to: .texture(t))`). `sampled: false` makes one a shader never reads
  /// (a target to draw into and copy out of): it has no heap slot, and a GPU whose driver can't sample yet
  /// still makes it.
  public func texture(_ format: TextureFormat, width: Int32, height: Int32, renderTarget: Bool = false,
                      sampled: Bool = true) throws(LoinnirError) -> Texture {
    if sampled && !core.limits.features.sampledImages {
      throw .unsupported("\(core.name)'s driver (\(core.backend)) has no sampled images yet")
    }
    var usage: ImageUsage = .copySource | .copyDestination
    if sampled { usage = usage | .sampled }
    if renderTarget { usage = usage | .renderTarget }
    // A target that is drawn into and copied out of (no shader reads it) is never copied into: a driver may then map it
    // for the CPU to read, and keep its cache in step.
    if renderTarget && !sampled { usage = .copySource | .renderTarget }
    let image: GPUImage
    do { image = try core.makeImage(ImageDescriptor(format: format.core, width: width, height: height, usage: usage)) } catch {
      throw LoinnirError(error)
    }
    reclaim()
    guard sampled else {
      // Unsampled: it has an index, as every texture does, but nothing is written to the heap there.
      let slot = takeSlot()
      textures[slot] = image
      return Texture(index: slot, width: width, height: height, format: format)
    }
    let slot = takeSlot()
    guard slot < core.limits.heapTextures else {
      freeSlots.append(slot)
      core.destroy(image)
      throw .unsupported("the texture heap is full")
    }
    do { try core.writeTexture(slot, image) } catch {
      freeSlots.append(slot)
      core.destroy(image)
      throw LoinnirError(error)
    }
    textures[slot] = image
    return Texture(index: slot, width: width, height: height, format: format)
  }

  func takeSlot() -> UInt32 {
    if let reused = freeSlots.popLast() { return reused }
    defer { nextSlot += 1 }
    return nextSlot
  }
}
