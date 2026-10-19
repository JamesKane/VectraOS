// SPDX-License-Identifier: BSD-3-Clause

// The resolved theme on the wire (D91, theming.md §3): Radharc resolves
// the theme in force and keeps it as one message of the wire format,
// RadharcIPC.ThemeFile's `resolved` event, in a read-only VMO that every
// client maps from `/svc/windows/theme/resolved`. An app reads its Theme
// back from those bytes and never parses a theme file. Floats travel as
// their IEEE 754 bits: the wire format has integers.

import IPC
import Themes

extension RadharcIPC.ResolvedTheme {
  /// `theme`'s wire form, at `generation`.
  public init(_ theme: Theme, generation: UInt64) {
    let faces = [FontRole.display, .body, .mono, .ui].map { r in
      let f = theme.typeface(r)
      return RadharcIPC.ThemeFace(family: f.family, weight: UInt16(clamping: f.weight), width: UInt16(clamping: f.width))
    }
    let knobs = theme.knobs.map { k in
      RadharcIPC.ThemeKnob(name: k.name, kind: k.kind.rawValue, label: k.label ?? "", defaultValue: k.defaultValue,
                           value: k.value, options: k.options, min: k.min.bitPattern, max: k.max.bitPattern)
    }
    self.init(generation: generation, name: theme.name, title: theme.title, variant: theme.variant ?? "",
              textScale: theme.textScale.bitPattern,
              roles: theme.roles.map { RadharcIPC.ThemeRole(name: $0, color: theme.color($0)) },
              styles: theme.classes.map { RadharcIPC.ThemeStyle(name: $0, theme.style($0)) }, faces: faces, knobs: knobs)
  }

  /// The message `theme/resolved` holds.
  public func encoded() -> [UInt8]? {
    (try? RadharcIPC.ThemeFileEventSender.encodeResolved(self))?.bytes
  }

  /// A resolved theme read back from `theme/resolved`'s bytes; nil if they
  /// aren't one.
  public init?(decoding bytes: [UInt8]) {
    let message = IPCMessage(bytes: bytes, handles: [])
    guard let header = try? message.header(),
      case .resolved(let t)? = try? RadharcIPC.ThemeFileEvent._decodeIfKnown(header, message)
    else { return nil }
    self = t
  }
}

extension RadharcIPC.ThemeStyle {
  init(name: String, _ s: Style) {
    self.init(name: name, fill: s.fill, stroke: s.stroke, ink: s.ink, border: s.border.bitPattern,
              radius: s.radius.bitPattern, cuts: s.cuts, glow: s.glow.bitPattern, glowColor: s.glowColor,
              font: s.font.rawValue, weight: UInt16(clamping: s.weight), size: s.textSize.bitPattern,
              lineHeight: s.lineHeight.bitPattern, tracking: s.tracking.bitPattern, uppercase: s.uppercase,
              padding: [s.padding.top, s.padding.right, s.padding.bottom, s.padding.left].map { $0.bitPattern },
              materials: s.materials.map { RadharcIPC.ThemeMaterial($0) })
  }

  /// The style it carries, or nil if a field is out of range.
  var style: Style? {
    guard let font = FontRole(rawValue: font), padding.count == 4 else { return nil }
    var materials: [Material] = []
    for m in self.materials {
      guard let v = m.material else { return nil }
      materials.append(v)
    }
    let p = padding.map { Float(bitPattern: $0) }
    return Style(fill: fill, stroke: stroke, ink: ink, border: Float(bitPattern: border),
                 radius: Float(bitPattern: radius), cuts: cuts, glow: Float(bitPattern: glow), glowColor: glowColor,
                 font: font, weight: Int(weight), textSize: Float(bitPattern: size),
                 lineHeight: Float(bitPattern: lineHeight), tracking: Float(bitPattern: tracking),
                 uppercase: uppercase, padding: (p[0], p[1], p[2], p[3]), materials: materials)
  }
}

extension RadharcIPC.ThemeMaterial {
  init(_ m: Material) {
    switch m {
    case .gradient(let a, let b, let angle):
      self.init(kind: 1, style: 0, a: a, b: b, x: angle.bitPattern, y: 0, z: 0)
    case .bevel(let k, let width):
      self.init(kind: 2, style: k.rawValue, a: 0, b: 0, x: width.bitPattern, y: 0, z: 0)
    case .pattern(let k, let a, let b, let pitch):
      self.init(kind: 3, style: k.rawValue, a: a, b: b, x: pitch.bitPattern, y: 0, z: 0)
    case .shadow(let c, let x, let y, let blur):
      self.init(kind: 4, style: 0, a: c, b: 0, x: x.bitPattern, y: y.bitPattern, z: blur.bitPattern)
    }
  }

  var material: Material? {
    let (x, y, z) = (Float(bitPattern: x), Float(bitPattern: y), Float(bitPattern: z))
    switch kind {
    case 1: return .gradient(a, b, angle: x)
    case 2: return BevelKind(rawValue: style).map { .bevel($0, width: x) }
    case 3: return PatternKind(rawValue: style).map { .pattern($0, a, b, pitch: x) }
    case 4: return .shadow(a, x: x, y: y, blur: z)
    default: return nil
    }
  }
}

extension Theme {
  /// The theme a resolved theme carries; nil if it is malformed (a style
  /// or face out of range, faces missing).
  public init?(_ r: RadharcIPC.ResolvedTheme) {
    guard r.faces.count == 4 else { return nil }
    var styles: [(String, Style)] = []
    for s in r.styles {
      guard let v = s.style else { return nil }
      styles.append((s.name, v))
    }
    var knobs: [Knob] = []
    for k in r.knobs {
      guard let kind = Knob.Kind(rawValue: k.kind) else { return nil }
      knobs.append(Knob(name: k.name, kind: kind, label: k.label.isEmpty ? nil : k.label,
                        defaultValue: k.defaultValue, value: k.value, options: k.options,
                        min: Double(bitPattern: k.min), max: Double(bitPattern: k.max)))
    }
    self.init(name: r.name, title: r.title, variant: r.variant.isEmpty ? nil : r.variant,
              textScale: Float(bitPattern: r.textScale), knobs: knobs,
              roles: r.roles.map { ($0.name, $0.color) }, styles: styles,
              faces: r.faces.map { Typeface(family: $0.family, weight: Int($0.weight), width: Int($0.width)) })
  }
}
