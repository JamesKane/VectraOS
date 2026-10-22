// SPDX-License-Identifier: BSD-3-Clause

// vkgen's Venus output (M5d): Swift that encodes Vulkan commands as Venus
// command streams and decodes their replies, from vk.xml and Venus's
// VK_EXT_command_serialization.xml and VK_MESA_venus_protocol.xml (data,
// data/venus). The encoding is docs/research/venus-protocol.md §3-§5, our
// own words for what venus-protocol's generator does; this generator is
// ours (principle 29). For each command:
//
// - `Venus.vkX(&e, reply:, params…)`: the command (inputs whole, outputs
//   partly: markers, sizes, the client's ids);
// - `Venus.vkX_reply(&d, params…)`: its reply into the caller's outputs;
// - `Venus.vkX_encodeReply(&e, result, params…)`: the reply as the
//   renderer writes it (for tests, and to measure);
// - `Venus.vkX_replySize(params…)`: the reply's size for the outputs given.
//
// Commands or structs the wire can't carry (function pointers, bit fields,
// two-dimensional arrays, other unions) are left out, and so is anything
// that needs them; the header's comment lists what was.

import VulkanGen
import XMLReader

/// What the Venus client driver speaks: core 1.0-1.3 and Venus's own
/// commands. The 1.3.0 renderer knows vk.xml 1.4.334, so nothing past 1.3
/// is needed yet.
public let venusSelection = VulkanSelection(
  maxVersion: "VK_VERSION_1_3",
  extensions: ["VK_EXT_command_serialization", "VK_MESA_venus_protocol"] + venusClientExtensions)

/// Extensions the client driver implements itself (M5j): their types are in
/// the header, but never on the wire (the renderer doesn't know them; their
/// structs are dropped from chains, their commands have no command type).
public let venusClientExtensions = ["VK_FUCHSIA_external_memory"]

/// Commands the renderer refuses (venus-protocol.md §16.3): never encoded.
public let venusRefused: [String] = [
  "vkGetInstanceProcAddr", "vkGetDeviceProcAddr", "vkEnumerateInstanceLayerProperties",
  "vkEnumerateDeviceLayerProperties", "vkMapMemory", "vkUnmapMemory", "vkFlushMappedMemoryRanges",
  "vkInvalidateMappedMemoryRanges", "vkUpdateDescriptorSetWithTemplate", "vkGetDeviceQueue", "vkQueueWaitIdle",
  "vkDeviceWaitIdle",
]

/// The highest command type the 1.3.0 renderer dispatches (§6.2).
public let venusMaxCommandType = 334

/// How a type goes on the wire.
enum Wire: Equatable {
  case scalar(Int)  // 4 or 8 bytes as in memory
  case small  // 8 or 16 bits, in 4 bytes (packed in arrays)
  case size  // size_t: 8 bytes
  case char, void
  case handle
  case structure(String)
  case union(String)
}

/// A struct member or a command parameter.
struct Item {
  var name: String
  var type: String
  var wire: Wire?
  var stars: Int
  var constPointee: Bool
  var dims: Int?  // a fixed array's size
  var bad = false  // a bit field or a two-dimensional array
  var len: [String]
  var altlen: String?
  var sType: String?
}

/// How an item is encoded.
enum Shape {
  case value(Wire)
  case fixed(Wire, Int)
  case pNext
  case string
  case strings(String)  // length expression
  case blob(String)
  case array(Wire, String)
  case single(Wire)
}

public struct VenusGenerator {
  let header: CHeaderGenerator
  var r: VulkanRegistry { header.r }

  var structs: [String: [Item]] = [:]  // supported structs and unions, canonical names
  var sTypes: [String: Int] = [:]  // struct → its sType's value
  var extenders: [String: [String]] = [:]  // base → the structs that may extend it, in vk.xml's order
  var outputs: Set<String> = []  // structs reached from outputs: partial and decode
  var commands: [(name: String, type: Int, proto: Item, params: [Item])] = []
  public private(set) var omitted: [String] = []

  public init(_ header: CHeaderGenerator) throws(VulkanGenError) {
    self.header = header
    try model()
  }

  // MARK: The model

  func canonical(_ name: String) -> String {
    var n = name
    while let a = r.types[n]?.attribute("alias") { n = a }
    return n
  }

  func classify(_ type: String) -> Wire? {
    switch type {
    case "uint32_t", "int32_t", "float", "int": return .scalar(4)
    case "uint64_t", "int64_t", "double": return .scalar(8)
    case "uint8_t", "int8_t", "uint16_t", "int16_t": return .small
    case "size_t": return .size
    case "char": return .char
    case "void": return .void
    default: break
    }
    guard let t = r.types[type] else { return nil }
    if let alias = t.attribute("alias") { return classify(alias) }
    switch t.attribute("category") {
    case "basetype":
      let text = t.innerText(skipping: ["comment"])
      guard text.contains("typedef"), !text.contains("*"), let under = t.element("type")?.innerText() else { return nil }
      return classify(under)
    case "bitmask":
      guard let under = t.element("type")?.innerText() else { return nil }
      return classify(under)
    case "enum": return .scalar(header.is64(type) ? 8 : 4)
    case "handle": return .handle
    case "struct": return .structure(type)
    case "union": return .union(type)
    default: return nil
    }
  }

  func item(_ e: XMLElement) -> Item? {
    guard let name = e.element("name")?.innerText(), let type = e.element("type")?.innerText() else { return nil }
    let text = e.innerText(skipping: ["comment"]).trimmingSpace()
    var it = Item(name: name, type: canonical(type), wire: classify(type), stars: text.filter { $0 == "*" }.count,
                  constPointee: text.hasPrefix("const"), dims: nil, len: [], altlen: e.attribute("altlen"),
                  sType: e.attribute("values"))
    if let l = e.attribute("len") { it.len = l.split(separator: ",").map(String.init) }
    if let after = Self.end(of: name, in: text) {
      let rest = text[after...]
      if rest.contains(":") { it.bad = true }
      let opens = rest.filter { $0 == "[" }.count
      if opens > 1 { it.bad = true }
      if opens == 1, let a = rest.firstIndex(of: "["), let b = rest.firstIndex(of: "]") {
        let dim = String(rest[rest.index(after: a)..<b])
        if let n = Int(dim) { it.dims = n } else if let c = header.apiConstant(dim), let n = Int(c) { it.dims = n } else {
          it.bad = true
        }
      }
    }
    return it
  }

