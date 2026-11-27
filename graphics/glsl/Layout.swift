// SPDX-License-Identifier: BSD-3-Clause

// std140, the uniform block's layout (the OpenGL ES 3.0 specification's section 2.12.6.4, which GL ES 2.0's uniforms
// take here as one block): a scalar 4 bytes, a vec2 8, a vec3 and a vec4 16 (a vec3 12 long); a matrix its columns,
// 16 bytes apart; an array's elements 16-byte aligned at least; a structure 16-byte aligned, its size a multiple of it.

extension Program {
  /// std140's alignment and size of a type (samplers take no room).
  func std140(_ t: GType) -> (align: Int, size: Int) {
    if t.isArray {
      let e = std140(t.element)
      let stride = roundUp(e.size, max(e.align, 16))
      return (max(e.align, 16), stride * t.arraySize)
    }
    if t.isSampler { return (1, 0) }
    if t.isStruct {
      var off = 0
      var align = 16
      for m in structs[t.structID].members {
        let x = std140(m.type)
        if x.size == 0 { continue }
        off = roundUp(off, x.align) + x.size
        align = max(align, x.align)
      }
      return (align, roundUp(off, align))
    }
    if t.isMatrix { return (16, 16 * t.cols) }
    switch t.rows {
    case 1: return (4, 4)
    case 2: return (8, 8)
    case 3: return (16, 12)
    default: return (16, 16)
    }
  }

}
