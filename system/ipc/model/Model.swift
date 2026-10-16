// SPDX-License-Identifier: BSD-3-Clause

// An IPC library as the macro and idlc see it: its structs and enums, its
// protocols, their methods, and every type's place on the wire
// (docs/wire-format.md).

import IPCWire

/// A type on the wire.
public indirect enum WireType: Equatable, Sendable {
  case integer(String, size: Int)  // the Swift type name, its byte size
  case bool
  case string
  case bytes  // [UInt8]
  case handle
  case vector(WireType)
  case optional(WireType)
  case structure(String)  // a struct of the library
  case enumeration(String)  // an integer-backed enum of the library

  /// The types every library knows, by name.
  public static func builtin(_ name: String) -> WireType? {
    switch name {
    case "UInt8", "Int8": .integer(name, size: 1)
    case "UInt16", "Int16": .integer(name, size: 2)
    case "UInt32", "Int32": .integer(name, size: 4)
    case "UInt64", "Int64": .integer(name, size: 8)
    case "Bool": .bool
    case "String": .string
    case "Handle": .handle
    default: nil
    }
  }

  /// The canonical Swift spelling, which baselines and pages use.
  public var swiftName: String {
    switch self {
    case .integer(let t, _): t
    case .bool: "Bool"
    case .string: "String"
    case .bytes: "[UInt8]"
    case .handle: "Handle"
    case .vector(let e): "[\(e.swiftName)]"
    case .optional(let w): "\(w.swiftName)?"
    case .structure(let n), .enumeration(let n): n
    }
  }

  /// Whether an optional of this type uses the type's own presence marker
  /// (a count and marker, or a handle's marker) rather than a box.
  public var hasOwnPresence: Bool {
    switch self {
    case .string, .bytes, .vector, .handle: true
    default: false
    }
  }
}

/// A struct of the library: fields laid out like a body's, rounded up to
/// the struct's alignment.
public struct StructModel: Sendable {
  public var name: String
  /// Declared `~Copyable`: required when it carries handles.
  public var isCopyable: Bool
  public var fields: [(name: String, swiftType: String, type: WireType)]
  public var layout = Layout()
  public var alignment = 1
}

/// An integer-backed enum of the library. Receivers reject values it
/// doesn't list.
public struct EnumModel: Sendable {
  public var name: String
  public var rawType: String
  public var size: Int
  public var cases: [(name: String, value: Int64)]
}

/// An error enum: `Int32`-backed, `IPCErrorCode`, positive codes.
public struct ErrorEnumModel: Sendable {
  public var name: String
  public var cases: [(name: String, code: Int32)]
}

/// The library's named types: what sizes and layouts are resolved against.
public struct Types: Sendable {
  public var structs: [StructModel] = []
  public var enums: [EnumModel] = []

  public init() {}

  public func structure(_ name: String) -> StructModel? { structs.first { $0.name == name } }
  public func enumeration(_ name: String) -> EnumModel? { enums.first { $0.name == name } }

  /// Bytes a value of `t` takes inline.
  public func size(_ t: WireType) -> Int {
    switch t {
    case .integer(_, let size): size
    case .bool: 1
    case .string, .bytes, .vector: 16
    case .handle: 4
    case .optional(let w): w.hasOwnPresence ? size(w) : 8
    case .structure(let n): structure(n)?.layout.size ?? 0
    case .enumeration(let n): enumeration(n)?.size ?? 0
    }
  }

  public func alignment(_ t: WireType) -> Int {
    switch t {
    case .integer(_, let size): size
    case .bool: 1
    case .string, .bytes, .vector: 8
    case .handle: 4
    case .optional(let w): w.hasOwnPresence ? alignment(w) : 8
    case .structure(let n): structure(n)?.alignment ?? 1
    case .enumeration(let n): enumeration(n)?.size ?? 1
    }
  }

  /// Whether a value of `t` carries handles, and so moves when sent.
  public func hasHandles(_ t: WireType) -> Bool {
    switch t {
    case .handle: true
    case .optional(let w), .vector(let w): hasHandles(w)
    case .structure(let n): structure(n)?.fields.contains { hasHandles($0.type) } ?? false
    default: false
    }
  }

