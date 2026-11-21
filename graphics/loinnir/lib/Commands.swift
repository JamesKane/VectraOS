// SPDX-License-Identifier: BSD-3-Clause

// Recording (sdk.md §5): render passes with draws, and copies. The list is the
// core's (graphics/core): Loinnir records into it, and the backend moves each
// image to the layout the next command needs when it runs the list.

import GPUCore

@safe public struct CommandList: ~Copyable {
  let owner: Loinnir
  var core = GPUCommandList()

  init(owner: Loinnir) { self.owner = owner }

  /// Draws into `target`, cleared to `clear` first if given (else its contents are kept).
  public mutating func render(to target: RenderTarget, clear: (Float, Float, Float, Float)? = nil,
                              _ body: (inout RenderPass) -> Void) {
    guard let image = resolve(target) else { return }
    let load: LoadAction = if let clear { .clear(clear.0, clear.1, clear.2, clear.3) } else { .load }
    core.beginRendering(RenderingInfo(colors: [Attachment(image: image, load: load, store: .store)]))
    var pass = RenderPass()
    body(&pass)
    core.append(contentsOf: pass.recorded)
    core.endRendering()
  }

  /// Copies `from` (tightly packed pixels) into `texture`.
  public mutating func copy(_ from: GPUAllocation, to texture: Texture) {
    guard let image = owner.textures[texture.index] else { return }
    core.copy(from.memory, to: image)
  }

  /// Copies `texture`'s pixels into `to` (tightly packed), to read back.
  public mutating func copy(_ texture: Texture, to: GPUAllocation) {
    guard let image = owner.textures[texture.index] else { return }
    core.copy(image, to: to.memory)
  }

  func resolve(_ target: RenderTarget) -> GPUImage? {
    switch target {
    case .texture(let t): return owner.textures[t.index]
    case .backbuffer(let r): return r.image
    }
  }
}

/// Draws inside a render pass.
@safe public struct RenderPass {
  var recorded = GPUCommandList()

  /// Draws `vertices` (× `instances`) with `pipeline`. `root` is the one
  /// pointer the shaders get: the GPU address of whatever they read.
  /// Instances `firstInstance` on: a range of a batch (the UI Kit draws
  /// each clip's range under its own scissor).
  public mutating func draw(_ pipeline: Pipeline, root: UInt64, vertices: UInt32, instances: UInt32 = 1,
                            firstInstance: UInt32 = 0)
  {
    recorded.draw(pipeline.core, root: root, vertices: vertices, instances: instances, firstInstance: firstInstance)
  }

  /// Draws from here on only within the rectangle (pixels; the render
  /// pass sets the whole target).
  public mutating func scissor(x: Int32, y: Int32, width: UInt32, height: UInt32) {
    recorded.setScissor(x: x, y: y, width: width, height: height)
  }
}
