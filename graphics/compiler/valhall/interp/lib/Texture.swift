// SPDX-License-Identifier: BSD-3-Clause

// The texture unit's model (valhall 12b, 03 section 3.7 and 3.8): a sampled image with mip levels, layers, cube faces and
// samples, a sampler descriptor, and the filtering a TEX instruction asks for. It is a model to test the compiler, not
// the hardware: where the spec leaves the unit's arithmetic open, this file makes a choice and says so.
//
// The choices:
//  - The level of detail of a quad is log2 of the larger of the two Euclidean lengths (the derivatives along x and along
//    y, each scaled by the level-0 size of the image): the isotropic formula of the graphics APIs. The spec gives no
//    formula (12b.6, 12b.5.5). Anisotropic filtering is not modelled.
//  - The sampler's bias is added, and its minimum and maximum applied, for every level mode that reads a level
//    (computed, computed with bias, explicit, a gradient descriptor); 12b.5.5 says it for the computed modes only.
//  - Mipmap mode 0 (nearest) picks `ceil(lod + 0.5) - 1` (12b.13.4's recipe), 1 (none) level 0, 2 and 3 blend the two
//    levels the fraction names (performance trilinear is the same here).
//  - Magnification is a level of detail at or below the cutoff (0, or 0.5 with the sampler's "magnify cutoff", 03 3.7).
//  - Integer textures are always read with the nearest texel and the nearest level.
//  - A depth-compare sample compares each texel, then filters the 0 and 1 results; it returns the result in channel 0
//    and 0, 0, 1 in the others (12b.6 leaves the other channels open).
//  - An out-of-range layer is clamped (the sampler's bit 26 on, the default); an out-of-range fetch returns zeros (the
//    hardware's value is open, 12b.7).
//  - Cube images are read in the direction form (12b.5.3, arch 11 and later): the face is the direction's major axis,
//    in the order +X -X +Y -Y +Z -Z, with the coordinate conventions of the graphics APIs; the spec leaves the
//    numbering and signs open. The filter does not cross faces (the sampler's seamless bit is not modelled): a texel
//    off a face is addressed by the face's own wrap mode.
//  - Unnormalised coordinates are not modelled.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// The texture's dimensionality as 12b.4 numbers it.
public enum TexDim: Int, Sendable { case d1 = 0, d2 = 1, d3 = 2, cube = 3 }

/// A sampled image: levels of texels, four 32-bit words each (floats' bit patterns, or integers), by layer and sample.
public struct TextureModel: Sendable {
  public var dim: TexDim
  public var width: Int
  public var height: Int
  public var depth: Int
  /// Array size: layers, or for a cube the number of cubes (1 when the image is not arrayed).
  public var layers: Int
  public var arrayed: Bool
  public var levels: Int
  public var samples: Int
  /// Integer texels (unsigned or signed), read without filtering.
  public var integer: Bool
  var data: [UInt32] = []
  var levelStart: [Int] = []

  public var faceLayers: Int { layers * (dim == .cube ? 6 : 1) }

  /// A texture whose texel `(level, layer, sample, x, y, z)` is `texel`: four words. For a cube `layer` counts faces.
  public init(
    dim: TexDim, width: Int, height: Int = 1, depth: Int = 1, layers: Int = 1, arrayed: Bool = false, levels: Int = 1,
    samples: Int = 1, integer: Bool = false, texel: (_ level: Int, _ layer: Int, _ sample: Int, _ x: Int, _ y: Int, _ z: Int) -> [UInt32]
  ) {
    self.dim = dim
    self.width = width
    self.height = height
    self.depth = depth
    self.layers = layers
    self.arrayed = arrayed
    self.levels = levels
    self.samples = samples
    self.integer = integer
    for l in 0..<levels {
      levelStart.append(data.count)
      let (w, h, d) = levelSize(l)
      for layer in 0..<faceLayers {
        for s in 0..<samples {
          for z in 0..<d {
            for y in 0..<h {
              for x in 0..<w {
                let t = texel(l, layer, s, x, y, z)
                for c in 0..<4 { data.append(c < t.count ? t[c] : 0) }
              }
            }
          }
        }
      }
    }
  }