  /// Whether `t` is a Swift `Copyable` type.
  public func isCopyable(_ t: WireType) -> Bool {
    switch t {
    case .handle: false
    case .optional(let w): isCopyable(w)
    case .structure(let n): structure(n)?.isCopyable ?? true
    default: true
    }
  }

  /// The named types `roots` use, directly or through others, in the order
  /// the library declares them.
  public func used(by roots: [WireType]) -> (structs: [StructModel], enums: [EnumModel]) {
    var names: [String] = []
    func visit(_ t: WireType) {
      switch t {
      case .vector(let w), .optional(let w): visit(w)
      case .enumeration(let n): if !names.contains(n) { names.append(n) }
      case .structure(let n):
        guard !names.contains(n) else { return }
        names.append(n)
        for f in structure(n)?.fields ?? [] { visit(f.type) }
      default: break
      }
    }
    roots.forEach(visit)
    return (structs.filter { names.contains($0.name) }, enums.filter { names.contains($0.name) })
  }
}

/// A field in an inline part or a struct: where it is and what it holds.
public struct Field: Sendable {
  public var name: String  // the Swift name used in generated code
  public var type: WireType
  public var offset: Int
  public var size: Int
}

/// Fields laid out in order, each naturally aligned; the padding between
/// them, and the size rounded up to `rounding` (8 for a body, the
/// alignment for a struct).
public struct Layout: Sendable {
  public var fields: [Field] = []
  public var padding: [(offset: Int, count: Int)] = []
  public var size = 0

  public init() {}

  public init(_ members: [(name: String, type: WireType)], types: Types, rounding: Int = wireAlignment) {
    var end = 0
    for member in members {
      let alignment = types.alignment(member.type), size = types.size(member.type)
      let offset = (end + alignment - 1) / alignment * alignment
      if offset > end { padding.append((end, offset - end)) }
      fields.append(Field(name: member.name, type: member.type, offset: offset, size: size))
      end = offset + size
    }
    self.size = (end + rounding - 1) / rounding * rounding
    if self.size > end { padding.append((end, self.size - end)) }
  }
}

/// A method's parameter.
public struct Parameter: Sendable {
  public var label: String?  // nil for `_`
  public var name: String
  public var swiftType: String  // as written, without `consuming`
  public var type: WireType
}

/// What a method is.
public enum MethodKind: Sendable {
  case call  // request and reply
  case oneway  // request only
  case event  // sent by the server
}

/// A method of a protocol.
public struct Method: Sendable {
  public var name: String
  public var kind: MethodKind
  public var since: Int
  public var parameters: [Parameter]
  public var result: (swiftType: String, type: WireType)?
  public var errorType: String?  // the `throws(E)` type, if any
  public var ordinal: UInt64
  public var request = Layout()
  public var reply = Layout()

  /// Every type the method's messages hold.
  public var types: [WireType] { parameters.map(\.type) + (result.map { [$0.type] } ?? []) }
}

/// A protocol of the library.
public struct ProtocolModel: Sendable {
  public var name: String
  /// The library's id and the protocol's name: "todhchai.node.Node".
  public var id: String
  public var version: Int
  /// Its own methods.
  public var methods: [Method]
  /// The protocols it composes, as written: "Attributes" in this library,
  /// "NodeIPC.Node" in another. Their methods are its methods too, with
  /// their own ordinals (FIDL's `compose`, a mixin: no "is a").
  public var composes: [String] = []

  /// The named types its methods use.
  public func used(_ types: Types) -> (structs: [StructModel], enums: [EnumModel]) {
    types.used(by: methods.flatMap(\.types))
  }
}

/// The ordinal of `method` in protocol `id` (docs/wire-format.md).
public func ordinal(protocolID id: String, method: String) -> UInt64 {
  let name = Array("\(id).\(method)".utf8)
  return methodOrdinal(name.span)
}
