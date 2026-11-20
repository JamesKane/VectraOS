// SPDX-License-Identifier: BSD-3-Clause

// Firmware packages (D164, firmware(6)): `firmware/packages/NAME.pkg`, a
// text record of the blobs a device needs that a processor on the device
// runs. Each file has its path under a driver's /lib/firmware, its
// SHA-256 and size, and where to read it in a source directory; the
// package has its licence and where the files came from. The blobs
// themselves are never committed: `vx firmware` fills a cache
// (.cache/firmware/PATH) from a source and checks every file against its
// record, and a board image's bootfs takes the cache's files.
//
// Host only. Read as directives (D86), so a record that says something
// this format doesn't know stops the read at its line.

import Directives
import TDCrypto

public struct FirmwareFile: Equatable, Sendable {
  /// Under /lib/firmware: the name a driver asks for.
  public var path: String
  /// Lower-case hexadecimal.
  public var sha256: String
  public var size: Int
  /// Where it is in a source directory, `path` unless the record says.
  public var from: String
}

public struct FirmwarePackage: Equatable, Sendable {
  public var name: String
  /// The arch whose board images carry it.
  public var arch: String
  public var licence = ""
  public var source = ""
  public var files: [FirmwareFile] = []
  /// Where it was read, "file:line".
  public var origin: String
}

public struct FirmwareError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

public enum Firmware {
  /// The directives a package record takes (firmware(6)).
  public static let directives: [StaticString] = ["package", "arch", "licence", "source", "file"]

  /// The package a record's `text` holds.
  public static func parse(_ text: String, file: String) throws(FirmwareError) -> FirmwarePackage {
    let read: [Directive]
    do throws(DirectiveError) { read = try Directives.read(Array(text.utf8), file: file, known: directives) } catch {
      throw FirmwareError(error.description)
    }
    var package: FirmwarePackage?
    for d in read {
      func fail(_ what: String) -> FirmwareError { FirmwareError("\(file):\(d.line): \(what)") }
      let rest = d.arguments
      if d.is("package") {
        guard package == nil else { throw fail("a record holds one package") }
        guard rest.count == 1, validName(rest[0]) else { throw fail("'package' takes a name") }
        package = FirmwarePackage(name: rest[0], arch: "", origin: "\(file):\(d.line)")
        continue
      }
      guard package != nil else { throw fail("'package' must come first") }
      if d.is("arch") {
        guard rest.count == 1, ["amd64", "arm64", "rv64"].contains(rest[0]) else { throw fail("'arch' takes amd64, arm64 or rv64") }
        package!.arch = rest[0]
      } else if d.is("licence") {
        guard rest.count == 1 else { throw fail("'licence' takes an SPDX id or a licence file's name") }
        package!.licence = rest[0]
      } else if d.is("source") {
        guard !rest.isEmpty else { throw fail("'source' says where the files came from") }
        package!.source = d.text
      } else if d.is("file") {
        guard rest.count == 3 || (rest.count == 5 && rest[3] == "from") else {
          throw fail("'file' takes PATH SHA256 SIZE [from PATH]")
        }
        guard validPath(rest[0]) else { throw fail("'\(rest[0])' isn't a relative path without '..'") }
        guard isHex256(rest[1]) else { throw fail("'\(rest[1])' isn't a SHA-256 in lower-case hexadecimal") }
        guard let size = Int(rest[2]), size > 0 else { throw fail("'\(rest[2])' isn't a size") }
        let from = rest.count == 5 ? rest[4] : rest[0]
        guard validPath(from) else { throw fail("'\(from)' isn't a relative path without '..'") }
        guard !package!.files.contains(where: { $0.path == rest[0] }) else { throw fail("'\(rest[0])' twice") }
        package!.files.append(FirmwareFile(path: rest[0], sha256: rest[1], size: size, from: from))
      }
    }
    guard var package else { throw FirmwareError("\(file): no package") }
    if package.arch.isEmpty { throw FirmwareError("\(package.origin): package '\(package.name)' has no 'arch'") }
    if package.licence.isEmpty { throw FirmwareError("\(package.origin): package '\(package.name)' has no 'licence'") }
    if package.source.isEmpty { throw FirmwareError("\(package.origin): package '\(package.name)' has no 'source'") }
    if package.files.isEmpty { throw FirmwareError("\(package.origin): package '\(package.name)' has no 'file'") }
    package.files.sort { $0.path < $1.path }
    return package
  }

  static func validName(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
  }

  /// A path under a directory: no leading slash, no empty or `..` part.
  static func validPath(_ s: String) -> Bool {
    guard !s.isEmpty, !s.utf8.starts(with: "/".utf8) else { return false }
    for part in s.split(separator: "/", omittingEmptySubsequences: false) where part.isEmpty || part == ".." || part == "." {
      return false
    }
    return true
  }

  static func isHex256(_ s: String) -> Bool {
    s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
  }

  /// The SHA-256 of `bytes`, in lower-case hexadecimal.
  public static func digest(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for b in SHA256.hash(bytes) {
      out.append(digits[Int(b >> 4)])
      out.append(digits[Int(b & 15)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Why `bytes` aren't `file`'s, or nil if they are.
  public static func mismatch(_ file: FirmwareFile, _ bytes: [UInt8]) -> String? {
    if bytes.count != file.size { return "\(file.path): \(bytes.count) bytes, the record says \(file.size)" }
    let actual = digest(bytes)
    if actual != file.sha256 { return "\(file.path): SHA-256 \(actual), the record says \(file.sha256)" }
    return nil
  }

  /// The (package, licence) pairs firmware/README.md accepts: a row of
  /// its Packages table, `| `NAME` | `LICENCE` | ... |`.
  public static func accepted(readme: String) -> [(package: String, licence: String)] {
    var out: [(package: String, licence: String)] = []
    var inTable = false
    for raw in readme.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      if line.hasPrefix("## ") { inTable = line == "## Packages" }
      guard inTable, line.hasPrefix("|") else { continue }
      var cells: [String] = []
      for cell in line.split(separator: "|", omittingEmptySubsequences: false).dropFirst() {
        cells.append(trim(String(cell)))
      }
      guard cells.count >= 2, let name = unquote(cells[0]), let licence = unquote(cells[1]) else { continue }
      out.append((name, licence))
    }
    return out
  }

  /// Refuses a package whose licence the README doesn't accept for it.
  public static func checkLicence(_ package: FirmwarePackage, accepted: [(package: String, licence: String)])
    throws(FirmwareError)
  {
    guard accepted.contains(where: { $0.package == package.name && $0.licence == package.licence }) else {
      throw FirmwareError("\(package.origin): package '\(package.name)': licence '\(package.licence)' isn't accepted in firmware/README.md")
    }
  }

  /// What `driver.manifest`'s `firmware PATH` lines name that no package holds.
  public static func unknown(_ names: [String], in packages: [FirmwarePackage]) -> [String] {
    names.filter { n in !packages.contains { $0.files.contains { $0.path == n } } }
  }

  private static func trim(_ s: String) -> String {
    var u = Array(s.utf8)
    while let f = u.first, f == 0x20 { u.removeFirst() }
    while let l = u.last, l == 0x20 { u.removeLast() }
    return String(decoding: u, as: UTF8.self)
  }

  private static func unquote(_ s: String) -> String? {
    let u = Array(s.utf8)
    guard u.count >= 3, u.first == 0x60, u.last == 0x60 else { return nil }
    return String(decoding: u[1..<(u.count - 1)], as: UTF8.self)
  }
}