  /// The size of level `l`: each axis halves, to a minimum of one (12b.13.2).
  public func levelSize(_ l: Int) -> (Int, Int, Int) {
    (max(1, width >> l), max(1, height >> l), dim == .d3 ? max(1, depth >> l) : 1)
  }

  /// The texel at integer coordinates, or nil outside the level.
  public func fetch(x: Int, y: Int, z: Int, layer: Int, level: Int, sample: Int) -> [UInt32]? {
    guard level >= 0, level < levels else { return nil }
    let (w, h, d) = levelSize(level)
    guard x >= 0, x < w, y >= 0, y < h, z >= 0, z < d, layer >= 0, layer < faceLayers, sample >= 0, sample < samples else { return nil }
    let at = levelStart[level] + ((((layer * samples + sample) * d + z) * h + y) * w + x) * 4
    return Array(data[at..<(at + 4)])
  }

  /// The words of the descriptor a shader reads back (12b.13, 03 3.8.4): the word `w` of the 8.
  public func descriptorWord(_ w: Int) -> UInt32 {
    switch w {
    case 0: return 1
    case 1: return UInt32(width - 1) | UInt32(height - 1) << 16
    case 2: return UInt32(levels - 1) << 16
    case 3:
      var log2 = 0
      while 1 << log2 < samples { log2 += 1 }
      return UInt32(log2) << 13
    case 6: return UInt32(layers - 1)
    case 7: return UInt32(depth - 1)
    default: return 0
    }
  }
}

/// A sampler descriptor (03 3.7): eight words, and the Vulkan-shaped way to make one.
public struct SamplerModel: Sendable {
  public var words: [UInt32]

  public static let wrapRepeat = 8, wrapClamp = 9, wrapBorder = 11, wrapMirror = 12, wrapMirrorClamp = 13, wrapMirrorBorder = 15
  /// Mipmap modes: 0 nearest, 1 none, 2 and 3 trilinear.
  public static let mipNearest = 0, mipNone = 1, mipTrilinear = 3

  /// `compareOp` is the API's function, "reference op texel" (Vulkan's numbering: never 0, less 1, equal 2, less or
  /// equal 3, greater 4, not equal 5, greater or equal 6, always 7), written mirrored as 03 3.7.4 says; nil is no comparison.
  public init(
    magNearest: Bool = false, minNearest: Bool = false, mipmap: Int = 3, wrap: [Int] = [9, 9, 9], lodBias: Float = 0,
    minLod: Float = 0, maxLod: Float = 15, compareOp: Int? = nil, border: [UInt32] = [0, 0, 0, 0], magnifyCutoffHalf: Bool = false
  ) {
    var w = [UInt32](repeating: 0, count: 8)
    w[0] = 1 | UInt32(wrap[2]) << 8 | UInt32(wrap[1]) << 12 | UInt32(wrap[0]) << 16 | 1 << 21 | 1 << 23 | 1 << 25 | 1 << 26
    if minNearest { w[0] |= 1 << 27 }
    if magNearest { w[0] |= 1 << 28 }
    if magnifyCutoffHalf { w[0] |= 1 << 29 }
    w[0] |= UInt32(mipmap) << 30
    func ulod(_ f: Float) -> UInt32 { UInt32(min(max(f * 256, 0), 8191)) }
    var code: UInt32 = 0
    if let op = compareOp {
      let mirrored = [0, 4, 2, 6, 1, 5, 3, 7]
      code = UInt32(mirrored[op])
    }
    w[1] = ulod(minLod) | code << 13 | ulod(maxLod) << 16
    w[2] = UInt32(UInt16(bitPattern: Int16(min(max(lodBias * 256, -32768), 32767))))
    for k in 0..<4 { w[4 + k] = border[k] }
    words = w
  }

