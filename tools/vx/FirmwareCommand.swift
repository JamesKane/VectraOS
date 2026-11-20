// SPDX-License-Identifier: BSD-3-Clause

// vx firmware list | check | fetch   (D164, vx-firmware(1))
//
// The firmware packages (firmware/packages/*.pkg) and the cache that holds
// their files, .cache/firmware/PATH. Nothing is downloaded: `fetch` fills
// the cache from a directory, here or on a machine ssh reaches (the
// board's /boot/firmware), and refuses a file that isn't its record's.

import FirmwarePackages
import HostSystem

private let packagesDirectory = "firmware/packages"
private let cacheDirectory = ".cache/firmware"
private let readmePath = "firmware/README.md"

/// Every package, from the tracked records.
private func loadPackages() -> [FirmwarePackage] {
  let listed = capture(["git", "ls-files", "--cached", "--others", "--exclude-standard", packagesDirectory]) ?? ""
  var out: [FirmwarePackage] = []
  for file in listed.split(whereSeparator: \.isNewline) where file.hasSuffix(".pkg") {
    guard let text = try? String(contentsOfFile: String(file), encoding: .utf8) else { fail("firmware: can't read \(file)") }
    do {
      out.append(try Firmware.parse(text, file: String(file)))
    } catch {
      fail("firmware: \(error)")
    }
  }
  return out
}

private func acceptedPackages() -> [(package: String, licence: String)] {
  Firmware.accepted(readme: (try? String(contentsOfFile: readmePath, encoding: .utf8)) ?? "")
}

/// The `firmware PATH` lines of every driver's record, with the record's file.
private func requested() -> [(driver: String, path: String)] {
  let listed = capture(["git", "ls-files", "drivers"]) ?? ""
  var out: [(driver: String, path: String)] = []
  for file in listed.split(whereSeparator: \.isNewline) where file.hasSuffix("/driver.manifest") {
    var driver = ""
    let text = (try? String(contentsOfFile: String(file), encoding: .utf8)) ?? ""
    for raw in text.split(whereSeparator: \.isNewline) {
      let words = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map {
        $0.split(whereSeparator: { $0 == " " || $0 == "\t" })
      } ?? []
      if words.count == 2, words[0] == "driver" { driver = String(words[1]) }
      if words.count == 2, words[0] == "firmware" { out.append((driver, String(words[1]))) }
    }
  }
  return out
}

private func cached(_ file: FirmwareFile) -> [UInt8]? {
  FileManager.default.contents(atPath: "\(cacheDirectory)/\(file.path)").map { [UInt8]($0) }
}

func firmwareCommand(_ args: [String]) -> Bool {
  let usage = "usage: vx firmware list | check [--require] | fetch [--from [HOST:]DIR] [PACKAGE...]"
  guard let sub = args.first else { fail(usage) }
  let rest = Array(args.dropFirst())
  let packages = loadPackages()
  switch sub {
  case "list":
    guard rest.isEmpty else { fail(usage) }
    for p in packages {
      let have = p.files.filter { f in cached(f).map { Firmware.mismatch(f, $0) == nil } ?? false }.count
      say("\(p.name)  \(p.arch)  \(p.licence)  \(have)/\(p.files.count) files cached")
      for f in p.files { say("  \(f.path)  \(f.size)  \(f.sha256)") }
    }
    return true
  case "check":
    var require = false
    for a in rest {
      guard a == "--require" else { fail(usage) }
      require = true
    }
    return check(packages, require: require)
  case "fetch":
    var source: String?
    var names: [String] = []
    var i = 0
    while i < rest.count {
      if rest[i] == "--from", i + 1 < rest.count { source = rest[i + 1]; i += 1 } else if !rest[i].hasPrefix("-") {
        names.append(rest[i])
      } else { fail(usage) }
      i += 1
    }
    for n in names where !packages.contains(where: { $0.name == n }) { fail("firmware: no package '\(n)'") }
    return fetch(packages.filter { names.isEmpty || names.contains($0.name) }, from: source)
  default:
    fail(usage)
  }
}

/// Licences accepted, files in the cache what their records say, and every
/// `firmware` line of a driver's record naming a file a package holds.
private func check(_ packages: [FirmwarePackage], require: Bool) -> Bool {
  var problems = 0
  func problem(_ text: String) {
    complain("firmware: \(text)")
    problems += 1
  }
  let accepted = acceptedPackages()
  var files = 0, missing = 0
  for p in packages {
    do { try Firmware.checkLicence(p, accepted: accepted) } catch { problem("\(error)") }
    for f in p.files {
      files += 1
      guard let bytes = cached(f) else {
        missing += 1
        if require { problem("\(f.path): not in \(cacheDirectory) (vx firmware fetch --from DIR)") }
        continue
      }
      if let why = Firmware.mismatch(f, bytes) { problem(why) }
    }
  }
  for r in requested() where !packages.contains(where: { $0.files.contains { $0.path == r.path } }) {
    problem("driver \(r.driver) names '\(r.path)', which no package holds")
  }
  if problems > 0 { return false }
  say("vx: firmware: \(packages.count) packages, \(files) files, \(files - missing) cached and matching\(missing > 0 ? ", \(missing) not cached" : "")")
  return true
}

/// Each file of `packages` copied from `source` into the cache, only once it is its record's.
private func fetch(_ packages: [FirmwarePackage], from source: String?) -> Bool {
  let accepted = acceptedPackages()
  for p in packages {
    do { try Firmware.checkLicence(p, accepted: accepted) } catch { fail("firmware: \(error)") }
  }
  var failed = false
  for p in packages {
    for f in p.files {
      if let bytes = cached(f), Firmware.mismatch(f, bytes) == nil { continue }
      guard let source else {
        complain("firmware: \(f.path): not cached, and no --from")
        failed = true
        continue
      }
      let destination = "\(cacheDirectory)/\(f.path)"
      let temporary = destination + ".part"
      makeDirectory(String(destination[..<destination.lastIndex(of: "/")!]))
      unlink(temporary)
      if let colon = source.firstIndex(of: ":"), !source[..<colon].contains("/") {
        guard run(["scp", "-q", "\(source)/\(f.from)", temporary], log: nil).ok else {
          complain("firmware: \(f.path): scp from \(source)/\(f.from) failed")
          failed = true
          continue
        }
      } else {
        guard let data = FileManager.default.contents(atPath: "\(source)/\(f.from)") else {
          complain("firmware: \(f.path): can't read \(source)/\(f.from)")
          failed = true
          continue
        }
        writeBytes([UInt8](data), to: temporary)
      }
      let bytes = FileManager.default.contents(atPath: temporary).map { [UInt8]($0) } ?? []
      if let why = Firmware.mismatch(f, bytes) {
        unlink(temporary)
        complain("firmware: refused \(why)")
        failed = true
        continue
      }
      guard rename(temporary, destination) == 0 else { fail("firmware: can't place \(destination)") }
      say("vx: firmware: \(f.path) cached")
    }
  }
  if !failed { say("vx: firmware: \(packages.map { $0.name }.joined(separator: ", ")) cached") }
  return !failed
}