  /// Where `name` ends in `text`, as a whole word.
  static func end(of name: String, in text: String) -> String.Index? {
    var i = text.startIndex
    while i < text.endIndex {
      if text[i...].hasPrefix(name), i == text.startIndex || !(text[text.index(before: i)].isLetter
        || text[text.index(before: i)].isNumber || text[text.index(before: i)] == "_")
      {
        let end = text.index(i, offsetBy: name.count)
        if end == text.endIndex || !(text[end].isLetter || text[end].isNumber || text[end] == "_") { return end }
      }
      i = text.index(after: i)
    }
    return nil
  }

  /// An item's shape, or nil if the wire can't carry it.
  func shape(_ it: Item) -> Shape? {
    guard !it.bad, let wire = it.wire else { return nil }
    if it.name == "pNext" && it.stars == 1 { return .pNext }
    let count = it.altlen ?? it.len.first
    switch (it.stars, it.dims) {
    case (0, nil):
      switch wire {
      case .char, .void: return nil
      default: return .value(wire)
      }
    case (0, let n?):
      switch wire {
      case .void, .union: return nil
      default: return .fixed(wire, n)
      }
    case (1, _):
      if wire == .char { return it.len.first == "null-terminated" ? .string : nil }
      if wire == .void { return count.map { .blob($0) } }
      if let count, count != "null-terminated" { return .array(wire, count) }
      return .single(wire)
    case (2, _):
      if wire == .char, it.constPointee, it.len.count == 2, it.len[1] == "null-terminated" { return .strings(it.len[0]) }
      return nil
    default:
      return nil
    }
  }

  /// Whether `wire` is something these structs can hold.
  func carried(_ wire: Wire, _ supported: Set<String>) -> Bool {
    switch wire {
    case .structure(let s): return supported.contains(s)
    case .union(let u): return u == "VkClearColorValue" || u == "VkClearValue"
    default: return true
    }
  }

  mutating func model() throws(VulkanGenError) {
    // Structs, then which can be carried (to a fixed point).
    var all: [String: [Item]] = [:]
    for n in header.typeNames {
      guard let t = r.types[n], t.attribute("alias") == nil,
        t.attribute("category") == "struct" || t.attribute("category") == "union"
      else { continue }
      all[n] = t.elements("member").filter(VulkanRegistry.forVulkan).compactMap { item($0) }
    }
    // sType values.
    var values: [String: String] = [:]
    for e in r.enumGroups["VkStructureType"]?.elements("enum") ?? [] {
      if let name = e.attribute("name"), let v = e.attribute("value") ?? e.attribute("alias") { values[name] = v }
    }
    for (name, v) in header.extraEnumValues["VkStructureType"] ?? [] where values[name] == nil { values[name] = v }
    func value(_ name: String) -> Int? {
      var v = name
      for _ in 0..<8 {
        guard let next = values[v] else { return nil }
        if let n = Int(next) { return n }
        v = next
      }
      return nil
    }
    // A struct whose sType comes from an extension not selected can't be sent.
    var unknown: Set<String> = []
    for (n, members) in all {
      guard let s = members.first?.sType else { continue }
      if let v = value(s) { sTypes[n] = v } else { unknown.insert(n) }
    }
    var supported = Set(all.keys).subtracting(unknown)
    var changed = true
    while changed {
      changed = false
      for (n, members) in all where supported.contains(n) {
        let ok: Bool
        if r.types[n]?.attribute("category") == "union" {
          ok = n == "VkClearColorValue" || n == "VkClearValue"
        } else {
          let hasSType = members.first?.sType != nil
          ok = members.allSatisfy { m in
            guard let s = shape(m) else { return false }
            switch s {
            case .pNext: return hasSType
            case .value(let w), .fixed(let w, _), .array(let w, _), .single(let w): return carried(w, supported)
            default: return true
            }
          }
        }
        if !ok {
          supported.remove(n)
          changed = true
        }
      }
    }
    for n in all.keys.sorted() where !supported.contains(n) { omitted.append("struct \(n)") }
    for n in supported { structs[n] = all[n] }

    // Extension structs, in vk.xml's order.
    let clientOnly = Set(venusClientExtensions.flatMap { e in
      (r.extensions[e]?.elements("require") ?? []).flatMap { $0.elements("type") }.compactMap { $0.attribute("name") }
    })
    for n in r.typeOrder where structs[n] != nil && sTypes[n] != nil && !clientOnly.contains(n) {
      for base in (r.types[n]?.attribute("structextends") ?? "").split(separator: ",").map(String.init) {
        let b = canonical(base)
        if structs[b] != nil, sTypes[b] != nil { extenders[b, default: []].append(n) }
      }
    }

    // Command types.
    var types: [String: Int] = [:]
    for e in r.enumGroups["VkCommandTypeEXT"]?.elements("enum") ?? [] {
      guard let name = e.attribute("name"), let v = e.attribute("value").flatMap(Int.init) else { continue }
      types[name] = v
    }
    for c in header.commandNames {
      guard let cmd = header.resolveCommand(c), cmd.attribute("alias") == nil || header.r.commands[c] != nil,
        let protoElement = cmd.element("proto"), let proto = item(protoElement)
      else { continue }
      if venusRefused.contains(c) { continue }
      guard let type = types["VK_COMMAND_TYPE_\(c)_EXT"] else {
        omitted.append("command \(c) (no command type)")
        continue
      }
      guard type <= venusMaxCommandType else {
        omitted.append("command \(c) (type \(type), past the renderer's)")
        continue
      }
      let params = cmd.elements("param").filter(VulkanRegistry.forVulkan).compactMap { item($0) }
      var ok = ["void", "VkResult", "VkDeviceAddress", "uint64_t", "uint32_t", "VkBool32"].contains(proto.type)
        && proto.stars == 0
      for p in params where p.name != "pAllocator" {
        guard let s = shape(p) else {
          ok = false
          continue
        }
        switch s {
        case .pNext: ok = false
        case .value(let w): if case .structure = w { ok = false } else if case .union = w { ok = false }
        case .fixed(let w, _), .array(let w, _), .single(let w): if !carried(w, supported) { ok = false }
        default: break
        }
      }
      guard ok else {
        omitted.append("command \(c)")
        continue
      }
      commands.append((c, type, proto, params))
    }
    commands.sort { $0.type < $1.type }

    // Structs reached from outputs.
    var pending: [String] = []
    for c in commands {
      for p in c.params where isOutput(p, in: c.params) {
        if case .structure(let s)? = p.wire { pending.append(s) }
      }
    }
    while let s = pending.popLast() {
      guard !outputs.contains(s), let members = structs[s] else { continue }
      outputs.insert(s)
      for m in members { if case .structure(let t)? = m.wire { pending.append(t) } }
      pending += extenders[s] ?? []
    }
  }

