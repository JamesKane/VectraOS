// SPDX-License-Identifier: BSD-3-Clause

// vkgen's output: a C header with the Vulkan types and command prototypes
// (as PFN_ typedefs) for the selected versions and extensions, in an order
// C accepts. A C header, so struct layouts are exactly C's when Swift
// imports them. Our generator; its output is ours (principle 29).

import XMLReader

public struct VulkanSelection: Sendable {
  public var maxVersion: String  // e.g. "VK_VERSION_1_4"
  public var extensions: [String]
  public init(maxVersion: String, extensions: [String]) {
    self.maxVersion = maxVersion
    self.extensions = extensions
  }
}

public struct VulkanGenError: Error, CustomStringConvertible {
  public let description: String
  public init(description: String) { self.description = description }
}

public struct CHeaderGenerator {
  public let r: VulkanRegistry
  public let selection: VulkanSelection

  // What the selection requires.
  public internal(set) var typeNames: Set<String> = []
  public internal(set) var commandNames: [String] = []
  public internal(set) var constants: [(String, String)] = []  // name, C value
  public internal(set) var extraEnumValues: [String: [(String, String)]] = [:]  // enum type → (name, value)

  public init(_ registry: VulkanRegistry, _ selection: VulkanSelection) throws(VulkanGenError) {
    r = registry
    self.selection = selection
    try collect()
  }

  // MARK: Selection

  mutating func collect() throws(VulkanGenError) {
    var requires: [(XMLElement, Int?)] = []  // <require> blocks, with their extension number
    // Core is split into feature groups per version (VK_BASE_, VK_COMPUTE_,
    // VK_GRAPHICS_ and VK_VERSION_): take all of them up to the maximum.
    let maxVersion = Self.version(selection.maxVersion) ?? (1, 0)
    for f in r.features {
      guard let name = f.attribute("name"), let v = Self.version(name), v <= maxVersion else { continue }
      for req in f.elements("require") where VulkanRegistry.forVulkan(req) { requires.append((req, nil)) }
    }
    for name in selection.extensions {
      guard let e = r.extensions[name] else { throw VulkanGenError(description: "no extension \(name) in vk.xml") }
      let number = e.attribute("number").flatMap { Int($0) }
      for req in e.elements("require") where VulkanRegistry.forVulkan(req) { requires.append((req, number)) }
    }
    var commands: [String] = []
    for (req, number) in requires {
      for item in req.children {
        guard VulkanRegistry.forVulkan(item), let name = item.attribute("name") else { continue }
        switch item.name {
        case "type": typeNames.insert(name)
        case "command": if !commands.contains(name) { commands.append(name) }
        case "enum":
          if let extends = item.attribute("extends") {
            if let value = enumValue(item, extensionNumber: number), !(extraEnumValues[extends] ?? []).contains(where: { $0.0 == name }) {
              extraEnumValues[extends, default: []].append((name, value))
            }
            typeNames.insert(extends)
          } else if let value = item.attribute("value") ?? item.attribute("alias") {
            if !constants.contains(where: { $0.0 == name }) { constants.append((name, value)) }
          } else if let c = apiConstant(name), !constants.contains(where: { $0.0 == name }) {
            constants.append((name, c))
          }
        default: break
        }
      }
    }
    commandNames = commands
    // Types the commands use.
    for c in commands {
      guard let cmd = resolveCommand(c) else { continue }
      for p in cmd.elements("param") + [cmd.element("proto")].compactMap({ $0 }) where VulkanRegistry.forVulkan(p) {
        if let t = p.element("type")?.innerText() { typeNames.insert(t) }
      }
    }
    // 64-bit flag enums are VkFlags64, which no element names.
    if typeNames.contains(where: { is64($0) }) { typeNames.insert("VkFlags64") }
    // Close over struct members, aliases, bitmask flag types.
    var pending = Array(typeNames)
    while let name = pending.popLast() {
      guard let t = r.types[name] else { continue }
      var more: [String] = []
      if let alias = t.attribute("alias") { more.append(alias) }
      if let req = t.attribute("requires") ?? t.attribute("bitvalues") { more.append(req) }
      for m in t.elements("member") where VulkanRegistry.forVulkan(m) {
        if let mt = m.element("type")?.innerText() { more.append(mt) }
        if let e = m.element("enum")?.innerText(), !constants.contains(where: { $0.0 == e }), let c = apiConstant(e) {
          constants.append((e, c))
        }
      }
      if t.attribute("category") == "funcpointer" {
        for ty in t.elements("type") { more.append(ty.innerText()) }
        for p in t.elements("param") { if let pt = p.element("type")?.innerText() { more.append(pt) } }
      }
      for m in more where !typeNames.contains(m) && r.types[m] != nil {
        typeNames.insert(m)
        pending.append(m)
      }
    }
    // Constants that API constants refer to.
    for (_, value) in constants {
      if let c = apiConstant(value), !constants.contains(where: { $0.0 == value }) { constants.append((value, c)) }
    }
  }