  func wrapMode(_ axis: Int) -> Int { Int(words[0] >> UInt32(16 - 4 * axis) & 15) }
  var minNearest: Bool { words[0] >> 27 & 1 != 0 }
  var magNearest: Bool { words[0] >> 28 & 1 != 0 }
  var cutoff: Float { words[0] >> 29 & 1 != 0 ? 0.5 : 0 }
  var mipmap: Int { Int(words[0] >> 30) }
  public var minLod: Float { Float(words[1] & 0x1FFF) / 256 }
  public var maxLod: Float { Float(words[1] >> 16 & 0x1FFF) / 256 }
  public var bias: Float { Float(Int16(bitPattern: UInt16(truncatingIfNeeded: words[2]))) / 256 }
  var compareCode: Int { Int(words[1] >> 13 & 7) }
}

/// A texel as the unit works on it: four floats while filtering (integer texels carry their words).
typealias Texel4 = [Float]

enum TexelAccess {
  /// The texel's value after addressing: nil from the address function means the border.
  static func border(_ s: SamplerModel) -> [UInt32] { Array(s.words[4..<8]) }
}

extension TextureModel {
  /// log2 of the level-0-scaled length of the larger of the two derivatives (the isotropic level of detail), or -inf.
  public func baseLod(dx: [Float], dy: [Float]) -> Float {
    let size = [Float(width), Float(height), Float(depth)]
    var rx: Float = 0, ry: Float = 0
    for i in 0..<min(dx.count, 3) {
      rx += (dx[i] * size[i]) * (dx[i] * size[i])
      ry += (dy[i] * size[i]) * (dy[i] * size[i])
    }
    let rho = max(rx, ry).squareRoot()
    return rho == 0 ? -Float.infinity : Float(log2(Double(rho)))
  }

  /// The wrapped texel index along an axis of size `n`, or nil for the border.
  static func address(_ i: Int, _ n: Int, _ mode: Int) -> Int? {
    switch mode {
    case SamplerModel.wrapRepeat:
      return ((i % n) + n) % n
    case SamplerModel.wrapBorder:
      return i >= 0 && i < n ? i : nil
    case SamplerModel.wrapMirror:
      let m = ((i % (2 * n)) + 2 * n) % (2 * n)
      return m < n ? m : 2 * n - 1 - m
    case SamplerModel.wrapMirrorClamp:
      return min(i >= 0 ? i : -(1 + i), n - 1)
    case SamplerModel.wrapMirrorBorder:
      let m = i >= 0 ? i : -(1 + i)
      return m < n ? m : nil
    default:
      return min(max(i, 0), n - 1)
    }
  }

  /// A cube direction to (face, s, t) with the graphics APIs' conventions.
  public static func cubeFace(_ x: Float, _ y: Float, _ z: Float) -> (face: Int, s: Float, t: Float) {
    let ax = abs(x), ay = abs(y), az = abs(z)
    var face = 0
    var sc: Float = 0, tc: Float = 0, ma: Float = 1
    if ax >= ay && ax >= az {
      face = x >= 0 ? 0 : 1
      ma = ax
      sc = x >= 0 ? -z : z
      tc = -y
    } else if ay >= az {
      face = y >= 0 ? 2 : 3
      ma = ay
      sc = x
      tc = y >= 0 ? z : -z
    } else {
      face = z >= 0 ? 4 : 5
      ma = az
      sc = z >= 0 ? x : -x
      tc = -y
    }
    if ma == 0 { return (face, 0.5, 0.5) }
    return (face, 0.5 * (sc / ma + 1), 0.5 * (tc / ma + 1))
  }