  func isOutput(_ p: Item, in params: [Item]) -> Bool { p.stars >= 1 && !p.constPointee }

  func isInOut(_ p: Item, in params: [Item]) -> Bool {
    isOutput(p, in: params) && params.contains { q in q.len.first == p.name }
  }

  // MARK: Swift

  func swiftScalar(_ type: String) -> String {
    switch type {
    case "uint32_t": return "UInt32"
    case "int32_t", "int": return "Int32"
    case "uint64_t": return "UInt64"
    case "int64_t": return "Int64"
    case "uint16_t": return "UInt16"
    case "int16_t": return "Int16"
    case "uint8_t": return "UInt8"
    case "int8_t": return "Int8"
    case "float": return "Float"
    case "double": return "Double"
    case "size_t": return "Int"
    case "char": return "CChar"
    default: return r.types[type]?.attribute("category") == "handle" ? "\(type)?" : type
    }
  }

  func swiftType(_ p: Item) -> String {
    let base = swiftScalar(p.type)
    if p.dims != nil { return "UnsafePointer<\(base)>?" }
    switch p.stars {
    case 0: return base
    case 1:
      if p.type == "void" { return p.constPointee ? "UnsafeRawPointer?" : "UnsafeMutableRawPointer?" }
      return p.constPointee ? "UnsafePointer<\(base)>?" : "UnsafeMutablePointer<\(base)>?"
    default: return "UnsafePointer<UnsafePointer<CChar>?>?"
    }
  }

  /// A length expression in Swift: `ident` names a member of `v` (a
  /// struct's) or a parameter (a command's: `p->m`, or a pointer to the count).
  func length(_ expr: String, member: Bool, params: [Item] = []) -> String {
    var out = ""
    var chars = Array(expr)[...]
    while let c = chars.first {
      if c.isLetter || c == "_" {
        var ident = ""
        while let d = chars.first, d.isLetter || d.isNumber || d == "_" {
          ident.append(d)
          chars.removeFirst()
        }
        var field: String?
        if chars.starts(with: "->") {
          chars.removeFirst(2)
          var f = ""
          while let d = chars.first, d.isLetter || d.isNumber || d == "_" {
            f.append(d)
            chars.removeFirst()
          }
          field = f
        }
        if member {
          out += "venusInt(v.\(ident))"
        } else if let field {
          out += "(\(ident).map { unsafe venusInt($0.pointee.\(field)) } ?? 0)"
        } else if let p = params.first(where: { $0.name == ident }), p.stars > 0 {
          out += "(\(ident).map { unsafe venusInt($0.pointee) } ?? 0)"
        } else {
          out += "venusInt(\(ident))"
        }
      } else {
        out.append(c)
        chars.removeFirst()
      }
    }
    return out
  }

  /// Whether a struct is an unsafe type to Swift: it holds a pointer or a
  /// handle, itself or in a struct it holds by value.
  func isUnsafe(_ s: String) -> Bool {
    for m in structs[s] ?? [] {
      if m.stars > 0 || m.wire == .handle { return true }
      if case .structure(let t)? = m.wire, t != s, isUnsafe(t) { return true }
    }
    return false
  }

  /// Arrays encoded only under a condition (§4.5).
  func condition(_ s: String, _ m: String) -> String? {
    switch (s, m) {
    case ("VkImageCreateInfo", "pQueueFamilyIndices"), ("VkBufferCreateInfo", "pQueueFamilyIndices"),
      ("VkPhysicalDeviceImageDrmFormatModifierInfoEXT", "pQueueFamilyIndices"):
      return "unsafe venusInt(v.sharingMode) == 1"  // VK_SHARING_MODE_CONCURRENT
    case ("VkFramebufferCreateInfo", "pAttachments"):
      return "unsafe venusInt(v.flags) & 1 == 0"  // not VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT
    default: return nil
    }
  }

  // MARK: Structs

  /// The members after sType and pNext (all of them without an sType).
  func fields(_ s: String) -> [Item] {
    let m = structs[s] ?? []
    return sTypes[s] != nil ? Array(m.dropFirst(2)) : m
  }

