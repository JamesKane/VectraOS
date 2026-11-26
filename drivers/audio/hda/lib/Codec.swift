// SPDX-License-Identifier: BSD-3-Clause

// An HD Audio codec as a graph of widgets (Intel High Definition Audio
// Specification rev. 1.0a, §7.1, §7.3.4): its audio function group, each
// widget's type, connections, pin defaults and amplifiers, read through
// `send` (a command word to its response, nil if none came). The output
// path runs from the best connected output pin (line out, then speaker,
// then headphones, by their defaults) back through selectors and mixers
// to an analog DAC; the input path from an analog ADC to the best input
// pin (line in, then microphone). Setting a path up is a list of verbs:
// every node powered, each selector set to the next node, each amplifier
// on the path unmuted at 0 dB, the pin's direction enabled (and the
// headphone amplifier, and EAPD where the pin has it).

public struct Widget: Equatable, Sendable {
  public var node: Int
  public var caps: WidgetCaps
  public var connections: [Int]
  public var pinCaps: UInt32
  public var config: PinConfig
  public var inAmp: AmpCaps
  public var outAmp: AmpCaps
  public var pcm: UInt32

  public init(node: Int, caps: WidgetCaps, connections: [Int] = [], pinCaps: UInt32 = 0, config: PinConfig = PinConfig(0),
              inAmp: AmpCaps = AmpCaps(0), outAmp: AmpCaps = AmpCaps(0), pcm: UInt32 = 0) {
    self.node = node
    self.caps = caps
    self.connections = connections
    self.pinCaps = pinCaps
    self.config = config
    self.inAmp = inAmp
    self.outAmp = outAmp
    self.pcm = pcm
  }

  public var type: WidgetType? { caps.type }
  public var outputCapable: Bool { pinCaps & (1 << 4) != 0 }
  public var inputCapable: Bool { pinCaps & (1 << 5) != 0 }
  public var eapd: Bool { pinCaps & (1 << 16) != 0 }
}

public struct CodecGraph: Equatable, Sendable {
  public var codec: Int
  public var vendor: UInt32
  public var afg: Int
  public var widgets: [Widget]

  public init(codec: Int, vendor: UInt32, afg: Int, widgets: [Widget]) {
    self.codec = codec
    self.vendor = vendor
    self.afg = afg
    self.widgets = widgets
  }

  /// Reads codec `codec`'s audio function group and its widgets: nil if
  /// it has none, or doesn't answer.
  public static func read(codec: Int, send: (UInt32) -> UInt32?) -> CodecGraph? {
    func param(_ node: Int, _ p: UInt32) -> UInt32? {
      send(Verb.command(codec: codec, node: node, verb: Verb.getParameter, payload: p))
    }
    func get(_ node: Int, _ verb: UInt32, _ payload: UInt32 = 0) -> UInt32? {
      send(Verb.command(codec: codec, node: node, verb: verb, payload: payload))
    }
    guard let vendor = param(0, Parameter.vendor), let groups = param(0, Parameter.nodeCount) else { return nil }
    let first = Int((groups >> 16) & 0xFF), count = Int(groups & 0xFF)
    var afg: Int?
    for n in first..<(first + count) where (param(n, Parameter.functionType) ?? 0) & 0xFF == 1 {
      afg = n
      break
    }
    guard let afg, let nodes = param(afg, Parameter.nodeCount) else { return nil }
    let groupPCM = param(afg, Parameter.pcm) ?? 0
    let groupIn = AmpCaps(param(afg, Parameter.inAmpCaps) ?? 0), groupOut = AmpCaps(param(afg, Parameter.outAmpCaps) ?? 0)
    var widgets: [Widget] = []
    let start = Int((nodes >> 16) & 0xFF), n = Int(nodes & 0xFF)
    for node in start..<(start + n) {
      guard let raw = param(node, Parameter.widgetCaps) else { continue }
      let caps = WidgetCaps(raw)
      var w = Widget(node: node, caps: caps)
      if caps.connectionList, let length = param(node, Parameter.connectionLength) {
        w.connections = connections(length: length) { get(node, Verb.getConnectionList, $0) }
      }
      if caps.type == .pin {
        w.pinCaps = param(node, Parameter.pinCaps) ?? 0
        w.config = PinConfig(get(node, Verb.getConfigDefault) ?? 0x4000_0000)
      }
      w.inAmp = caps.ampOverride ? AmpCaps(param(node, Parameter.inAmpCaps) ?? 0) : groupIn
      w.outAmp = caps.ampOverride ? AmpCaps(param(node, Parameter.outAmpCaps) ?? 0) : groupOut
      if caps.type == .output || caps.type == .input {
        w.pcm = caps.formatOverride ? param(node, Parameter.pcm) ?? 0 : groupPCM
      }
      widgets.append(w)
    }
    return CodecGraph(codec: codec, vendor: vendor, afg: afg, widgets: widgets)
  }

