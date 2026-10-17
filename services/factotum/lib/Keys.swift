// SPDX-License-Identifier: BSD-3-Clause

// Keys and patterns, as Plan 9's factotum writes them (M6k part k4b;
// architecture §17). A key is a list of attributes:
//
//     key proto=scram-sha-256 server=mail.example user=jk !password=secret
//
// a name starting with `!` is secret: it never leaves factotum (a
// listing shows `!password?`). `confirm=always|once|never` says whether
// using the key asks the user first (`once`: once per app session); a
// key's protocol has its own default (`pass`, which reveals the secret,
// always asks). A value with spaces is quoted, rc-style: 'two words',
// '' for a quote.
//
// A pattern is attributes that must match, `name=value`, and attributes
// that must be present, `name?`:
//
//     proto=scram-sha-256 server=mail.example user?
//
// Tier 0: the keys are an array (no Dictionary), searched in order, and
// names and values are compared as bytes (`same`): String's == needs
// Unicode's tables, which tier 0 links without.

public struct KeyAttribute: Equatable, Sendable {
  public var name: String
  public var value: String
  /// Its name had `!`: never shown, never sent.
  public var secret: Bool
  public init(_ name: String, _ value: String, secret: Bool = false) {
    self.name = name
    self.value = value
    self.secret = secret
  }
}

public struct Key: Equatable, Sendable {
  public var attributes: [KeyAttribute]
  public init(_ attributes: [KeyAttribute]) { self.attributes = attributes }

  /// Attribute `name`'s value, public or secret.
  public subscript(_ name: String) -> String? { attributes.first { same($0.name, name) }?.value }

  public var proto: String { self["proto"] ?? "" }

  /// The key as text with its secrets hidden (`!password?`): what a
  /// listing shows.
  public var shown: String {
    attributes.map { $0.secret ? "!" + $0.name + "?" : $0.name + "=" + quoted($0.value) }.joined(separator: " ")
  }

  /// The key as text, secrets included (only factotum's own store).
  public var text: String {
    attributes.map { ($0.secret ? "!" : "") + $0.name + "=" + quoted($0.value) }.joined(separator: " ")
  }
}

public enum KeyError: Error, Equatable, Sendable {
  /// A word that isn't `name=value` (or `name?` in a pattern), with where.
  case syntax(String)
}

/// A pattern of attributes a key must have.
public struct KeyPattern: Equatable, Sendable {
  public struct Term: Equatable, Sendable {
    public var name: String
    /// nil: the attribute must be present, with any value (`name?`).
    public var value: String?
  }
  public var terms: [Term]
  public init(terms: [Term]) { self.terms = terms }

  public init(_ text: String) throws(KeyError) {
    var terms: [Term] = []
    for word in try words(text) {
      if word.utf8.last == UInt8(ascii: "?"), !word.utf8.contains(UInt8(ascii: "=")) {
        terms.append(Term(name: String(decoding: word.utf8.dropLast(), as: UTF8.self).trimmingBang, value: nil))
      } else if let (name, value) = split(word) {
        terms.append(Term(name: name.trimmingBang, value: value))
      } else {
        throw .syntax(word)
      }
    }
    self.terms = terms
  }

  /// Whether `key` has every term's attribute (and value). A secret
  /// attribute matches only `name?`: a pattern can't test a secret's
  /// value, or a client could guess it one try at a time.
  public func matches(_ key: Key) -> Bool {
    terms.allSatisfy { t in
      key.attributes.contains { same($0.name, t.name) && (t.value == nil || (!$0.secret && same(t.value, $0.value))) }
    }
  }

  /// Attribute `name`'s value in the pattern, if it fixes one.
  public subscript(_ name: String) -> String? { terms.first { same($0.name, name) }?.value ?? nil }

  /// This pattern with `name=value` (replacing a term for `name`).
  public func with(_ name: String, _ value: String) -> KeyPattern {
    KeyPattern(terms: terms.filter { !same($0.name, name) } + [Term(name: name, value: value)])
  }

  /// Whether every key this pattern matches is one `scope` allows: it
  /// fixes each of the scope's attributes to the scope's value.
  public func within(_ scope: KeyPattern) -> Bool {
    scope.terms.allSatisfy { s in
      terms.contains { t in
        same(t.name, s.name) && t.value != nil && (s.value.map { same(t.value, $0) } ?? true)
      }
    }
  }

  public var text: String {
    terms.map { t in t.value.map { t.name + "=" + quoted($0) } ?? t.name + "?" }.joined(separator: " ")
  }
}