  /// Whole: as an input, or a reply's output.
  func encodeLines(_ s: String, _ m: Item) -> [String] {
    let v = "v.\(m.name)"
    let u = isUnsafe(s) ? "unsafe " : ""
    guard let shape = shape(m) else { return [] }
    switch shape {
    case .pNext: return []
    case .value(let w):
      switch w {
      case .scalar: return ["\(u)e.raw(\(v))"]
      case .small: return ["\(u)e.u32(UInt32(truncatingIfNeeded: \(v)))"]
      case .size: return ["\(u)e.u64(UInt64(\(v)))"]
      case .handle: return ["unsafe e.handle(\(v))"]
      case .structure(let t), .union(let t): return ["\(u)encode_\(t)(&e, \(v))"]
      default: return []
      }
    case .fixed(let w, let n):
      switch w {
      case .handle:
        return ["e.size(\(n))",
                "\(u)withUnsafeBytes(of: \(v)) { b in for i in 0..<\(n) { unsafe e.handle(b.load(fromByteOffset: i * 8, as: OpaquePointer?.self)) } }"]
      case .structure(let t):
        return ["e.size(\(n))",
                "\(u)withUnsafeBytes(of: \(v)) { b in for i in 0..<\(n) { unsafe encode_\(t)(&e, b.load(fromByteOffset: i * MemoryLayout<\(t)>.stride, as: \(t).self)) } }"]
      default: return ["\(u)e.fixed(\(v), count: \(n))"]
      }
    case .string: return ["unsafe e.string(\(v))"]
    case .strings(let l): return ["unsafe e.strings(\(v), count: \(length(l, member: true)))"]
    case .blob(let l): return guarded(s, m, ["unsafe e.blob(UnsafeRawPointer(\(v)), count: \(length(l, member: true)))"])
    case .array(let w, let l):
      let n = length(l, member: true)
      switch w {
      case .handle: return guarded(s, m, ["unsafe e.handles(UnsafePointer(\(v)), count: \(n))"])
      case .structure(let t), .union(let t):
        return guarded(s, m, [
          "if let p = unsafe UnsafePointer(\(v)) { let n = unsafe \(n); e.size(n); for i in 0..<n { unsafe encode_\(t)(&e, p[i]) } } else { e.size(0) }",
        ])
      default: return guarded(s, m, ["unsafe e.array(UnsafePointer(\(v)), count: \(n))"])
      }
    case .single(let w):
      switch w {
      case .structure(let t), .union(let t):
        return ["if let p = unsafe UnsafePointer(\(v)) { e.size(1); unsafe encode_\(t)(&e, p.pointee) } else { e.size(0) }"]
      default: return ["if let p = unsafe UnsafePointer(\(v)) { e.size(1); unsafe e.raw(p.pointee) } else { e.size(0) }"]
      }
    }
  }

  func guarded(_ s: String, _ m: Item, _ lines: [String]) -> [String] {
    guard let c = condition(s, m.name) else { return lines }
    return ["if \(c) {"] + lines.map { "  " + $0 } + ["} else {", "  e.size(0)", "}"]
  }

  /// Partly: what tells the renderer which outputs to fill (§4.12).
  func partialLines(_ s: String, _ m: Item, counts: Set<String>) throws(VulkanGenError) -> [String] {
    if counts.contains(m.name) { return encodeLines(s, m) }
    let v = "v.\(m.name)"
    let u = isUnsafe(s) ? "unsafe " : ""
    guard let shape = shape(m) else { return [] }
    switch shape {
    case .pNext: return []
    case .value(let w):
      switch w {
      case .handle: return ["unsafe e.handle(\(v))"]
      case .structure(let t): return ["\(u)partial_\(t)(&e, \(v))"]
      case .union(let t): throw VulkanGenError(description: "an output union, \(t) in \(s)")
      default: return []
      }
    case .fixed(let w, let n):
      switch w {
      case .handle: return encodeLines(s, m)
      case .structure(let t):
        return ["e.size(\(n))",
                "\(u)withUnsafeBytes(of: \(v)) { b in for i in 0..<\(n) { unsafe partial_\(t)(&e, b.load(fromByteOffset: i * MemoryLayout<\(t)>.stride, as: \(t).self)) } }"]
      default: return []
      }
    case .single: return ["e.size(unsafe \(v) == nil ? 0 : 1)"]
    case .string: throw VulkanGenError(description: "an output string, \(m.name) in \(s)")
    case .strings(let l), .blob(let l), .array(_, let l):
      return ["e.size(unsafe \(v) == nil ? 0 : \(length(l, member: true)))"]
    }
  }

  /// Into the caller's storage, from a reply.
  func decodeLines(_ s: String, _ m: Item) -> [String] {
    let v = "v.\(m.name)"
    let u = isUnsafe(s) ? "unsafe " : ""
    let mutable = "UnsafePointer(\(v)).map { UnsafeMutablePointer(mutating: $0) }"
    guard let shape = shape(m) else { return [] }
    switch shape {
    case .pNext: return []
    case .value(let w):
      switch w {
      case .scalar: return ["\(u)\(v) = try d.raw()"]
      case .small: return ["\(u)\(v) = try d.small()"]
      case .size: return ["\(u)\(v) = Int(truncatingIfNeeded: try d.u64())"]
      case .handle: return ["_ = try d.u64()"]
      case .structure(let t): return ["try \(u)decode_\(t)(&d, &\(v))"]
      default: return ["throw VenusError.unsupported"]
      }
    case .fixed(let w, let n):
      switch w {
      case .handle: return ["guard try d.size() == \(n) else { throw VenusError.badSize }", "try d.skip(\(n) * 8)"]
      case .structure(let t):
        return ["do {",
                "  guard try d.size() == \(n) else { throw VenusError.badSize }",
                "  var failure: VenusError?",
                "  \(u)withUnsafeMutableBytes(of: &\(v)) { b in",
                "    let p = unsafe b.baseAddress!.assumingMemoryBound(to: \(t).self)",
                "    for i in 0..<\(n) { do throws(VenusError) { try unsafe decode_\(t)(&d, &p[i]) } catch { failure = error; return } }",
                "  }",
                "  if let failure { throw failure }",
                "}"]
      case .char: return ["try \(u)d.fixed(&\(v), count: \(n), string: true)"]
      default: return ["try \(u)d.fixed(&\(v), count: \(n))"]
      }
    case .single(let w):
      switch w {
      case .structure(let t):
        return ["if try d.marker() { guard let p = unsafe \(mutable) else { throw VenusError.noStorage }; try unsafe decode_\(t)(&d, &p.pointee) }"]
      case .scalar: return ["if try d.marker() { guard let p = unsafe \(mutable) else { throw VenusError.noStorage }; unsafe p.pointee = try d.raw() }"]
      default: return ["throw VenusError.unsupported"]
      }
    case .array(let w, _):
      switch w {
      case .handle: return ["do { let n = try d.size(); guard n <= cap_\(m.name) else { throw VenusError.badSize }; try d.skip(n * 8) }"]
      case .structure(let t):
        return ["do {",
                "  let n = try d.size()",
                "  if n > 0 {",
                "    guard let p = unsafe \(mutable) else { throw VenusError.noStorage }",
                "    guard n <= cap_\(m.name) else { throw VenusError.badSize }",
                "    for i in 0..<n { try unsafe decode_\(t)(&d, &p[i]) }",
                "  }",
                "}"]
      case .union: return ["throw VenusError.unsupported"]
      default: return ["try unsafe d.array(\(mutable), capacity: cap_\(m.name))"]
      }
    case .blob:
      return ["try unsafe d.blob(UnsafeMutableRawPointer(mutating: UnsafeRawPointer(\(v))), capacity: cap_\(m.name))"]
    case .string, .strings: return ["throw VenusError.unsupported"]
    }
  }

