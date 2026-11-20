// SPDX-License-Identifier: BSD-3-Clause

// The count of `unsafe` in drivers (D172): which unit a path belongs to,
// how many lines of a Swift source carry the keyword, and the record the
// count is held to. `vx loc --check` reads the files and calls these.

/// The lines of `source` that have an `unsafe` token on them.
///
/// A token is the identifier `unsafe` on its own: the expression keyword
/// (`unsafe foo()`), the attribute (`@unsafe`) and the `unsafe` of a
/// modifier (`nonisolated(unsafe)`). `unsafeBitCast`, `withUnsafeBytes`
/// and `.unsafe` (a member's name) are other identifiers.
/// `@safe(unchecked)` has no such token and doesn't count: it is a promise
/// that a type is safe, not a use. Comments (block comments nest) and
/// string literals (single, multi-line, raw) are skipped, and so is the
/// text of an interpolation in a string. A line with several tokens is one
/// line, as the roadmap counts.
public func unsafeLines(in source: String) -> Int {
  let bytes = Array(source.utf8)
  let n = bytes.count
  var i = 0
  var line = 0
  var lastCounted = -1
  var total = 0
  let word = Array("unsafe".utf8)

  func isIdent(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || b == 0x5f || b >= 0x80
  }

  /// `j` is just past a `\(`; returns just past its matching `)`.
  func skipInterpolation(_ start: Int) -> Int {
    var j = start
    var depth = 1
    while j < n, depth > 0 {
      let c = bytes[j]
      if c == 0x28 {
        depth += 1
      } else if c == 0x29 {
        depth -= 1
      } else if c == 0x22 {  // a nested simple string
        j += 1
        while j < n, bytes[j] != 0x22, bytes[j] != 0x0a {
          if bytes[j] == 0x5c { j += 1 }
          j += 1
        }
      } else if c == 0x0a {
        line += 1
      }
      j += 1
    }
    return j
  }

  while i < n {
    let b = bytes[i]
    if b == 0x0a {
      line += 1
      i += 1
    } else if b == 0x2f, i + 1 < n, bytes[i + 1] == 0x2f {  // a line comment
      while i < n, bytes[i] != 0x0a { i += 1 }
    } else if b == 0x2f, i + 1 < n, bytes[i + 1] == 0x2a {  // a block comment
      var depth = 1
      i += 2
      while i < n, depth > 0 {
        if bytes[i] == 0x2f, i + 1 < n, bytes[i + 1] == 0x2a {
          depth += 1
          i += 2
        } else if bytes[i] == 0x2a, i + 1 < n, bytes[i + 1] == 0x2f {
          depth -= 1
          i += 2
        } else {
          if bytes[i] == 0x0a { line += 1 }
          i += 1
        }
      }
    } else if b == 0x22 || b == 0x23 {  // a quote, or hashes that may lead one
      var hashes = 0
      var j = i
      while j < n, bytes[j] == 0x23 { hashes += 1; j += 1 }
      guard j < n, bytes[j] == 0x22 else {
        i = j  // `#if`, `#expect`: the directive's name is read next
        continue
      }
      j += 1
      var multi = false
      if j + 1 < n, bytes[j] == 0x22, bytes[j + 1] == 0x22 { multi = true; j += 2 }
      scan: while j < n {
        let c = bytes[j]
        if c == 0x0a {
          line += 1
          if !multi { break scan }  // unterminated: go on from the next line
        } else if c == 0x5c {  // an escape: `\` and the hashes of a raw string
          var k = 0
          while k < hashes, j + 1 + k < n, bytes[j + 1 + k] == 0x23 { k += 1 }
          if k == hashes, j + 1 + k < n {
            if bytes[j + 1 + k] == 0x28 {
              j = skipInterpolation(j + 2 + k)
              continue scan
            }
            if bytes[j + 1 + k] == 0x0a { line += 1 }
            j += 1 + k
          }
        } else if c == 0x22 {
          var q = 1
          if multi { while q < 3, j + q < n, bytes[j + q] == 0x22 { q += 1 } }
          if !multi || q == 3 {
            var k = 0
            while k < hashes, j + q + k < n, bytes[j + q + k] == 0x23 { k += 1 }
            if k == hashes { j += q + hashes - 1; break scan }
          }
        }
        j += 1
      }
      i = j + 1
    } else if isIdent(b) {
      let start = i
      while i < n, isIdent(bytes[i]) { i += 1 }
      if i - start == word.count, bytes[start..<i].elementsEqual(word),
        !(start > 0 && bytes[start - 1] == 0x2e), lastCounted != line
      {
        lastCounted = line
        total += 1
      }
    } else {
      i += 1
    }
  }
  return total
}

/// The unit a path is counted in, or nil if it isn't counted: for Swift
/// under `drivers/`, `drivers/<class>/<name>` (a driver, a class's shared
/// `lib` or `client`, a bus library) and `drivers/devmgr`. Not counted:
/// `drivers/host` (DriverHost, the one audited runtime), anything under a
/// `tests` directory (host test code and native test programs), and files
/// directly in a class directory.
public func unsafeUnit(of path: String) -> String? {
  guard path.hasSuffix(".swift"), path.hasPrefix("drivers/") else { return nil }
  let parts = path.split(separator: "/").map(String.init)
  guard parts.count >= 3 else { return nil }
  if parts.dropLast().contains("tests") { return nil }
  if parts[1] == "host" { return nil }
  if parts[1] == "devmgr" { return "drivers/devmgr" }
  guard parts.count >= 4 else { return nil }
  return "drivers/\(parts[1])/\(parts[2])"
}

/// Parse the record: `unit<TAB>count` lines, `#` comments and blank lines
/// skipped. A line that isn't a unit and a positive count, or repeats a
/// unit, is a problem.
public func parseUnsafeRecord(_ text: String) -> (record: [String: Int], problems: [String]) {
  var record: [String: Int] = [:]
  var problems: [String] = []
  for (k, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
    let line = String(raw)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
    if f.count == 2, let n = Int(f[1]), n > 0, record[String(f[0])] == nil {
      record[String(f[0])] = n
    } else {
      problems.append("docs/unsafe.tsv line \(k + 1): `\(line)` is not a unit, a tab and a positive count, once")
    }
  }
  return (record, problems)
}

/// What the counts say against the record. Over it fails; under it fails
/// too, saying to lower the record (it only falls, and a stale number would
/// let the count climb back). A unit absent from the record has zero.
public func judgeUnsafe(counts: [String: Int], record: [String: Int]) -> [String] {
  var out: [String] = []
  for unit in Set(counts.keys).union(record.keys).sorted() {
    let have = counts[unit] ?? 0
    let limit = record[unit] ?? 0
    if have > limit {
      out.append("\(unit) has \(have) lines with `unsafe`, over its record of \(limit) (D172)")
    } else if have < limit {
      out.append("\(unit) has \(have) lines with `unsafe`, under its record of \(limit): lower it in docs/unsafe.tsv (D172)")
    }
  }
  return out
}
