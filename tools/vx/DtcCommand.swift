// SPDX-License-Identifier: BSD-3-Clause

// vx dtc IN.dts -o OUT.dtb [-I DIR]... [--cc CLANG] [--check]   (D154, vx-dtc(1))
//
// A devicetree source through the C preprocessor (the toolchain's clang,
// as the kernel's build runs it on .dts files), then Dtc's parser, as a
// flattened tree. With --check, the tree also goes through the checks over
// a whole machine's description (D171), as devmgr would take it, with the
// drivers' records under drivers/ (run from the repository's root): the
// output is then optional.

import BoardCheck
import DevMgr
import Dtc
import HostSystem

func dtcCommand(_ args: [String]) -> Bool {
  var input: String?, output: String?, cc = "clang", checking = false
  var includes: [String] = []
  var i = 0
  while i < args.count {
    switch args[i] {
    case "-o" where i + 1 < args.count: output = args[i + 1]; i += 1
    case "-I" where i + 1 < args.count: includes.append(args[i + 1]); i += 1
    case "--cc" where i + 1 < args.count: cc = args[i + 1]; i += 1
    case "--check": checking = true
    case let a where !a.hasPrefix("-") && input == nil: input = a
    default: fail("usage: vx dtc IN.dts [-o OUT.dtb] [-I DIR]... [--cc CLANG] [--check]")
    }
    i += 1
  }
  guard let input, output != nil || checking else { fail("usage: vx dtc IN.dts [-o OUT.dtb] [-I DIR]... [--cc CLANG] [--check]") }
  let sourceDirectory = directory(of: input)
  let preprocessed = (output ?? input) + ".i"
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
    let dtb = try tree.flatten()
    if let output { writeBytes(dtb, to: output) }
    if checking { return check(dtb, named: input) }
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

/// The checks over the tree `dtb` makes, each finding a line; false if any.
/// The arch's DMA default is RISC-V's, which none of the checks reads.
private func check(_ dtb: [UInt8], named name: String) -> Bool {
  do {
    let index = try DriverIndex.load(root: ".")
    let board = try Board.tree(name: name, dtb: dtb, coherentByDefault: true)
    let findings = BoardChecks.run(board, index: index)
    for f in findings { say("\(name): \(f)") }
    say("\(name): \(board.devices.count) devices, \(findings.count) findings")
    return findings.isEmpty
  } catch {
    fail("dtc: \(error)")
  }
}