  func structCode(_ s: String) throws(VulkanGenError) -> String {
    var out = ""
    func function(_ signature: String, _ lines: [String]) {
      out += "  \(signature) {\n"
      for l in lines { out += "    \(l)\n" }
      out += "  }\n\n"
    }
    let isUnion = r.types[s]?.attribute("category") == "union"
    if isUnion {
      // §4.11: the fixed default tag; both carry the 16 bytes as uint32[4].
      let bytes = ["e.size(4)", "withUnsafeBytes(of: v) { b in unsafe e.bytes(b.baseAddress, count: 16) }"]
      let lines = (s == "VkClearValue" ? ["e.u32(0)", "e.u32(2)"] : ["e.u32(2)"]) + bytes
      function("static func encode_\(s)(_ e: inout VenusEncoder, _ v: \(s))", lines)
      return out
    }
    let f = fields(s)
    let counts = Set((structs[s] ?? []).compactMap { m -> String? in
      guard m.stars > 0, m.dims == nil, let l = m.altlen ?? m.len.first, l != "null-terminated" else { return nil }
      return l
    }.flatMap { expr in
      expr.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
    })
    let output = outputs.contains(s)
    if let sType = sTypes[s] {
      function("static func encode_\(s)(_ e: inout VenusEncoder, _ v: \(s))",
               ["e.u32(\(sType))", "unsafe encodeChain_\(s)(&e, UnsafeRawPointer(v.pNext))", "unsafe encodeFields_\(s)(&e, v)"])
      function("static func encodeFields_\(s)(_ e: inout VenusEncoder, _ v: \(s))", f.flatMap { encodeLines(s, $0) })
      function("static func encodeChain_\(s)(_ e: inout VenusEncoder, _ p: UnsafeRawPointer?)",
               chainLines(s, field: "encodeFields"))
      if output {
        function("static func partial_\(s)(_ e: inout VenusEncoder, _ v: \(s))",
                 ["e.u32(\(sType))", "unsafe partialChain_\(s)(&e, UnsafeRawPointer(v.pNext))", "unsafe partialFields_\(s)(&e, v)"])
        var lines: [String] = []
        for m in f { lines += try partialLines(s, m, counts: counts) }
        function("static func partialFields_\(s)(_ e: inout VenusEncoder, _ v: \(s))", lines)
        function("static func partialChain_\(s)(_ e: inout VenusEncoder, _ p: UnsafeRawPointer?)",
                 chainLines(s, field: "partialFields"))
        function("static func decode_\(s)(_ d: inout VenusDecoder, _ v: inout \(s)) throws(VenusError)",
                 ["let sType: UInt32 = try d.raw()", "guard sType == \(sType) else { throw VenusError.wrongStructure(sType) }",
                  "try unsafe decodeChain_\(s)(&d, UnsafeMutableRawPointer(mutating: UnsafeRawPointer(v.pNext)))",
                  "try unsafe decodeFields_\(s)(&d, &v)"])
        function("static func decodeFields_\(s)(_ d: inout VenusDecoder, _ v: inout \(s)) throws(VenusError)",
                 capacities(s, f) + f.flatMap { decodeLines(s, $0) })
        function("static func decodeChain_\(s)(_ d: inout VenusDecoder, _ p: UnsafeMutableRawPointer?) throws(VenusError)",
                 decodeChainLines(s))
      }
    } else {
      function("static func encode_\(s)(_ e: inout VenusEncoder, _ v: \(s))", f.flatMap { encodeLines(s, $0) })
      if output {
        var lines: [String] = []
        for m in f { lines += try partialLines(s, m, counts: counts) }
        function("static func partial_\(s)(_ e: inout VenusEncoder, _ v: \(s))", lines)
        function("static func decode_\(s)(_ d: inout VenusDecoder, _ v: inout \(s)) throws(VenusError)",
                 capacities(s, f) + f.flatMap { decodeLines(s, $0) })
      }
    }
    return out
  }

  /// Arrays' capacities, read before their counts are decoded over.
  func capacities(_ s: String, _ f: [Item]) -> [String] {
    f.compactMap { m in
      guard let shape = shape(m) else { return nil }
      switch shape {
      case .array(_, let l), .blob(let l): return "let cap_\(m.name) = unsafe \(length(l, member: true))"
      default: return nil
      }
    }
  }

  /// §4.10: the first struct in the chain that may extend `s`, its own
  /// chain (judged against `s`'s list), then its members.
  func chainLines(_ s: String, field: String) -> [String] {
    let ext = extenders[s] ?? []
    guard !ext.isEmpty else { return ["e.size(0)"] }
    var lines = ["var q = unsafe p", "while let c = unsafe q {",
                 "  let next = unsafe c.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)",
                 "  switch unsafe c.load(as: UInt32.self) {"]
    for x in ext {
      let chain = field == "encodeFields" ? "encodeChain" : "partialChain"
      lines.append("  case \(sTypes[x]!): e.size(1); e.u32(\(sTypes[x]!)); unsafe \(chain)_\(s)(&e, next); unsafe \(field)_\(x)(&e, c.load(as: \(x).self)); return")
    }
    lines += ["  default: unsafe q = next", "  }", "}", "e.size(0)"]
    return lines
  }

  func decodeChainLines(_ s: String) -> [String] {
    let ext = (extenders[s] ?? []).filter { outputs.contains($0) }
    var lines = ["guard try d.marker() else { return }", "let sType: UInt32 = try d.raw()"]
    guard !ext.isEmpty else { return lines + ["throw VenusError.unknownStructure(sType)"] }
    lines += ["var q = unsafe p",
              "while let c = unsafe q, unsafe c.load(as: UInt32.self) != sType { unsafe q = c.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self) }",
              "guard let c = unsafe q else { throw VenusError.unknownStructure(sType) }",
              "try unsafe decodeChain_\(s)(&d, c.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self))",
              "switch sType {"]
    for x in ext { lines.append("case \(sTypes[x]!): try unsafe decodeFields_\(x)(&d, &c.assumingMemoryBound(to: \(x).self).pointee)") }
    lines += ["default: throw VenusError.unknownStructure(sType)", "}"]
    return lines
  }

