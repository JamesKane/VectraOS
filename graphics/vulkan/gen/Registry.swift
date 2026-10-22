// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan API registry (vk.xml, Khronos; data), read into what vkgen
// needs: types, enum values, commands, and which of them each feature and
// extension requires. The format is described in the Vulkan registry
// documentation ("The Khronos Vulkan API Registry"); this reader is ours.

import XMLReader

public struct VulkanRegistry {
  public var types: [String: XMLElement] = [:]  // by name, the <type> element
  public var typeOrder: [String] = []
  public var enumGroups: [String: XMLElement] = [:]  // <enums name=...>
  public var commands: [String: XMLElement] = [:]  // by name
  public var features: [XMLElement] = []
  public var extensions: [String: XMLElement] = [:]

  public init(_ text: String) throws(XMLError) {
    try add(text)
  }

  /// vk.xml and registries that extend it (Venus's command serialization
  /// and protocol XML), read as one.
  public init(_ texts: [String]) throws(XMLError) {
    for t in texts { try add(t) }
  }

  mutating func add(_ text: String) throws(XMLError) {
    let root = try parseXML(text)
    guard root.name == "registry" else { throw XMLError(description: "not a Vulkan registry") }
    for section in root.children {
      switch section.name {
      case "types":
        for t in section.elements("type") where Self.forVulkan(t) {
          // A name attribute, a <name> child, or (function pointers in
          // newer registries) <proto><name>.
          let name = t.attribute("name") ?? t.element("name")?.innerText() ?? t.element("proto")?.element("name")?.innerText()
          guard let name else { continue }
          if types[name] == nil { typeOrder.append(name) }
          types[name] = t
        }
      case "enums":
        if let name = section.attribute("name") { enumGroups[name] = section }
      case "commands":
        for c in section.elements("command") where Self.forVulkan(c) {
          let name = c.attribute("name") ?? c.element("proto")?.element("name")?.innerText()
          if let name { commands[name] = c }
        }
      case "feature":
        if Self.forVulkan(section) { features.append(section) }
      case "extensions":
        for e in section.elements("extension") {
          if let name = e.attribute("name") { extensions[name] = e }
        }
      default:
        break
      }
    }
  }

  /// Whether an element applies to Vulkan (not only Vulkan SC).
  public static func forVulkan(_ e: XMLElement) -> Bool {
    guard let api = e.attribute("api") ?? e.attribute("supported") else { return true }
    return api.split(separator: ",").contains("vulkan")
  }
}
