// SPDX-License-Identifier: BSD-3-Clause

// The files a TraceSession exports over the console (system/trace/session),
// reassembled: after todhchai's `td boot`, as `vx trace collect`. Lines
// carry `td-trace NAME OFFSET BASE64`, `td-trace NAME OFFSET zero COUNT`
// and, at each file's end, `td-trace NAME end SIZE`, after whatever the
// console put before them (the debuglog's prefix).

public enum TraceExport {
  public struct Damage: Error, CustomStringConvertible, Equatable {
    public let description: String
  }

  /// Every file the lines carry, by name, each read as a trace; a piece
  /// the console dropped is damage (a piece sent twice is taken once).
  public static func reassemble(_ lines: [String]) -> Result<[(name: String, bytes: [UInt8])], Damage> {
    var pieces: [String: [Int: [UInt8]]] = [:]
    var sizes: [String: Int] = [:]
    for line in lines {
      let all = line.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
      guard let at = all.firstIndex(of: "td-trace") else { continue }
      let words = Array(all[(at + 1)...])
      guard words.count >= 3 else { continue }  // a line the console cut short
      let name = words[0]
      if words[1] == "end" {
        if let n = Int(words[2]) { sizes[name] = n }
        continue
      }
      guard let offset = Int(words[1]) else { continue }
      if words.count == 4, words[2] == "zero", let n = Int(words[3]) {
        pieces[name, default: [:]][offset] = [UInt8](repeating: 0, count: n)
      } else if words.count == 3, let data = base64(words[2]) {
        pieces[name, default: [:]][offset] = data
      }
    }
    var files: [(name: String, bytes: [UInt8])] = []
    for (name, size) in sizes.sorted(by: { $0.key < $1.key }) {
      var bytes: [UInt8] = []
      while bytes.count < size {
        guard let piece = pieces[name]?[bytes.count], !piece.isEmpty else {
          return .failure(Damage(description: "\(name): the piece at \(bytes.count) is missing (the console dropped it)"))
        }
        bytes += piece
      }
      guard bytes.count == size else { return .failure(Damage(description: "\(name) is \(bytes.count) bytes, not \(size)")) }
      do {
        _ = try TraceFile(bytes: bytes)
      } catch {
        return .failure(Damage(description: "\(name) doesn't read as a trace: \(error)"))
      }
      files.append((name, bytes))
    }
    if let lost = pieces.keys.sorted().first(where: { sizes[$0] == nil }) {
      return .failure(Damage(description: "\(lost) has no end"))
    }
    return .success(files)
  }

  /// RFC 4648 base64, padded; nil if it isn't.
  static func base64(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []
    var value: UInt32 = 0, bits = 0, padding = 0
    for c in text.utf8 {
      let v: UInt32
      switch c {
      case UInt8(ascii: "A")...UInt8(ascii: "Z"): v = UInt32(c - UInt8(ascii: "A"))
      case UInt8(ascii: "a")...UInt8(ascii: "z"): v = UInt32(c - UInt8(ascii: "a")) + 26
      case UInt8(ascii: "0")...UInt8(ascii: "9"): v = UInt32(c - UInt8(ascii: "0")) + 52
      case UInt8(ascii: "+"): v = 62
      case UInt8(ascii: "/"): v = 63
      case UInt8(ascii: "="):
        padding += 1
        continue
      default: return nil
      }
      guard padding == 0 else { return nil }
      value = value << 6 | v
      bits += 6
      if bits >= 8 {
        bits -= 8
        out.append(UInt8(truncatingIfNeeded: value >> UInt32(bits)))
      }
    }
    guard (text.utf8.count % 4 == 0), padding <= 2 else { return nil }
    return out
  }
}