  // MARK: Commands

  func commandCode(_ c: (name: String, type: Int, proto: Item, params: [Item])) throws(VulkanGenError) -> String {
    let ps = c.params
    let list = ps.map { "_ \($0.name): \(swiftType($0))" }.joined(separator: ", ")
    let names = ps.map { $0.name }.joined(separator: ", ")
    let returns: String? = c.proto.type == "void" ? nil : swiftScalar(c.proto.type)
    func len(_ p: Item) -> String { length(p.altlen ?? p.len.first ?? "0", member: false, params: ps) }
    /// The same where it stands alone: unsafe only if it reads a pointer.
    func lenU(_ p: Item) -> String { let l = len(p); return l.contains(".map {") ? "unsafe \(l)" : l }

    var command = ["e.u32(\(c.type))", "e.u32(reply ? 1 : 0)"]
    var reply = ["e.u32(\(c.type))"]
    if returns != nil { reply.append("e.raw(result)") }
    var decode = ["let type = try d.u32()", "guard type == \(c.type) else { throw VenusError.wrongCommand(type) }"]
    if let returns { decode.append("let result: \(returns) = try d.raw()") }
    var caps: [String] = []

    for p in ps {
      let x = p.name
      if x == "pAllocator" {
        command.append("e.size(0)")
        continue
      }
      guard let shape = shape(p) else { throw VulkanGenError(description: "\(c.name): \(x)") }
      if !isOutput(p, in: ps) {
        switch shape {
        case .value(let w):
          switch w {
          case .scalar: command.append("e.raw(\(x))")
          case .small: command.append("e.u32(UInt32(truncatingIfNeeded: \(x)))")
          case .size: command.append("e.u64(UInt64(\(x)))")
          case .handle: command.append("unsafe e.handle(\(x))")
          default: throw VulkanGenError(description: "\(c.name): \(x) by value")
          }
        case .fixed(_, let n): command.append("unsafe e.fixed(\(x), count: \(n))")
        case .string: command.append("unsafe e.string(\(x))")
        case .strings(let l): command.append("unsafe e.strings(\(x), count: \(length(l, member: false, params: ps)))")
        case .blob: command.append("unsafe e.blob(\(x), count: \(len(p)))")
        case .array(let w, _):
          switch w {
          case .handle: command.append("unsafe e.handles(\(x), count: \(len(p)))")
          case .structure(let t), .union(let t):
            command.append("if let p = unsafe \(x) { let n = \(lenU(p)); e.size(n); for i in 0..<n { unsafe encode_\(t)(&e, p[i]) } } else { e.size(0) }")
          default: command.append("unsafe e.array(\(x), count: \(len(p)))")
          }
        case .single(let w):
          switch w {
          case .structure(let t), .union(let t):
            command.append("if let p = unsafe \(x) { e.size(1); unsafe encode_\(t)(&e, p.pointee) } else { e.size(0) }")
          default: command.append("if let p = unsafe \(x) { e.size(1); unsafe e.raw(p.pointee) } else { e.size(0) }")
          }
        case .pNext: throw VulkanGenError(description: "\(c.name): \(x)")
        }
        continue
      }
      // Outputs: partly in the command, whole in the reply.
      switch shape {
      case .single(let w):
        switch w {
        case .handle:
          command.append("if let p = unsafe \(x) { e.size(1); unsafe e.handle(p.pointee) } else { e.size(0) }")
          reply.append("if let p = unsafe \(x) { e.size(1); unsafe e.handle(p.pointee) } else { e.size(0) }")
          decode.append("if try d.marker() { _ = try d.u64() }")
        case .structure(let t):
          command.append("if let p = unsafe \(x) { e.size(1); unsafe partial_\(t)(&e, p.pointee) } else { e.size(0) }")
          reply.append("if let p = unsafe \(x) { e.size(1); unsafe encode_\(t)(&e, p.pointee) } else { e.size(0) }")
          decode.append("if try d.marker() { guard let p = unsafe \(x) else { throw VenusError.noStorage }; try unsafe decode_\(t)(&d, &p.pointee) }")
        case .scalar, .small, .size:
          let value: String, read: String
          switch w {
          case .small: (value, read) = ("e.u32(UInt32(truncatingIfNeeded: p.pointee))", "try d.small()")
          case .size: (value, read) = ("e.u64(UInt64(p.pointee))", "Int(truncatingIfNeeded: try d.u64())")
          default: (value, read) = ("e.raw(p.pointee)", "try d.raw()")
          }
          if isInOut(p, in: ps) {
            command.append("if let p = unsafe \(x) { e.size(1); unsafe \(value) } else { e.size(0) }")
          } else {
            command.append("e.size(unsafe \(x) == nil ? 0 : 1)")
          }
          reply.append("if let p = unsafe \(x) { e.size(1); unsafe \(value) } else { e.size(0) }")
          decode.append("if try d.marker() { guard let p = unsafe \(x) else { throw VenusError.noStorage }; unsafe p.pointee = \(read) }")
        default: throw VulkanGenError(description: "\(c.name): output \(x)")
        }
      case .array(let w, _):
        caps.append("let cap_\(x) = \(lenU(p))")
        switch w {
        case .handle:
          command.append("if let p = unsafe \(x) { let n = \(lenU(p)); e.size(n); for i in 0..<n { unsafe e.handle(p[i]) } } else { e.size(0) }")
          reply.append("unsafe e.handles(UnsafePointer(\(x)), count: \(len(p)))")
          decode.append("do { let n = try d.size(); guard n <= cap_\(x) else { throw VenusError.badSize }; try d.skip(n * 8) }")
        case .structure(let t):
          command.append("if let p = unsafe \(x) { let n = \(lenU(p)); e.size(n); for i in 0..<n { unsafe partial_\(t)(&e, p[i]) } } else { e.size(0) }")
          reply.append("if let p = unsafe \(x) { let n = \(lenU(p)); e.size(n); for i in 0..<n { unsafe encode_\(t)(&e, p[i]) } } else { e.size(0) }")
          decode += ["do {", "  let n = try d.size()", "  if n > 0 {",
                     "    guard let p = unsafe \(x) else { throw VenusError.noStorage }",
                     "    guard n <= cap_\(x) else { throw VenusError.badSize }",
                     "    for i in 0..<n { try unsafe decode_\(t)(&d, &p[i]) }", "  }", "}"]
        case .scalar, .small, .size:
          command.append("e.size(unsafe \(x) == nil ? 0 : \(len(p)))")
          reply.append("unsafe e.array(UnsafePointer(\(x)), count: \(len(p)))")
          decode.append("try unsafe d.array(\(x), capacity: cap_\(x))")
        default: throw outputError(c.name, x)
        }
      case .blob:
        caps.append("let cap_\(x) = \(lenU(p))")
        command.append("e.size(unsafe \(x) == nil ? 0 : \(len(p)))")
        reply.append("unsafe e.blob(UnsafeRawPointer(\(x)), count: \(len(p)))")
        decode.append("try unsafe d.blob(\(x), capacity: cap_\(x))")
      default: throw outputError(c.name, x)
      }
    }

    var out = "  /// \(c.name) (command type \(c.type)).\n"
    out += "  public static func \(c.name)(_ e: inout VenusEncoder, reply: Bool\(list.isEmpty ? "" : ", " + list)) {\n"
    for l in command { out += "    \(l)\n" }
    out += "  }\n\n"
    out += "  /// \(c.name)'s reply, into the outputs given.\n"
    if returns != nil { out += "  @discardableResult\n" }
    out += "  public static func \(c.name)_reply(_ d: inout VenusDecoder\(list.isEmpty ? "" : ", " + list)) throws(VenusError)\(returns.map { " -> \($0)" } ?? "") {\n"
    for l in caps + decode { out += "    \(l)\n" }
    if returns != nil { out += "    return result\n" }
    out += "  }\n\n"
    let resultParam = returns.map { ", _ result: \($0)" } ?? ""
    out += "  /// \(c.name)'s reply as the renderer writes it.\n"
    out += "  public static func \(c.name)_encodeReply(_ e: inout VenusEncoder\(resultParam)\(list.isEmpty ? "" : ", " + list)) {\n"
    for l in reply { out += "    \(l)\n" }
    out += "  }\n\n"
    let placeholder = returns == nil ? "" : (c.proto.type == "VkResult" ? ", VK_SUCCESS" : ", 0")
    out += "  /// The size of \(c.name)'s reply, for the outputs given.\n"
    out += "  public static func \(c.name)_replySize(\(list)) -> Int {\n"
    out += "    var e = VenusEncoder(measuring: true)\n"
    let unsafeParams = ps.contains { $0.stars > 0 || $0.dims != nil || $0.wire == .handle }
    out += "    \(unsafeParams ? "unsafe " : "")\(c.name)_encodeReply(&e\(placeholder)\(names.isEmpty ? "" : ", " + names))\n"
    out += "    return e.count\n"
    out += "  }\n\n"
    return out
  }

