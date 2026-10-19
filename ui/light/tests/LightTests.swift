// SPDX-License-Identifier: BSD-3-Clause

// Light's tables against the sRGB formula, and its blends against the
// formula's own in floating point.

import LightGen
import Testing

@testable import Light

@Test func theTablesAreLightgens() throws {
  let t = try tables()
  #expect(Light.decodeTable == t.decode && Light.encodeTable == t.encode, "stale: run .build/debug/lightgen ui/light/lib/Tables.swift")
}

@Test func everyByteComesBackItself() {
  for b in UInt32(0)...255 { #expect(Light.encode(Light.decode(b)) == b, "byte \(b)") }
}

@Test func theTablesFollowTheFormula() {
  // Decoding within half a 16-bit step; encoding within a byte of the
  // formula anywhere in a level's range.
  for b in 0..<256 {
    #expect(abs(Double(Light.decode(UInt32(b))) - srgbDecode(Double(b) / 255) * 65535) <= 0.5)
  }
  for l in stride(from: 0, through: 65535, by: 7) {
    let exact = srgbEncode(Double(l) / 65535) * 255
    #expect(abs(Double(Light.encode(UInt32(l))) - exact) <= 1, "light \(l)")
  }
}

@Test func aBlendIsInLight() {
  // White over black at half coverage is half the light: 0xbc, not the
  // bytes' 0x80.
  #expect(Light.over(0xFF_FFFF, 0, coverage: 128) == 0xBCBCBC)
  #expect(Light.over(straight: 0x80FF_FFFF, 0x33_6699) == 0xBF_C7D4)
  #expect(Light.over(0x12_3456, 0xAB_CDEF, coverage: 255) == 0x12_3456)
  #expect(Light.over(0x12_3456, 0xAB_CDEF, coverage: 0) == 0xAB_CDEF)
  // Against the formula, for a spread of colours and coverages.
  for (c, u) in [(UInt32(0x1D_1B17), UInt32(0xFB_FAF6)), (0xD8_E1FF, 0x0A_0A12), (0x3E_6FB0, 0xF2_BB26)] {
    for a in stride(from: UInt32(1), to: 255, by: 9) {
      let got = Light.over(c, u, coverage: a)
      for s in [UInt32(16), 8, 0] {
        let t = Double(a) / 255
        let l = srgbDecode(Double(c >> s & 0xFF) / 255) * t + srgbDecode(Double(u >> s & 0xFF) / 255) * (1 - t)
        #expect(abs(Double(got >> s & 0xFF) - srgbEncode(l) * 255) <= 1)
      }
    }
  }
}

@Test func alphaIsPremultipliedInLight() {
  // Half-transparent white, premultiplied in light: half its light is
  // 0xbc. Over black it is that; straight, the same colour is 0xffffff.
  #expect(Light.over(premultiplied: 0x80BC_BCBC, 0) == 0xBCBCBC)
  #expect(Light.over(straight: 0x80FF_FFFF, 0) == 0xBCBCBC)
  #expect(Light.over(premultiplied: 0xFF12_3456, 0xFF_FFFF) == 0x12_3456)
  // Over white, the premultiplied pixel adds half white's light.
  #expect(Light.over(premultiplied: 0x80BC_BCBC, 0xFF_FFFF) == 0xFFFFFF)
  #expect(Light.mix(0xFF00_0000, 0x00FF_FFFF, 128) == 0x7FBC_BCBC)
}

@Test func theContrastCurve() {
  let flat = TextContrast(step: 0), full = TextContrast(1)
  for c in 0..<256 { #expect(flat.apply(c, darker: true) == c && flat.apply(c, darker: false) == c) }
  // At 1, a cube: 0.4 of a pixel is 0.784 for darker ink, 0.064 for
  // lighter.
  #expect(full.apply(0, darker: true) == 0 && full.apply(255, darker: true) == 255)
  #expect(full.apply(102, darker: true) == 200 && full.apply(102, darker: false) == 16)
  // It raises coverage for darker ink and lowers it for lighter, and keeps
  // its order.
  let s = TextContrast.standard
  for c in 1..<256 {
    #expect(s.apply(c, darker: true) >= c && s.apply(c, darker: true) >= s.apply(c - 1, darker: true))
    #expect(s.apply(c, darker: false) <= c && s.apply(c, darker: false) >= s.apply(c - 1, darker: false))
  }
  #expect(TextContrast(0.6) == TextContrast(step: 12) && TextContrast(0.61) == TextContrast(step: 12))
  // The direction is the ink's against what's under it.
  #expect(Light.overText(0, 0xFF_FFFF, coverage: 102, contrast: full) == Light.over(0, 0xFF_FFFF, coverage: 200))
  #expect(Light.overText(0xFF_FFFF, 0, coverage: 102, contrast: full) == Light.over(0xFF_FFFF, 0, coverage: 16))
}