  /// (1, 4) from "VK_VERSION_1_4", "VK_GRAPHICS_VERSION_1_4" and so on.
  static func version(_ name: String) -> (Int, Int)? {
    let parts = name.split(separator: "_")
    guard parts.count >= 4, parts.first == "VK", parts[parts.count - 3] == "VERSION",
      let major = Int(parts[parts.count - 2]), let minor = Int(parts[parts.count - 1])
    else { return nil }
    return (major, minor)
  }

  /// Platform types (vk.xml names their headers): Zircon's handle, which
  /// VK_FUCHSIA_external_memory hands out (M5j), is a 32-bit integer.
  static let platformTypes: [(String, String)] = [("zx_handle_t", "uint32_t")]

  /// A command, through its alias.
  public func resolveCommand(_ name: String) -> XMLElement? {
    guard let c = r.commands[name] else { return nil }
    if let alias = c.attribute("alias") { return resolveCommand(alias) }
    return c
  }

  /// An API constant's value (from <enums name="API Constants">).
  public func apiConstant(_ name: String) -> String? {
    guard let group = r.enumGroups["API Constants"] else { return nil }
    for e in group.elements("enum") where e.attribute("name") == name {
      return e.attribute("value") ?? e.attribute("alias")
    }
    return nil
  }

  /// An enum value from an extension or feature: value, bitpos, alias or
  /// offset (1000000000 + (extnumber − 1) × 1000 + offset, negated by dir).
  func enumValue(_ e: XMLElement, extensionNumber: Int?) -> String? {
    if let v = e.attribute("value") { return v }
    if let b = e.attribute("bitpos") { return bit(b, in: e.attribute("extends")) }
    if let a = e.attribute("alias") { return a }
    if let o = e.attribute("offset").flatMap(Int.init) {
      let ext = e.attribute("extnumber").flatMap(Int.init) ?? extensionNumber ?? 0
      let v = 1_000_000_000 + (ext - 1) * 1000 + o
      return e.attribute("dir") == "-" ? "-\(v)" : "\(v)"
    }
    return nil
  }

  public func is64(_ enumName: String?) -> Bool {
    guard let enumName else { return false }
    return r.enumGroups[enumName]?.attribute("bitwidth") == "64"
  }

  func bit(_ pos: String, in enumName: String?) -> String {
    is64(enumName) ? "(1ULL << \(pos))" : "(1U << \(pos))"
  }

  // MARK: Output