  func outputError(_ c: String, _ x: String) -> VulkanGenError { VulkanGenError(description: "\(c): output \(x)") }

  // MARK: The driver's entry points

  /// The client driver's own commands (graphics/venus/driver/Driver.swift),
  /// which the generated entry points leave to it.
  public static let handwritten: [String] = [
    "vkCreateInstance", "vkDestroyInstance", "vkEnumerateInstanceVersion", "vkEnumerateInstanceExtensionProperties",
    "vkEnumerateInstanceLayerProperties", "vkEnumeratePhysicalDevices", "vkGetPhysicalDeviceProperties",
    "vkGetPhysicalDeviceProperties2", "vkEnumerateDeviceExtensionProperties", "vkEnumerateDeviceLayerProperties",
    "vkGetInstanceProcAddr", "vkGetDeviceProcAddr", "vkCreateDevice", "vkDestroyDevice", "vkGetDeviceQueue",
    "vkGetDeviceQueue2", "vkQueueSubmit", "vkQueueSubmit2", "vkQueueWaitIdle", "vkDeviceWaitIdle", "vkCreateFence",
    "vkDestroyFence", "vkResetFences", "vkGetFenceStatus", "vkWaitForFences", "vkAllocateMemory", "vkFreeMemory",
    "vkMapMemory", "vkUnmapMemory", "vkFlushMappedMemoryRanges", "vkInvalidateMappedMemoryRanges",
    "vkAllocateCommandBuffers", "vkFreeCommandBuffers", "vkBeginCommandBuffer", "vkEndCommandBuffer",
    "vkResetCommandBuffer", "vkGetMemoryZirconHandleFUCHSIA",
  ]

