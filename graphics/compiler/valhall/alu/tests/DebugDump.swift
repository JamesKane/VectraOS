#if canImport(Darwin)
import Darwin
#endif
import Testing
import ValhallBackend
import ValhallISA
import ShaderCompiler

@Suite struct DebugDump {
  @Test func dump() throws {
    guard let name = getenv("DUMP") else { return }
    let cs = try compileGLSL(String(cString: name))
    for (n, i) in cs.instructions.enumerated() { print("\(n): \(ISATable.shared.disassemble(i))") }
    var m = try IRModule.lower(try SPIRVModule.parse(words: try spirv(String(cString: name))))
    try m.optimize()
    _ = m.expandAtomics()
    print(m.functions[0].text(module: m))
  }
}
