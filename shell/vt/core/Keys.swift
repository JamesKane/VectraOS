// SPDX-License-Identifier: BSD-3-Clause

// Keys as a terminal sends them (M6j part 2d), as xterm does ("XTerm
// Control Sequences", PC-Style Function Keys): arrows CSI A-D (SS3 A-D in
// application cursor mode), Home and End CSI H and F (SS3 in application
// mode), Insert, Delete, Page Up and Down CSI n ~, F1-F4 SS3 P-S and F5-F12
// CSI n ~; with modifiers, CSI 1;m X or CSI n;m ~, m = 1 + Shift + 2 Alt
// + 4 Control. Enter CR, Tab HT (Shift-Tab CSI Z), Backspace DEL (BS with
// Control), Escape ESC. A character with Control is its control code
// (@ to _, and space as NUL), with Alt prefixed by ESC. Pasted text in
// bracketed paste mode comes between CSI 200 ~ and CSI 201 ~.

public enum TerminalKey: Equatable, Sendable {
  case up, down, right, left, home, end, insert, delete, pageUp, pageDown
  case function(Int)
  case enter, tab, backspace, escape
}

public struct KeyModifiers: OptionSet, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = KeyModifiers(rawValue: 1)
  public static let alt = KeyModifiers(rawValue: 2)
  public static let control = KeyModifiers(rawValue: 4)
}

public enum KeyEncoder {
  static let esc: UInt8 = 0x1B

  static func csi(_ s: String) -> [UInt8] { [esc, UInt8(ascii: "[")] + Array(s.utf8) }
  static func ss3(_ s: String) -> [UInt8] { [esc, UInt8(ascii: "O")] + Array(s.utf8) }

  /// A key's bytes.
  public static func encode(_ key: TerminalKey, _ m: KeyModifiers = [], applicationCursor: Bool = false) -> [UInt8] {
    let mod = m.isEmpty ? nil : Int(m.rawValue) + 1
    func letter(_ c: String) -> [UInt8] {
      if let mod { return csi("1;\(mod)" + c) }
      return applicationCursor ? ss3(c) : csi(c)
    }
    func tilde(_ n: Int) -> [UInt8] { csi(mod.map { "\(n);\($0)~" } ?? "\(n)~") }
    switch key {
    case .up: return letter("A")
    case .down: return letter("B")
    case .right: return letter("C")
    case .left: return letter("D")
    case .home: return letter("H")
    case .end: return letter("F")
    case .insert: return tilde(2)
    case .delete: return tilde(3)
    case .pageUp: return tilde(5)
    case .pageDown: return tilde(6)
    case .function(let n):
      switch n {
      case 1...4:
        let c = ["P", "Q", "R", "S"][n - 1]
        return mod.map { csi("1;\($0)" + c) } ?? ss3(c)
      case 5...12: return tilde([15, 17, 18, 19, 20, 21, 23, 24][n - 5])
      default: return []
      }
    case .enter: return m.contains(.alt) ? [esc, 0x0D] : [0x0D]
    case .tab: return m.contains(.shift) ? csi("Z") : [0x09]
    case .backspace:
      let b: UInt8 = m.contains(.control) ? 0x08 : 0x7F
      return m.contains(.alt) ? [esc, b] : [b]
    case .escape: return [esc]
    }
  }

  /// A typed character's bytes: with Control, its control code where it
  /// has one; with Alt, after ESC.
  public static func encode(character c: UInt32, _ m: KeyModifiers = []) -> [UInt8] {
    var out: [UInt8] = []
    if m.contains(.alt) { out.append(esc) }
    if m.contains(.control) {
      switch c {
      case 0x20, 0x40: return out + [0]
      case 0x61...0x7A: return out + [UInt8(c - 0x60)]
      case 0x41...0x5F: return out + [UInt8(c - 0x40)]
      case 0x3F: return out + [0x7F]
      default: break
      }
    }
    var s = ""
    if let u = Unicode.Scalar(c) { s.unicodeScalars.append(u) }
    return out + Array(s.utf8)
  }

  /// Pasted text: bracketed if the program asked.
  public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
    let bytes = Array(text.utf8)
    return bracketed ? csi("200~") + bytes + csi("201~") : bytes
  }
}
