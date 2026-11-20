// SPDX-License-Identifier: BSD-3-Clause

import FirmwarePackages
import Testing

private let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let record = """
  # a comment
  package demo
  arch arm64
  licence LICENCE.demo
  source Somebody's repository at abc123
  file z/b.bin \(abc) 3
  file a/x.bin \(abc) 3 from x.bin
  """

@Test func aPackageRecordParses() throws {
  let p = try Firmware.parse(record, file: "demo.pkg")
  #expect(p.name == "demo" && p.arch == "arm64" && p.licence == "LICENCE.demo")
  #expect(p.source == "Somebody's repository at abc123")
  // Sorted by path; `from` defaults to the path.
  #expect(p.files.map { $0.path } == ["a/x.bin", "z/b.bin"])
  #expect(p.files[0].from == "x.bin" && p.files[1].from == "z/b.bin")
  #expect(p.files[1].size == 3 && p.files[1].sha256 == abc)
}

@Test func badRecordsAreRefusedAtTheirLine() {
  func refused(_ text: String) -> String {
    do { _ = try Firmware.parse(text, file: "t.pkg"); return "" } catch { return error.description }
  }
  let head = "package d\narch arm64\nlicence L\nsource s\n"
  #expect(refused(head).contains("no 'file'"))
  #expect(refused(head + "file a \(abc) 3\nfile a \(abc) 3").contains("t.pkg:6: 'a' twice"))
  #expect(refused(head + "file ../a \(abc) 3").contains("without '..'"))
  #expect(refused(head + "file /a \(abc) 3").contains("without '..'"))
  #expect(refused(head + "file a \(abc.uppercased()) 3").contains("SHA-256"))
  #expect(refused(head + "file a abc 3").contains("SHA-256"))
  #expect(refused(head + "file a \(abc) 0").contains("isn't a size"))
  #expect(refused(head + "file a \(abc)").contains("takes PATH SHA256 SIZE"))
  #expect(refused(head + "file a \(abc) 3\nmystery x").contains("unknown directive 'mystery'"))
  #expect(refused("arch arm64").contains("'package' must come first"))
  #expect(refused("package d\nlicence L\nsource s\nfile a \(abc) 3").contains("no 'arch'"))
  #expect(refused("package d\narch arm64\nsource s\nfile a \(abc) 3").contains("no 'licence'"))
  #expect(refused("package D\n").contains("takes a name"))
}

@Test func theHashAndSizeAreChecked() throws {
  let p = try Firmware.parse(record, file: "demo.pkg")
  let file = p.files[0]
  #expect(Firmware.digest(Array("abc".utf8)) == abc)
  #expect(Firmware.mismatch(file, Array("abc".utf8)) == nil)
  #expect(Firmware.mismatch(file, Array("abd".utf8))?.contains("SHA-256") == true)
  #expect(Firmware.mismatch(file, Array("abcd".utf8))?.contains("4 bytes, the record says 3") == true)
  #expect(Firmware.mismatch(file, [])?.contains("0 bytes") == true)
}

@Test func aLicenceNotAcceptedInTheReadmeIsRefused() throws {
  let readme = """
    # Firmware

    | What | Licence |
    |---|---|
    | `rge` | `BSD-2-Clause` |

    ## Packages

    | Package | Licence | Accepted |
    |---|---|---|
    | `demo` | `LICENCE.demo` | the owner |
    | `other` | `MIT` | the owner |

    ## Elsewhere

    | `late` | `X` | no |
    """
  let accepted = Firmware.accepted(readme: readme)
  #expect(accepted.count == 2 && accepted[0].package == "demo" && accepted[1].licence == "MIT")
  var p = try Firmware.parse(record, file: "demo.pkg")
  try Firmware.checkLicence(p, accepted: accepted)
  // A package the README lists, under another licence, or not at all.
  p.licence = "MIT"
  #expect(throws: FirmwareError.self) { try Firmware.checkLicence(p, accepted: accepted) }
  p.licence = "LICENCE.demo"
  p.name = "unlisted"
  #expect(throws: FirmwareError.self) { try Firmware.checkLicence(p, accepted: accepted) }
  #expect(throws: FirmwareError.self) { try Firmware.checkLicence(p, accepted: []) }
}

@Test func aDriversFirmwareLineMustNameAPackagedFile() throws {
  let p = try Firmware.parse(record, file: "demo.pkg")
  #expect(Firmware.unknown(["a/x.bin"], in: [p]).isEmpty)
  #expect(Firmware.unknown(["a/x.bin", "nope.bin"], in: [p]) == ["nope.bin"])
}