  public func generate(source: String, guard name: String = "TD_VULKAN_H", section: String = "Vulkan") throws(VulkanGenError)
    -> String
  {
    var out = """
      // SPDX-License-Identifier: BSD-3-Clause
      //
      // Generated by vkgen from \(source). Do not edit; regenerate (CLAUDE.md, "\(section)").
      // Vulkan up to \(selection.maxVersion), with \(selection.extensions.joined(separator: ", ")).
      // Commands are function-pointer typedefs (PFN_vk*), loaded at run time.

      #ifndef \(name)
      #define \(name)

      #include <stddef.h>
      #include <stdint.h>

      #define VKAPI_ATTR
      #define VKAPI_CALL
      #define VKAPI_PTR

      """
    let sorted = typeNames.sorted()
    func category(_ n: String) -> String? { r.types[n]?.attribute("category") }

    out += "\n// API constants.\n"
    for (name, value) in constants.sorted(by: { $0.0 < $1.0 }) {
      out += "#define \(name) \(value)\n"
    }

    // Platform types the selection uses, as their platforms define them.
    for (name, c) in Self.platformTypes where typeNames.contains(name) { out += "typedef \(c) \(name);\n" }

    out += "\n// Base types.\n"
    for n in r.typeOrder where typeNames.contains(n) && category(n) == "basetype" {
      let text = r.types[n]!.innerText(skipping: ["comment"]).trimmingSpace()
      if text.hasPrefix("typedef") { out += text + "\n" } else { out += "typedef struct \(n) \(n);\n" }
    }

    out += "\n// Handles.\n"
    for n in sorted where category(n) == "handle" && r.types[n]!.attribute("alias") == nil {
      out += "typedef struct \(n)_T *\(n);\n"
    }
    for n in sorted where category(n) == "handle" {
      if let alias = r.types[n]!.attribute("alias") { out += "typedef \(alias) \(n);\n" }
    }

    out += "\n// Enums.\n"
    for n in sorted where category(n) == "enum" {
      if r.types[n]!.attribute("alias") != nil { continue }
      out += try enumCode(n)
    }
    for n in sorted where category(n) == "enum" {
      if let alias = r.types[n]!.attribute("alias") { out += "typedef \(alias) \(n);\n" }
    }

    out += "\n// Bitmasks.\n"
    for n in r.typeOrder where typeNames.contains(n) && category(n) == "bitmask" {
      let t = r.types[n]!
      if let alias = t.attribute("alias") { out += "typedef \(alias) \(n);\n" } else {
        out += t.innerText(skipping: ["comment"]).trimmingSpace() + "\n"
      }
    }

    let structs = sorted.filter { category($0) == "struct" || category($0) == "union" }
    out += "\n// Structures, declared ahead of their use.\n"
    for n in structs where r.types[n]!.attribute("alias") == nil {
      out += "typedef \(category(n)!) \(n) \(n);\n"
    }
    // Aliases too, since a struct may hold one by value.
    for n in structs {
      if let alias = r.types[n]!.attribute("alias") { out += "typedef \(alias) \(n);\n" }
    }

    out += "\n// Function pointers.\n"
    for n in r.typeOrder where typeNames.contains(n) && category(n) == "funcpointer" {
      let t = r.types[n]!
      if let proto = t.element("proto") {  // <proto> and <param>s, as commands are
        out += prototype(name: n, proto: proto, params: t.elements("param")) + "\n"
      } else {  // older registries: the whole typedef as text
        out += t.innerText(skipping: ["comment"]).trimmingSpace() + "\n"
      }
    }

    out += "\n// Structures.\n"
    for n in try structOrder(structs.filter { r.types[$0]!.attribute("alias") == nil }) {
      let t = r.types[n]!
      out += "\(category(n)!) \(n) {\n"
      for m in t.elements("member") where VulkanRegistry.forVulkan(m) {
        out += "  " + declaration(m) + ";\n"
      }
      out += "};\n"
    }

    out += "\n// Commands, as the function pointers the loader fills.\n"
    var aliases: [(String, String)] = []
    for c in commandNames {
      guard let cmd = r.commands[c] else { throw VulkanGenError(description: "no command \(c)") }
      if let alias = cmd.attribute("alias") {
        aliases.append((c, alias))
        continue
      }
      guard let proto = cmd.element("proto") else { continue }
      out += prototype(name: "PFN_\(c)", proto: proto, params: cmd.elements("param")) + "\n"
    }
    for (c, alias) in aliases { out += "typedef PFN_\(alias) PFN_\(c);\n" }
    out += "\n// The names of the commands above, for the loader.\n"
    out += "#define TD_VULKAN_COMMANDS(X) \\\n"
    out += commandNames.map { "  X(\($0))" }.joined(separator: " \\\n") + "\n"
    out += "\n#endif\n"
    return out
  }

  /// The Swift command table: a typed function pointer per command,
  /// loaded through vkGetInstanceProcAddr (global and instance commands)
  /// or vkGetDeviceProcAddr (commands on a device, queue or command buffer).
  public func swiftCommands(source: String) -> String {
    var global: [String] = [], instance: [String] = [], device: [String] = []
    for c in commandNames {
      guard let cmd = resolveCommand(c) else { continue }
      let first = cmd.elements("param").filter(VulkanRegistry.forVulkan).first?.element("type")?.innerText()
      if ["vkCreateInstance", "vkEnumerateInstanceVersion", "vkEnumerateInstanceExtensionProperties",
          "vkEnumerateInstanceLayerProperties", "vkGetInstanceProcAddr"].contains(c) {
        global.append(c)
      } else if ["VkDevice", "VkQueue", "VkCommandBuffer"].contains(first ?? "") && c != "vkGetDeviceProcAddr" {
        device.append(c)
      } else {
        instance.append(c)
      }
    }
    func load(_ names: [String], via: String, handle: String) -> String {
      names.map { "    unsafe \($0) = unsafeBitCast(\(via)(\(handle), \"\($0)\"), to: PFN_\($0)?.self)" }.joined(separator: "\n")
    }
    return """
      // SPDX-License-Identifier: BSD-3-Clause
      //
      // Generated by vkgen from \(source). Do not edit; regenerate (CLAUDE.md, "Vulkan").

      import TDVulkan

      /// Every Vulkan command td_vulkan.h declares, loaded at run time.
      @safe public struct VulkanCommands {
      \((global + instance + device).map { "  public var \($0): PFN_\($0)?" }.joined(separator: "\n"))

        public init() {}

        /// Global commands (no instance yet).
        public mutating func loadGlobal(_ get: PFN_vkGetInstanceProcAddr) {
      \(load(global, via: "get", handle: "nil"))
        }

        /// Instance commands, and device commands through the instance's
        /// dispatch (until `loadDevice` replaces them).
        public mutating func loadInstance(_ get: PFN_vkGetInstanceProcAddr, _ instance: VkInstance) {
      \(load(instance + device, via: "get", handle: "instance"))
        }

        /// Device commands, straight from the driver.
        public mutating func loadDevice(_ get: PFN_vkGetDeviceProcAddr, _ device: VkDevice) {
      \(load(device, via: "get", handle: "device"))
        }
      }

      """
  }