  /// One generated entry point: a vkCmd records into its command buffer;
  /// a command that makes handles gives them fresh ids; vkDestroy and
  /// vkFree send and free; one that answers is a call; the rest are sent.
  func entryCode(_ c: (name: String, type: Int, proto: Item, params: [Item])) throws(VulkanGenError) -> String {
    let ps = c.params
    let list = ps.map { "_ \($0.name): \(swiftType($0))" }.joined(separator: ", ")
    let names = ps.map { $0.name }.joined(separator: ", ")
    let returns: String? = c.proto.type == "void" ? nil : swiftScalar(c.proto.type)
    let failure = returns == nil ? "" : (c.proto.type == "VkResult" ? " lostResult" : " 0")
    guard let first = ps.first, first.wire == .handle, first.stars == 0 else {
      throw VulkanGenError(description: "\(c.name): no dispatchable first parameter")
    }
    var out = "func venus_\(c.name)(\(list))\(returns.map { " -> \($0)" } ?? "") {\n"
    func line(_ l: String) { out += "  \(l)\n" }
    if c.name.hasPrefix("vkCmd") {
      line("guard let cb = unsafe state(\(first.name), CommandBufferState.self) else { return }")
      line("unsafe Venus.\(c.name)(&cb.encoder, reply: false, \(names))")
      return out + "}\n\n"
    }
    line("guard let context = unsafe VenusHandle.context(\(first.name)) else { return\(failure) }")
    let isDestroy = c.name.hasPrefix("vkDestroy") || c.name.hasPrefix("vkFree")
    let made = ps.filter { isOutput($0, in: ps) && $0.wire == .handle }
    let hasOutputs = ps.contains { isOutput($0, in: ps) }
    let send = "try context.send { e in unsafe Venus.\(c.name)(&e, reply: false, \(names)) }"
    let call = "try unsafe context.call(Venus.\(c.name)_replySize(\(names)), { e in unsafe Venus.\(c.name)(&e, reply: true, \(names)) }, { (d: inout VenusDecoder) throws(VenusError)\(returns.map { " -> \($0)" } ?? "") in try unsafe Venus.\(c.name)_reply(&d, \(names)) })"
    if isDestroy {
      line("_ = try? context.locked { () throws(VenusLost) in \(send) }")
      // What it destroys or frees: the handles after the dispatchable one.
      for p in ps.dropFirst() where p.wire == .handle && !isOutput(p, in: ps) {
        if p.stars == 0 {
          line("unsafe VenusHandle.free(\(p.name))")
        } else if let l = p.len.first {
          let n = length(l, member: false, params: ps)
          line("for i in 0..<\(n.contains(".map {") ? "unsafe " : "")\(n) { unsafe VenusHandle.free(\(p.name)?[i]) }")
        }
      }
      if returns != nil { line("return VK_SUCCESS") }
      return out + "}\n\n"
    }
    if !made.isEmpty {
      guard c.proto.type == "VkResult" else { throw VulkanGenError(description: "\(c.name): makes handles, no VkResult") }
      line("do {")
      line("  return try context.locked { () throws(VenusLost) -> VkResult in")
      for p in made {
        if let l = p.len.first {
          let n = length(l, member: false, params: ps)
          line("    let \(p.name)Count = \(n.contains(".map {") ? "unsafe " : "")\(n)")
          line("    for i in 0..<\(p.name)Count { unsafe \(p.name)?[i] = VenusHandle.make(id: context.newID(), state: nil, dispatchable: false) }")
        } else {
          line("    unsafe \(p.name)?.pointee = VenusHandle.make(id: context.newID(), state: nil, dispatchable: false)")
        }
      }
      line("    let r = \(call)")
      line("    if r != VK_SUCCESS {")
      for p in made {
        if p.len.first != nil {
          line("      for i in 0..<\(p.name)Count { unsafe VenusHandle.free(\(p.name)?[i]); unsafe \(p.name)?[i] = nil }")
        } else {
          line("      unsafe VenusHandle.free(\(p.name)?.pointee); unsafe \(p.name)?.pointee = nil")
        }
      }
      line("    }")
      line("    return r")
      line("  }")
      line("} catch {")
      line("  return lostResult")
      line("}")
      return out + "}\n\n"
    }
    if returns != nil || hasOutputs {
      if let returns {
        line("do { return try context.locked { () throws(VenusLost) -> \(returns) in \(call) } } catch { return\(failure) }")
      } else {
        line("_ = try? context.locked { () throws(VenusLost) in \(call) }")
      }
      return out + "}\n\n"
    }
    line("_ = try? context.locked { () throws(VenusLost) in \(send) }")
    return out + "}\n\n"
  }

  /// The driver's entry points and their names, for vkGetInstanceProcAddr.
  public func entries(source: String) throws(VulkanGenError) -> String {
    var out = """
      // SPDX-License-Identifier: BSD-3-Clause
      //
      // Generated by vkgen from \(source). Do not edit; regenerate (CLAUDE.md, "Venus").
      // The Venus client driver's entry points that pass straight through to the renderer,
      // and every entry point's name.

      import TDVenus
      import Venus


      """
    var table: [String] = []
    for c in commands where !c.name.hasSuffix("MESA") {
      table.append(c.name)
      if Self.handwritten.contains(c.name) { continue }
      out += try entryCode(c)
    }
    // Refused by the renderer but the driver's own (§16.3).
    for n in Self.handwritten where !table.contains(n) { table.append(n) }
    out += "/// Every entry point, by name.\n"
    out += "let venusEntries: [(name: StaticString, function: PFN_vkVoidFunction)] = [\n"
    for n in table.sorted() {
      out += "  (\"\(n)\", unsafe unsafeBitCast(venus_\(n) as PFN_\(n), to: PFN_vkVoidFunction.self)),\n"
    }
    out += "]\n"
    return out
  }

  // MARK: Output

  public func swift(source: String) throws(VulkanGenError) -> String {
    var out = """
      // SPDX-License-Identifier: BSD-3-Clause
      //
      // Generated by vkgen from \(source). Do not edit; regenerate (CLAUDE.md, "Venus").
      // Venus's encoders and decoders for Vulkan up to \(venusSelection.maxVersion) and Venus's own
      // commands: \(commands.count) commands, \(structs.count) structs and unions (\(outputs.count) of them outputs).

      import TDVenus

      public enum Venus {}

      extension Venus {

      """
    for c in commands { out += try commandCode(c) }
    out += "}\n\n// Structs.\nextension Venus {\n"
    for s in structs.keys.sorted() { out += try structCode(s) }
    out += "}\n"
    if !omitted.isEmpty {
      out += "\n// Left out (the wire can't carry them, or what they need):\n"
      for o in omitted { out += "//   \(o)\n" }
    }
    return out
  }
}

/// Venus's header and Swift, from its three registries' texts (vkgen
/// --venus, and the test that checks the committed outputs).
public func venusOutputs(vk: String, serialization: String, protocol mesa: String) throws
  -> (header: String, swift: String, entries: String)
{
  let registry = try VulkanRegistry([vk, serialization, mesa])
  let header = try CHeaderGenerator(registry, venusSelection)
  let source = "data/venus (vk.xml, VK_EXT_command_serialization.xml, VK_MESA_venus_protocol.xml)"
  let venus = try VenusGenerator(header)
  return (try header.generate(source: source, guard: "TD_VENUS_H", section: "Venus"), try venus.swift(source: source),
          try venus.entries(source: source))
}