  /// A connection list of `length`'s form (§7.3.3.3): short entries 4 a
  /// response, long 2; an entry with its top bit set is a range from the
  /// entry before it.
  public static func connections(length: UInt32, entry: (UInt32) -> UInt32?) -> [Int] {
    let long = length & 0x80 != 0
    let count = Int(length & 0x7F)
    let per = long ? 2 : 4, bits: UInt32 = long ? 16 : 8
    var out: [Int] = []
    var i = 0
    while i < count {
      guard let word = entry(UInt32(i)) else { break }
      for j in 0..<per where i + j < count {
        let e = (word >> (bits * UInt32(j))) & ((1 << bits) - 1)
        let node = Int(e & ((1 << (bits - 1)) - 1))
        if e & (1 << (bits - 1)) != 0, let last = out.last, last < node {
          for k in (last + 1)...node { out.append(k) }
        } else {
          out.append(node)
        }
      }
      i += per
    }
    return out
  }

  public func widget(_ node: Int) -> Widget? { widgets.first { $0.node == node } }

  /// The nodes from `from` to the first node `goal` takes, through
  /// connections (breadth first, at most 6 deep), `from` first.
  func path(from: Int, to goal: (Widget) -> Bool) -> [Int]? {
    var paths: [[Int]] = [[from]]
    var seen: [Int] = [from]
    for _ in 0..<6 {
      var next: [[Int]] = []
      for p in paths {
        guard let w = widget(p.last!) else { continue }
        for c in w.connections where !seen.contains(c) {
          seen.append(c)
          guard let cw = widget(c) else { continue }
          if goal(cw) { return p + [c] }
          next.append(p + [c])
        }
      }
      paths = next
    }
    return nil
  }

  /// Playback's path: a pin first, an analog DAC last.
  public func outputPath() -> [Int]? {
    let pins = widgets.filter { $0.type == .pin && $0.config.connected && $0.config.isOutput && $0.outputCapable }
      .sorted { ($0.config.rank, $0.config.association, $0.config.sequence) < ($1.config.rank, $1.config.association, $1.config.sequence) }
    for pin in pins {
      if let p = path(from: pin.node, to: { $0.type == .output && !$0.caps.digital }) { return p }
    }
    return nil
  }

  /// Capture's path: an analog ADC first, a pin last.
  public func inputPath() -> [Int]? {
    var best: (rank: Int, path: [Int])?
    for adc in widgets where adc.type == .input && !adc.caps.digital {
      guard let p = path(from: adc.node, to: { $0.type == .pin && $0.config.connected && $0.config.isInput && $0.inputCapable })
      else { continue }
      let rank = widget(p.last!)!.config.rank
      if best == nil || rank < best!.rank { best = (rank, p) }
    }
    return best?.path
  }

  func command(_ node: Int, _ verb: UInt32, _ payload: UInt32) -> UInt32 {
    Verb.command(codec: codec, node: node, verb: verb, payload: payload)
  }

  /// An amplifier unmuted at 0 dB, both sides: output or input, of input
  /// `index`.
  func amp(_ node: Int, output: Bool, index: Int, _ caps: AmpCaps) -> UInt32 {
    let payload: UInt32 = (output ? 1 << 15 : 1 << 14) | 1 << 13 | 1 << 12 | UInt32(index & 0xF) << 8 | caps.offset
    return command(node, Verb.setAmp, payload)
  }

  /// The verbs that set `path` up: playback's (pin to DAC) if `output`,
  /// else capture's (ADC to pin).
  public func setUp(_ path: [Int], output: Bool) -> [UInt32] {
    var verbs = [command(afg, Verb.setPowerState, 0)]
    for n in path where widget(n)?.caps.powerControl == true { verbs.append(command(n, Verb.setPowerState, 0)) }
    for (i, n) in path.enumerated() {
      guard let w = widget(n) else { continue }
      // Where the signal comes from: the next node on playback's path
      // (towards the DAC), the next on capture's (towards the pin).
      let from = i + 1 < path.count ? path[i + 1] : nil
      if let from, let index = w.connections.firstIndex(of: from) {
        if w.type == .mixer {
          if w.caps.inAmp { verbs.append(amp(n, output: false, index: index, w.inAmp)) }
        } else {
          if w.connections.count > 1 { verbs.append(command(n, Verb.setConnectionSelect, UInt32(index))) }
          if w.caps.inAmp && w.type != .pin { verbs.append(amp(n, output: false, index: index, w.inAmp)) }
        }
      }
      if w.caps.outAmp && (output || w.type != .input) { verbs.append(amp(n, output: true, index: 0, w.outAmp)) }
      if w.type == .pin {
        if output {
          verbs.append(command(n, Verb.setPinControl, w.config.device == 2 ? 0xC0 : 0x40))
          if w.eapd { verbs.append(command(n, Verb.setEAPD, 0x02)) }
        } else {
          verbs.append(command(n, Verb.setPinControl, 0x20))
          if w.caps.inAmp { verbs.append(amp(n, output: false, index: 0, w.inAmp)) }
        }
      }
    }
    return verbs
  }
}