  /// The cube's level of detail from the directions at the lane and at its x and y neighbours: the derivatives of the
  /// face coordinates, from the difference of the faces' coordinates computed on the lane's own face.
  public func cubeBaseLod(_ p: [Float], dx: [Float], dy: [Float]) -> Float {
    let f = TextureModel.cubeFace(p[0], p[1], p[2])
    func onFace(_ d: [Float]) -> (Float, Float) {
      let q = [p[0] + d[0], p[1] + d[1], p[2] + d[2]]
      let ax = abs(p[0]), ay = abs(p[1]), az = abs(p[2])
      var sc: Float, tc: Float, ma: Float
      switch f.face {
      case 0: (sc, tc, ma) = (-q[2], -q[1], q[0]); _ = ax
      case 1: (sc, tc, ma) = (q[2], -q[1], -q[0])
      case 2: (sc, tc, ma) = (q[0], q[2], q[1]); _ = ay
      case 3: (sc, tc, ma) = (q[0], -q[2], -q[1])
      case 4: (sc, tc, ma) = (q[0], -q[1], q[2]); _ = az
      default: (sc, tc, ma) = (-q[0], -q[1], -q[2])
      }
      return (0.5 * (sc / ma + 1), 0.5 * (tc / ma + 1))
    }
    let zero: [Float] = [0, 0, 0]
    let o = onFace(zero), a = onFace(dx), b = onFace(dy)
    return baseLod(dx: [a.0 - o.0, a.1 - o.1], dy: [b.0 - o.0, b.1 - o.1])
  }

  /// The compare function of the sampler (03 3.7.3): the texel is the first operand.
  static func compare(_ code: Int, _ texel: Float, _ ref: Float) -> Bool {
    switch code {
    case 1: return texel < ref
    case 2: return texel == ref
    case 3: return texel <= ref
    case 4: return texel > ref
    case 5: return texel != ref
    case 6: return texel >= ref
    case 7: return true
    default: return false
    }
  }

  /// One texel read for the filter: addressed, converted, compared when asked; a texel off the image is the border.
  func filterTexel(_ s: SamplerModel, _ x: Int, _ y: Int, _ z: Int, layer: Int, level: Int, ref: Float?) -> Texel4 {
    let (w, h, d) = levelSize(level)
    let ax = TextureModel.address(x, w, s.wrapMode(0))
    let ay = dim == .d1 ? 0 : TextureModel.address(y, h, s.wrapMode(1))
    let az = dim == .d3 ? TextureModel.address(z, d, s.wrapMode(2)) : 0
    let words: [UInt32]
    if let ax, let ay, let az, let t = fetch(x: ax, y: ay, z: az, layer: layer, level: level, sample: 0) {
      words = t
    } else {
      words = TexelAccess.border(s)
    }
    var t = words.map { Float(bitPattern: $0) }
    if let r = ref {
      let ok = TextureModel.compare(s.compareCode, t[0], r)
      t = [ok ? 1 : 0, 0, 0, 1]
    }
    return t
  }

  /// A filtered read of one level at normalised coordinates.
  func readLevel(_ s: SamplerModel, _ c: [Float], layer: Int, level: Int, nearest: Bool, ref: Float?) -> Texel4 {
    let (w, h, d) = levelSize(level)
    let u = c[0] * Float(w)
    let v = (c.count > 1 ? c[1] : 0) * Float(h)
    let t = (c.count > 2 ? c[2] : 0) * Float(d)
    if nearest {
      return filterTexel(s, Int(u.rounded(.down)), Int(v.rounded(.down)), Int(t.rounded(.down)), layer: layer, level: level, ref: ref)
    }
    let u0 = (u - 0.5).rounded(.down), v0 = (v - 0.5).rounded(.down), t0 = (t - 0.5).rounded(.down)
    let fu = u - 0.5 - u0, fv = v - 0.5 - v0, ft = t - 0.5 - t0
    var out: Texel4 = [0, 0, 0, 0]
    let zs = dim == .d3 ? 2 : 1
    let ys = dim == .d1 ? 1 : 2
    for k in 0..<zs {
      for j in 0..<ys {
        for i in 0..<2 {
          let wu = i == 0 ? 1 - fu : fu
          let wv = ys == 1 ? 1 : (j == 0 ? 1 - fv : fv)
          let wt = zs == 1 ? 1 : (k == 0 ? 1 - ft : ft)
          let weight = wu * wv * wt
          if weight == 0 { continue }
          let x = filterTexel(s, Int(u0) + i, Int(v0) + j, Int(t0) + k, layer: layer, level: level, ref: ref)
          for c in 0..<4 { out[c] += x[c] * weight }
        }
      }
    }
    return out
  }

