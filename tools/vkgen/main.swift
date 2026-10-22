// SPDX-License-Identifier: BSD-3-Clause

// vkgen: vk.xml → the C header graphics/vulkan/c/include/td_vulkan.h and
// its Swift command table; with --venus, Venus's registries → the header
// graphics/venus/c/include/td_venus.h, Venus's encoders and decoders, and the
// client driver's generated entry points.
//
//   vkgen OUTPUT.h COMMANDS.swift vk.xml
//   vkgen --loader DISPATCH.swift vk.xml        (our loader's tables and trampolines)
//   vkgen --venus OUTPUT.h PROTOCOL.swift ENTRIES.swift vk.xml VK_EXT_command_serialization.xml VK_MESA_venus_protocol.xml

import FoundationEssentials
import Glibc
import VenusGen
import VulkanGen

func fail(_ message: String) -> Never {
  let line = Array("vkgen: \(message)\n".utf8)
  _ = line.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
  exit(1)
}

func read(_ path: String) -> String {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
  return text
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--loader" {
  args.removeFirst()
  guard args.count == 2 else { fail("usage: vkgen --loader DISPATCH.swift vk.xml") }
  do {
    let generator = try CHeaderGenerator(try VulkanRegistry(read(args[1])), loinnirSelection)
    try LoaderGenerator(generator).generate(source: "vk.xml").write(toFile: args[0], atomically: true, encoding: .utf8)
  } catch {
    fail("\(error)")
  }
  exit(0)
}
if args.first == "--venus" {
  args.removeFirst()
  guard args.count == 6 else {
    fail("usage: vkgen --venus OUTPUT.h PROTOCOL.swift ENTRIES.swift vk.xml VK_EXT_command_serialization.xml VK_MESA_venus_protocol.xml")
  }
  do {
    let (header, swift, entries) = try venusOutputs(vk: read(args[3]), serialization: read(args[4]), protocol: read(args[5]))
    try header.write(toFile: args[0], atomically: true, encoding: .utf8)
    try swift.write(toFile: args[1], atomically: true, encoding: .utf8)
    try entries.write(toFile: args[2], atomically: true, encoding: .utf8)
  } catch {
    fail("\(error)")
  }
  exit(0)
}
guard args.count == 3 else { fail("usage: vkgen OUTPUT.h COMMANDS.swift vk.xml") }
let text = read(args[2])
do {
  let registry = try VulkanRegistry(text)
  let generator = try CHeaderGenerator(registry, loinnirSelection)
  try generator.generate(source: "vk.xml").write(toFile: args[0], atomically: true, encoding: .utf8)
  try generator.swiftCommands(source: "vk.xml").write(toFile: args[1], atomically: true, encoding: .utf8)
} catch {
  fail("\(error)")
}
