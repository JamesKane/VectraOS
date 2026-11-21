// SPDX-License-Identifier: BSD-3-Clause

// The rewrite itself (D174 step 5): a Vulkan program's SPIR-V into the
// core's interface, against a `LoweringLayout` (Layout.swift).

/// `spirv` (words) rewritten for the core: its descriptor sets, push constants and (for a vertex stage) vertex
/// inputs read through the root block; the heap's arrays at set 0, bindings 0 to 2; the core's push-constant block,
/// the root, in place of the program's.
public func lower(spirv: [UInt32], stage: ShaderStage, entryPoint: String, layout: LoweringLayout)
  throws(LoweringError) -> [UInt32]
{
  throw .unsupported("the lowering is not written yet")
}