  /// A sample at the level of detail `lod` (already biased and clamped): the words of the texel.
  /// `c` is the coordinate: 1 to 3 normalised values, or for a cube the direction.
  public func sample(
    _ s: SamplerModel, _ c: [Float], layer: Int, lod: Float, offset: (Int, Int, Int) = (0, 0, 0), compare ref: Float? = nil
  ) -> [UInt32] {
    var coord = c
    var layer = layer
    if dim == .cube {
      let f = TextureModel.cubeFace(c[0], c[1], c[2])
      coord = [f.s, f.t]
      layer = min(max(layer, 0), layers - 1) * 6 + f.face
    } else {
      layer = min(max(layer, 0), layers - 1)
    }
    let mode = integer ? SamplerModel.mipNearest : s.mipmap
    let magnified = lod <= s.cutoff
    let nearestFilter = integer || (magnified ? s.magNearest : s.minNearest)
    func read(_ level: Int) -> Texel4 {
      var cc = coord
      // The texel offset moves the lookup by whole texels of the level.
      let (w, h, d) = levelSize(level)
      cc[0] += Float(offset.0) / Float(w)
      if cc.count > 1 { cc[1] += Float(offset.1) / Float(h) }
      if cc.count > 2 { cc[2] += Float(offset.2) / Float(d) }
      return readLevel(s, cc, layer: layer, level: level, nearest: nearestFilter, ref: ref)
    }
    var out: Texel4
    switch mode {
    case SamplerModel.mipNone:
      out = read(0)
    case SamplerModel.mipNearest:
      let d = min(max(Int((lod + 0.5).rounded(.up)) - 1, 0), levels - 1)
      out = read(d)
    default:
      let l = min(max(lod, 0), Float(levels - 1))
      let d0 = Int(l.rounded(.down))
      let d1 = min(d0 + 1, levels - 1)
      let f = l - Float(d0)
      out = read(d0)
      if f > 0 && d1 != d0 {
        let b = read(d1)
        for k in 0..<4 { out[k] = out[k] * (1 - f) + b[k] * f }
      }
    }
    if ref != nil { return [out[0].bitPattern, 0, 0, Float(1).bitPattern] }
    if integer { return out.map { $0.bitPattern } }
    return out.map { $0.bitPattern }
  }

  /// The four texels of a gather (12b.5.7), in the hardware's order (x0,y0), (x1,y0), (x0,y1), (x1,y1): one component,
  /// at level 0, around the coordinate offset by whole texels.
  public func gather(
    _ s: SamplerModel, _ c: [Float], layer: Int, component: Int, offset: (Int, Int, Int) = (0, 0, 0), compare ref: Float? = nil
  ) -> [UInt32] {
    var coord = c
    var layer = layer
    if dim == .cube {
      let f = TextureModel.cubeFace(c[0], c[1], c[2])
      coord = [f.s, f.t]
      layer = min(max(layer, 0), layers - 1) * 6 + f.face
    } else {
      layer = min(max(layer, 0), layers - 1)
    }
    let u = coord[0] * Float(width) - 0.5
    let v = coord[1] * Float(height) - 0.5
    let x0 = Int(u.rounded(.down)) + offset.0
    let y0 = Int(v.rounded(.down)) + offset.1
    var out: [UInt32] = []
    for (dy, dx) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
      let t = filterTexel(s, x0 + dx, y0 + dy, 0, layer: layer, level: 0, ref: ref)
      out.append(ref != nil ? t[0].bitPattern : t[component].bitPattern)
    }
    return out
  }
}
