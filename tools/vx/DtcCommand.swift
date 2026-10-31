// SPDX-License-Identifier: BSD-3-Clause

// vx dtc IN.dts -o OUT.dtb [-I DIR]... [--cc CLANG]   (D154, vx-dtc(1))
//
// A devicetree source through the C preprocessor (the toolchain's clang,
// as the kernel's build runs it on .dts files), then Dtc's parser, as a
// flattened tree.

import Dtc
import HostSystem

func dtcCommand(_ args: [String]) -> Bool {
  var input: String?, output: String?, cc = "clang"
  var includes: [String] = []
  var i = 0
  while i < args.count {
    switch args[i] {
    case "-o" where i + 1 < args.count: output = args[i + 1]; i += 1
    case "-I" where i + 1 < args.count: includes.append(args[i + 1]); i += 1
    case "--cc" where i + 1 < args.count: cc = args[i + 1]; i += 1
    case let a where !a.hasPrefix("-") && input == nil: input = a
    default: fail("usage: vx dtc IN.dts -o OUT.dtb [-I DIR]... [--cc CLANG]")
    }
    i += 1
  }
  guard let input, let output else { fail("usage: vx dtc IN.dts -o OUT.dtb [-I DIR]... [--cc CLANG]") }
  let sourceDirectory = directory(of: input)
  let preprocessed = output + ".i"
  defer { unlink(preprocessed) }
  let cpp = [cc, "-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
             "-I", sourceDirectory.isEmpty ? "." : sourceDirectory] + includes.flatMap { ["-I", $0] } + [input, "-o", preprocessed]
  guard run(cpp, log: nil).ok else { fail("dtc: the preprocessor failed on \(input)") }
  guard let source = try? String(contentsOfFile: preprocessed, encoding: .utf8) else { fail("dtc: can't read \(preprocessed)") }
  let search = includes
  do {
    let tree = try DtsParser.parse(source, file: input) { name, from in
      let here = directory(of: from)
      for dir in [here] + search {
        let path = dir.isEmpty ? name : dir + "/" + name
        if let text = try? String(contentsOfFile: path, encoding: .utf8) { return (text, path) }
      }
      return nil
    }
    writeBytes(try tree.flatten(), to: output)
  } catch {
    fail("dtc: \(error)")
  }
  return true
}

/// The directory part of `path`, "" for a bare name.
private func directory(of path: String) -> String {
  guard let slash = path.lastIndex(of: "/") else { return "" }
  return slash == path.startIndex ? "/" : String(path[..<slash])
}
