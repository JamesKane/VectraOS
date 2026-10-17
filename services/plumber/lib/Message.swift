// SPDX-License-Identifier: BSD-3-Clause

// plumb(6)'s message format (D85): the fields src, dst, wdir, type, attr
// and ndata, a line each (a missing one an empty line), then ndata bytes of
// data, which alone may hold newlines. attr is `name=value` pairs apart by
// blanks, a value quoted '...' (a quote doubled inside) when it holds a
// blank, a quote or an equals sign, as plumbpackattr writes them.

extension RouteMessage {
  /// The message in plumb(6)'s form.
  public var packed: [UInt8] {
    var out: [UInt8] = []
    for field in [src, dst, wdir, type, Self.packAttributes(attrs)] { out += Array(field.utf8) + [0x0A] }
    let data = Array(data.utf8)
    out += Array(String(data.count).utf8) + [0x0A] + data
    return out
  }

  /// A message read from plumb(6)'s form, or nil if it isn't one: six
  /// lines, then exactly ndata bytes.
  public init?(packed bytes: [UInt8]) {
    var fields: [String] = []
    var at = 0
    for _ in 0..<6 {
      guard let nl = bytes[at...].firstIndex(of: 0x0A) else { return nil }
      fields.append(String(decoding: bytes[at..<nl], as: UTF8.self))
      at = nl + 1
    }
    var n = 0
    for b in fields[5].utf8 {
      guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9"), n < 1 << 24 else { return nil }
      n = n * 10 + Int(b - UInt8(ascii: "0"))
    }
    guard !fields[5].isEmpty, bytes.count - at == n, let attrs = Self.unpackAttributes(fields[4]) else { return nil }
    self.init(src: fields[0], dst: fields[1], wdir: fields[2], type: fields[3],
              data: String(decoding: bytes[at...], as: UTF8.self), attrs: attrs)
  }

  static func packAttributes(_ attrs: [(name: String, value: String)]) -> String {
    var out: [UInt8] = []
    for (i, a) in attrs.enumerated() {
      if i > 0 { out.append(0x20) }
      out += Array(a.name.utf8) + [UInt8(ascii: "=")]
      let v = Array(a.value.utf8)
      if v.isEmpty || v.contains(where: { $0 == 0x20 || $0 == 0x09 || $0 == UInt8(ascii: "'") || $0 == UInt8(ascii: "=") }) {
        out.append(UInt8(ascii: "'"))
        for b in v {
          if b == UInt8(ascii: "'") { out.append(b) }
          out.append(b)
        }
        out.append(UInt8(ascii: "'"))
      } else {
        out += v
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func unpackAttributes(_ text: String) -> [(name: String, value: String)]? {
    let b = Array(text.utf8)
    var out: [(name: String, value: String)] = []
    var i = 0
    while i < b.count {
      while i < b.count, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
      guard i < b.count else { break }
      var name: [UInt8] = []
      while i < b.count, b[i] != UInt8(ascii: "="), b[i] != 0x20 { name.append(b[i]); i += 1 }
      guard i < b.count, b[i] == UInt8(ascii: "="), !name.isEmpty else { return nil }
      i += 1
      var value: [UInt8] = []
      if i < b.count, b[i] == UInt8(ascii: "'") {
        i += 1
        while true {
          guard i < b.count else { return nil }  // an unclosed quote
          if b[i] == UInt8(ascii: "'") {
            if i + 1 < b.count, b[i + 1] == UInt8(ascii: "'") {
              value.append(b[i])
              i += 2
              continue
            }
            i += 1
            break
          }
          value.append(b[i])
          i += 1
        }
      } else {
        while i < b.count, b[i] != 0x20, b[i] != 0x09 { value.append(b[i]); i += 1 }
      }
      out.append((String(decoding: name, as: UTF8.self), String(decoding: value, as: UTF8.self)))
    }
    return out
  }
}
