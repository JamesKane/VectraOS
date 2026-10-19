// SPDX-License-Identifier: BSD-3-Clause

// The clipboard (D112, sdk(2)): one entry of typed representations, held
// by Radharc. Its text is `snarf`, its representations `clip`'s files,
// and `clip/new` takes a whole entry. A program in a rio window has rio's
// at /dev, which pass to Radharc's under rio's rule; any other uses
// Radharc's, at /svc/windows. Reads succeed only for the focused window's
// program after a key or a press, so a read made on a paste key works,
// and one made from a timer is refused. Each call is a channel of its
// own, from any thread.

import Node

public enum Snarf {
  /// The file `name` (`snarf` or `clip`) a program reaches: /dev's, else
  /// Radharc's.
  static func path(_ name: String) -> String? {
    guard let ns = NativeProcess.namespace else { return nil }
    for dir in ["/dev/", "/svc/windows/"] where (try? ns.connect(dir + name)) != nil { return dir + name }
    return nil
  }

  /// The clipboard's text; nil if there is none, or the read is refused.
  public static func read() -> String? {
    guard let ns = NativeProcess.namespace, let p = path("snarf"), var f = try? ns.open(p),
      let b = try? f.read(offset: 0, max: 1 << 20)
    else { return nil }
    return String(decoding: b, as: UTF8.self)
  }

  /// The clipboard is `text` from now on (an entry of it alone).
  @discardableResult
  public static func write(_ text: String) -> Bool {
    guard let ns = NativeProcess.namespace, let p = path("snarf"), var f = try? ns.open(p) else { return false }
    // (The entry is replaced when the channel closes, at the end of scope.)
    return (try? f.write(offset: 0, Array(text.utf8))) != nil
  }

  /// The entry's representations' types, as `clip` names them
  /// (`text.plain`, `image.png`); empty if the read is refused.
  public static func types() -> [String] {
    guard let ns = NativeProcess.namespace, let p = path("clip"), let names = try? ns.list(p) else { return [] }
    return names.map { $0.name }.filter { $0 != "new" }
  }

  /// One representation's bytes, by its `clip` name.
  public static func read(type name: String) -> [UInt8]? {
    guard let ns = NativeProcess.namespace, let p = path("clip"), var f = try? ns.open(p + "/" + name) else { return nil }
    return try? f.readAll()
  }

  /// The clipboard is a new entry: each representation a MIME type and
  /// its bytes, committed whole.
  @discardableResult
  public static func write(_ entry: [(type: String, bytes: [UInt8])]) -> Bool {
    guard let ns = NativeProcess.namespace, let p = path("clip"), var f = try? ns.open(p + "/new") else { return false }
    for r in entry {
      guard (try? f.write(offset: 0, Array("type=\(r.type) length=\(r.bytes.count)\n".utf8) + r.bytes)) != nil else {
        return false
      }
    }
    return true
  }
}