  /// `typedef RET (VKAPI_PTR *NAME)(PARAMS);` from <proto> and <param>s.
  func prototype(name: String, proto: XMLElement, params: [XMLElement]) -> String {
    let lead = proto.innerText(skipping: ["comment", "name"]).trimmingSpace()  // "VkResult", "void*" etc.
    let list = params.filter(VulkanRegistry.forVulkan).map { declaration($0) }
    return "typedef \(lead) (VKAPI_PTR *\(name))(\(list.isEmpty ? "void" : list.joined(separator: ", ")));"
  }

  /// A member's or parameter's C declaration; a space between its type
  /// and name where the XML runs them together (`<type>uint64_t</type><name>ring</name>`).
  func declaration(_ e: XMLElement) -> String {
    let text = e.innerText(skipping: ["comment"]).trimmingSpace()
    guard let name = e.element("name")?.innerText(), let type = e.element("type")?.innerText(),
      let range = text.firstRange(of: type + name)
    else { return text }
    var fixed = text
    fixed.replaceSubrange(range, with: type + " " + name)
    return fixed
  }

  func enumCode(_ n: String) throws(VulkanGenError) -> String {
    let group = r.enumGroups[n]
    var values: [(String, String)] = []
    for e in group?.elements("enum") ?? [] where VulkanRegistry.forVulkan(e) {
      guard let name = e.attribute("name") else { continue }
      if let v = e.attribute("value") { values.append((name, v)) }
      else if let b = e.attribute("bitpos") { values.append((name, bit(b, in: n))) }
      else if let a = e.attribute("alias") { values.append((name, a)) }
    }
    for (name, v) in extraEnumValues[n] ?? [] where !values.contains(where: { $0.0 == name }) { values.append((name, v)) }
    // An alias of a value from an extension not selected names nothing: drop it.
    let defined = Set(values.map(\.0))
    values = values.filter { v in !(v.1.hasPrefix("VK_") && !defined.contains(v.1)) }
    if is64(n) {
      var out = "typedef VkFlags64 \(n);\n"
      for (name, v) in values { out += "static const \(n) \(name) = \(v);\n" }
      return out
    }
    let maxName = n.camelToUpperSnake() + "_MAX_ENUM_TD"  // a sentinel no real enumerant uses
    var out = "typedef enum \(n) {\n"
    for (name, v) in values { out += "  \(name) = \(v),\n" }
    out += "  \(maxName) = 0x7FFFFFFF\n} \(n);\n"
    return out
  }

  /// Structs ordered so each comes after the structs it holds by value.
  func structOrder(_ names: [String]) throws(VulkanGenError) -> [String] {
    let set = Set(names)
    var done: Set<String> = []
    var visiting: Set<String> = []
    var out: [String] = []
    func target(_ name: String) -> String {
      var n = name
      while let a = r.types[n]?.attribute("alias") { n = a }
      return n
    }
    func visit(_ n: String) throws(VulkanGenError) {
      if done.contains(n) { return }
      guard !visiting.contains(n) else { throw VulkanGenError(description: "structs hold each other by value: \(n)") }
      visiting.insert(n)
      for m in r.types[n]?.elements("member") ?? [] where VulkanRegistry.forVulkan(m) {
        guard let mt = m.element("type")?.innerText() else { continue }
        let byValue = !m.innerText(skipping: ["comment"]).contains("*")
        let t = target(mt)
        if byValue, set.contains(t) { try visit(t) }
      }
      visiting.remove(n)
      done.insert(n)
      out.append(n)
    }
    for n in names { try visit(n) }
    return out
  }
}

extension String {
  public func trimmingSpace() -> String {
    let collapsed = split(whereSeparator: { $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    return String(collapsed.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
  }

  /// "VkFormatFeatureFlagBits" → "VK_FORMAT_FEATURE_FLAG_BITS"
  func camelToUpperSnake() -> String {
    var out = ""
    let chars = Array(self)
    for (i, c) in chars.enumerated() {
      if c.isUppercase, i > 0, !chars[i - 1].isUppercase || (i + 1 < chars.count && chars[i + 1].isLowercase) { out += "_" }
      if c.isNumber, i > 0, !chars[i - 1].isNumber { out += "_" }
      out += c.uppercased()
    }
    return out
  }
}
