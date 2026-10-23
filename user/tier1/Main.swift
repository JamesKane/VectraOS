// SPDX-License-Identifier: BSD-3-Clause

// Full Swift on croi (M6e): a program built by the *-vectraos swiftc
// against the toolchain's runtime and standard library in tier 1's sysroot,
// over our libc, libc++ and the floor. Existentials, generics across
// modules (Inventory), classes and ARC, Codable through an encoder of its
// own, Mirror and dynamic casts (the runtime's metadata, which swiftrt.o
// registers), key paths, errors, Unicode, Regex, floating point printed
// and parsed, hashing (seeded from croi's CPRNG), CommandLine and the
// environment, and a thread through the platform module. Exits 0 if all
// held. It is linked against the shared runtime (D124), and reports its
// spawn to main beside m2's for a static program: from userboot's
// croi.spawn_ns= to its first line, the loading, binding and the
// libraries' initializers between (process.spawn_to_main.linked).

import Inventory
import VectraOSLibc

var entered = timespec()
_ = clock_gettime(CLOCK_MONOTONIC, &entered)
if let spawned = getenv("croi.spawn_ns").flatMap({ Int64(String(cString: $0)) }) {
  let at = Int64(entered.tv_sec) * 1_000_000_000 + Int64(entered.tv_nsec)
  print("swift-hello: budget name=process.spawn_to_main.linked value=\(at - spawned) unit=ns")
}

var failures = 0
func check(_ ok: Bool, _ what: String) {
  if !ok {
    print("swift-hello: FAILED: \(what)")
    failures += 1
  }
}

// Existentials and generics across modules.
struct Crate: Weighed, Codable, Hashable {
  var label: String
  var weight: Int
  var tags: [String]
}
var shelf = Shelf<Crate>()
shelf.put(Crate(label: "a", weight: 3, tags: ["x"]))
shelf.put(Crate(label: "b", weight: 9, tags: []))
shelf.put(Crate(label: "c", weight: 5, tags: ["y", "z"]))
check(shelf.total == 17 && shelf.heaviest()?.label == "b", "generics across modules")
let anyWeighed: [any Weighed] = shelf.items
check(anyWeighed.count == 3, "existentials with associated types")

// Classes, subclasses across modules, ARC and deinit.
final class Box: Tracked {
  override func describe() -> String { "box \(name)" }
}
do {
  let boxes = (0..<10).map { Box(name: "\($0)") }
  check(Tracked.alive == 10 && boxes[3].describe() == "box 3", "classes and overrides")
}
check(Tracked.alive == 0, "deinit when the last reference goes")

// Codable, through a small encoder of our own (no Foundation yet).
final class FlatEncoder: Encoder {
  var codingPath: [any CodingKey] = []
  var userInfo: [CodingUserInfoKey: Any] = [:]
  var out: [String] = []
  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    KeyedEncodingContainer(Keyed<Key>(encoder: self))
  }
  func unkeyedContainer() -> any UnkeyedEncodingContainer { Unkeyed(encoder: self) }
  func singleValueContainer() -> any SingleValueEncodingContainer { Single(encoder: self) }

  struct Single: SingleValueEncodingContainer {
    let encoder: FlatEncoder
    var codingPath: [any CodingKey] { [] }
    mutating func encodeNil() throws { encoder.out.append("nil") }
    mutating func encode(_ value: String) throws { encoder.out.append(value) }
    mutating func encode(_ value: Int) throws { encoder.out.append("\(value)") }
    mutating func encode<T: Encodable>(_ value: T) throws { try value.encode(to: encoder) }
  }

  struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: FlatEncoder
    var codingPath: [any CodingKey] { [] }
    mutating func encodeNil(forKey key: Key) throws { encoder.out.append("\(key.stringValue)=nil") }
    mutating func encode(_ value: String, forKey key: Key) throws { encoder.out.append("\(key.stringValue)=\(value)") }
    mutating func encode(_ value: Int, forKey key: Key) throws { encoder.out.append("\(key.stringValue)=\(value)") }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
      encoder.out.append("\(key.stringValue)=[")
      try value.encode(to: encoder)
      encoder.out.append("]")
    }
    mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey: Key) -> KeyedEncodingContainer<N> {
      fatalError("unused")
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { fatalError("unused") }
    mutating func superEncoder() -> any Encoder { encoder }
    mutating func superEncoder(forKey key: Key) -> any Encoder { encoder }
  }
  struct Unkeyed: UnkeyedEncodingContainer {
    let encoder: FlatEncoder
    var codingPath: [any CodingKey] { [] }
    var count = 0
    mutating func encodeNil() throws { encoder.out.append("nil") }
    mutating func encode(_ value: String) throws {
      encoder.out.append(value)
      count += 1
    }
    mutating func encode<T: Encodable>(_ value: T) throws { try value.encode(to: encoder) }
    mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type) -> KeyedEncodingContainer<N> { fatalError("unused") }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { fatalError("unused") }
    mutating func superEncoder() -> any Encoder { encoder }
  }
}
let encoder = FlatEncoder()
try? shelf.items[2].encode(to: encoder)
check(encoder.out.joined(separator: ",") == "label=c,weight=5,tags=[,y,z,]", "Codable: \(encoder.out)")

// Mirror and dynamic casts: the runtime's metadata.
let mirror = Mirror(reflecting: shelf.items[0])
check(mirror.children.map { $0.label ?? "" } == ["label", "weight", "tags"], "Mirror")
let things: [Any] = [1, "two", 3.0, Box(name: "b"), [4]]
check(things.compactMap { $0 as? Tracked }.count == 1 && (things[4] as? [Int]) == [4], "dynamic casts")
check(String(describing: type(of: things[3])) == "Box", "type names")

// Key paths.
let byWeight = \Crate.weight
check(shelf.items.map { $0[keyPath: byWeight] } == [3, 9, 5], "key paths")

// Errors.
enum Problem: Error { case tooHeavy(Int) }
func lift(_ c: Crate) throws(Problem) -> Int {
  if c.weight > 8 { throw .tooHeavy(c.weight) }
  return c.weight
}
var problem = 0
for c in shelf.items {
  do { _ = try lift(c) } catch { if case .tooHeavy(let w) = error { problem = w } }
}
check(problem == 9, "typed throws")

// Unicode, Regex, hashing.
let word = "Tódhchaí 🇮🇪"
check(word.count == 10 && word.unicodeScalars.count == 11 && word.uppercased() == "TÓDHCHAÍ 🇮🇪", "Unicode")
let match = "build 6.4.0-RELEASE".firstMatch(of: #/(\d+)\.(\d+)\.(\d+)/#)
check(match.map { "\($0.1)|\($0.2)|\($0.3)" } == "6|4|0", "Regex")
check(Set(shelf.items).count == 3 && Set([1, 2, 2, 3]).count == 3, "hashing")

// Floating point, printed and parsed.
check("\(0.1 + 0.2)" == "0.30000000000000004" && Double("1e-3") == 0.001 && "\(Float.pi)" == "3.1415925",
      "floating point")

// The command line and the environment.
check(CommandLine.arguments.first?.hasSuffix("swift-hello") == true, "CommandLine")

// A thread through the platform module (pthreads, our libc's).
nonisolated(unsafe) var fromThread = 0
var thread = pthread_t()
let created = pthread_create(&thread, nil, { _ in
  fromThread = (1...100).reduce(0, +)
  return nil
}, nil)
check(created == 0 && pthread_join(thread, nil) == 0 && fromThread == 5050, "a thread")

print("swift-hello: \(failures == 0 ? "passed" : "FAILED")")
exit(failures == 0 ? 0 : 1)