extension Key {
  /// A key from its text (`key` first is allowed, as factotum's ctl
  /// takes it).
  public init(parsing text: String) throws(KeyError) {
    var w = try words(text)
    if same(w.first, "key") { w.removeFirst() }
    var attributes: [KeyAttribute] = []
    for word in w {
      guard let (name, value) = split(word) else { throw .syntax(word) }
      let secret = name.utf8.first == UInt8(ascii: "!")
      attributes.append(KeyAttribute(secret ? String(decoding: name.utf8.dropFirst(), as: UTF8.self) : name, value,
                                     secret: secret))
    }
    guard attributes.contains(where: { same($0.name, "proto") }) else { throw .syntax("no proto") }
    self.init(attributes)
  }
}

/// factotum's keys, in the order they were added.
public struct KeyStore: Sendable {
  public private(set) var keys: [Key] = []
  public init() {}

  /// Adds a key; one with the same public attributes is replaced.
  public mutating func add(_ key: Key) {
    let pub = key.attributes.filter { !$0.secret }
    keys.removeAll { k in
      let other = k.attributes.filter { !$0.secret }
      return other.count == pub.count
        && zip(other, pub).allSatisfy { same($0.name, $1.name) && same($0.value, $1.value) }
    }
    keys.append(key)
  }

  /// Removes the keys `pattern` matches; how many.
  @discardableResult
  public mutating func delete(_ pattern: KeyPattern) -> Int {
    let before = keys.count
    keys.removeAll { pattern.matches($0) }
    return before - keys.count
  }

  /// The keys `pattern` matches.
  public func matching(_ pattern: KeyPattern) -> [Key] { keys.filter { pattern.matches($0) } }

  /// Every key with its secrets hidden, a line each.
  public var listing: String { keys.map { "key " + $0.shown + "\n" }.joined() }

  /// Factotum's ctl: `key ATTRS` adds, `delkey PATTERN` deletes. What
  /// it did, or the error.
  public mutating func control(_ line: String) throws(KeyError) -> String {
    let w = try words(line)
    guard let verb = w.first else { return "" }
    if same(verb, "key") {
      add(try Key(parsing: line))
      return "added"
    }
    if same(verb, "delkey") {
      let rest = w.dropFirst().map { quoted($0) }.joined(separator: " ")
      return "deleted \(delete(try KeyPattern(rest)))"
    }
    throw .syntax(verb)
  }
}

// MARK: Words

/// `text`'s words: split at blanks, rc's quoting ('a b', '' a quote).
func words(_ text: String) throws(KeyError) -> [String] {
  var out: [String] = []
  var word: [UInt8] = []
  var inWord = false, quoting = false
  let b = Array(text.utf8)
  var i = 0
  while i < b.count {
    let c = b[i]
    if quoting {
      if c == UInt8(ascii: "'") {
        if i + 1 < b.count && b[i + 1] == UInt8(ascii: "'") {
          word.append(c)
          i += 1
        } else {
          quoting = false
        }
      } else {
        word.append(c)
      }
    } else if c == UInt8(ascii: "'") {
      quoting = true
      inWord = true
    } else if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      if inWord { out.append(String(decoding: word, as: UTF8.self)) }
      word.removeAll()
      inWord = false
    } else {
      word.append(c)
      inWord = true
    }
    i += 1
  }
  if quoting { throw .syntax("an unfinished quote") }
  if inWord { out.append(String(decoding: word, as: UTF8.self)) }
  return out
}

/// `name=value` split at its first `=`.
func split(_ word: String) -> (String, String)? {
  let b = Array(word.utf8)
  guard let eq = b.firstIndex(of: UInt8(ascii: "=")), eq > 0 else { return nil }
  return (String(decoding: b[..<eq], as: UTF8.self), String(decoding: b[(eq + 1)...], as: UTF8.self))
}

/// A value as a word: quoted if it has blanks or quotes, or is empty.
func quoted(_ v: String) -> String {
  let special = v.utf8.isEmpty
    || v.utf8.contains { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == UInt8(ascii: "'") }
  guard special else { return v }
  var out: [UInt8] = [UInt8(ascii: "'")]
  for c in v.utf8 {
    out.append(c)
    if c == UInt8(ascii: "'") { out.append(c) }
  }
  out.append(UInt8(ascii: "'"))
  return String(decoding: out, as: UTF8.self)
}

extension String {
  /// Without a leading `!` (a pattern names secret attributes plainly).
  var trimmingBang: String { utf8.first == UInt8(ascii: "!") ? String(decoding: utf8.dropFirst(), as: UTF8.self) : self }
}

/// Whether two strings are the same bytes.
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// Whether an optional string is `b`'s bytes.
func same(_ a: String?, _ b: String) -> Bool { a.map { same($0, b) } ?? false }
