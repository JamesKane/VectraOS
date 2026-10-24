// SPDX-License-Identifier: BSD-3-Clause

// The kernels' scalar reference (D129): a pixel at a time, as the UI
// libraries drew before spans. Every tier's kernels give the same bytes
// as these, which the pixels suite checks. A change to what a kernel
// draws is made here first, in the open, and the kernels follow.

#if canImport(Light)
import Light
#endif

extension PixelKernels {
  public enum Reference {
    public static func fill(_ target: UnsafeMutablePointer<UInt32>, _ count: Int, _ color: UInt32) {
      for i in 0..<count { unsafe target[i] = color }
    }

    public static func copyOpaque(_ target: UnsafeMutablePointer<UInt32>, _ source: UnsafePointer<UInt32>,
                                  _ count: Int)
    {
      for i in 0..<count { unsafe target[i] = source[i] & 0xFF_FFFF }
    }

    public static func over(premultiplied source: UnsafePointer<UInt32>, _ target: UnsafeMutablePointer<UInt32>,
                            _ count: Int)
    {
      for i in 0..<count { unsafe target[i] = Light.over(premultiplied: source[i], target[i]) }
    }

    public static func over(straight source: UnsafePointer<UInt32>, _ target: UnsafeMutablePointer<UInt32>,
                            _ count: Int)
    {
      for i in 0..<count { unsafe target[i] = Light.over(straight: source[i], target[i]) }
    }

    public static func over(_ color: UInt32, coverage: UInt32, _ target: UnsafeMutablePointer<UInt32>,
                            _ count: Int)
    {
      for i in 0..<count { unsafe target[i] = Light.over(color, target[i], coverage: coverage) }
    }

    public static func overText(_ color: UInt32, coverage: UnsafePointer<UInt8>,
                                _ target: UnsafeMutablePointer<UInt32>, _ count: Int, alpha: UInt32,
                                contrast: TextContrast)
    {
      for i in 0..<count where unsafe coverage[i] > 0 {
        unsafe target[i] = Light.overText(color, target[i], coverage: Int(coverage[i]), alpha: alpha,
                                          contrast: contrast)
      }
    }
  }
}
