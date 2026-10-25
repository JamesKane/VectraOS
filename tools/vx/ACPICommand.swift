// SPDX-License-Identifier: BSD-3-Clause

// vx acpi: the corpus of firmware tables the AML interpreter is tested on
// (drivers/bus/acpi/README.md, D74). It stays out of the tree, in .cache/acpi (one
// directory a machine, each table a file named by signature): firmware
// tables are vendor binaries, and QEMU's are GPL-licensed fixtures.
//
//   vx acpi import [NAME]
//       This machine's tables, from /sys/firmware/acpi/tables (root only:
//       run it with sudo, and the files are given back to you), with the
//       SSDTs firmware loaded at run time (dynamic/, kept as dynamic-NAME),
//       a snapshot of the firmware memory its operation regions read
//       (memory/, from /dev/mem: only ranges /proc/iomem says are firmware
//       memory with no device in them, so reading has no side effects),
//       and Linux's
//       view of its namespace from /sys/bus/acpi/devices, the oracle the
//       interpreter's enumeration is checked against. NAME: the host name.
//   vx acpi fetch-qemu
//       QEMU's tables for x86 (q35, pc, microvm), arm64 virt and riscv64
//       virt: its regression fixtures, at the pinned release below.
//   vx acpi list
//       What the corpus holds.

import FoundationEssentials
import Glibc
import TDACPI

let acpiCorpus = ".cache/acpi"

/// QEMU's fixtures: tests/data/acpi at v11.1.2.
let qemuRelease = "v11.1.2"
let qemuCommit = "4fc49f46dc95d4a27de2509e7fceb2931e91faeb"
let qemuMachines = [("x86/q35", "qemu-x86-q35"), ("x86/pc", "qemu-x86-pc"), ("x86/microvm", "qemu-x86-microvm"),
                    ("aarch64/virt", "qemu-aarch64-virt"), ("riscv64/virt", "qemu-riscv64-virt")]

func acpiCommand(_ args: [String]) -> Bool {
  switch args.first {
  case "import": return acpiImport(name: args.count > 1 ? args[1] : hostName())
  case "fetch-qemu": return acpiFetchQEMU()
  case "list": return acpiList()
  default:
    complain("usage: vx acpi import [NAME] | fetch-qemu | list")
    return false
  }
}


func readFile(_ path: String) -> [UInt8]? {
  FileManager.default.contents(atPath: path).map { [UInt8]($0) }
}

func writeFile(_ path: String, _ bytes: [UInt8]) -> Bool {
  FileManager.default.createFile(atPath: path, contents: Data(bytes))
}

/// Under sudo, gives what we wrote back to the user who asked.
func giveBack(_ path: String) {
  guard let uid = getenv("SUDO_UID").flatMap({ UInt32(String(cString: $0)) }),
    let gid = getenv("SUDO_GID").flatMap({ UInt32(String(cString: $0)) })
  else { return }
  _ = chown(path, uid, gid)
}

func acpiImport(name: String) -> Bool {
  let source = "/sys/firmware/acpi/tables"
  let target = "\(acpiCorpus)/\(name)"
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: source) else {
    complain("can't list \(source)")
    return false
  }
  var tables: [(String, [UInt8])] = []
  for table in names.sorted() {
    var st = stat()
    guard stat("\(source)/\(table)", &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }  // not data/, dynamic/
    guard let bytes = readFile("\(source)/\(table)") else {
      complain("can't read \(source)/\(table): the tables need root. Run: sudo .build/debug/vx acpi import \(name)")
      return false
    }
    tables.append((table, bytes))
  }
  // SSDTs the firmware's methods loaded at run time (Load, LoadTable):
  // Linux's device view includes what they define.
  for table in ((try? FileManager.default.contentsOfDirectory(atPath: "\(source)/dynamic")) ?? []).sorted() {
    if let bytes = readFile("\(source)/dynamic/\(table)") { tables.append(("dynamic-\(table)", bytes)) }
  }
  makeDirectory(acpiCorpus)
  makeDirectory(target)
  giveBack(".cache")
  giveBack(acpiCorpus)
  giveBack(target)
  for (table, bytes) in tables {
    guard writeFile("\(target)/\(table)", bytes) else { fail("can't write \(target)/\(table)") }
    giveBack("\(target)/\(table)")
  }
  // The oracle: Linux's (ACPICA's) view of the same namespace.
  var rows = ["# path\thid\tuid\tadr\tstatus\tmodalias"]
  let devices = "/sys/bus/acpi/devices"
  for device in ((try? FileManager.default.contentsOfDirectory(atPath: devices)) ?? []).sorted() {
    func field(_ f: String) -> String {
      readFile("\(devices)/\(device)/\(f)").map { trimmed(String(decoding: $0, as: UTF8.self)) } ?? ""
    }
    let path = field("path")
    guard !path.isEmpty else { continue }
    rows.append([path, field("hid"), field("uid"), field("adr"), field("status"), field("modalias")].joined(separator: "\t"))
  }
  let oracle = "\(target)/linux-devices.tsv"
  guard writeFile(oracle, Array((rows.joined(separator: "\n") + "\n").utf8)) else { fail("can't write \(oracle)") }
  giveBack(oracle)
  let regions = snapshotMemory(tables: tables, into: target)
  let provenance = """
    This machine's ACPI tables, from /sys/firmware/acpi/tables, and Linux's
    view of its namespace (linux-devices.tsv, from /sys/bus/acpi/devices).
    Firmware: vendor binaries, kept out of the tree. Imported by vx acpi import.

    """
  _ = writeFile("\(target)/PROVENANCE", Array(provenance.utf8))
  giveBack("\(target)/PROVENANCE")
  say("vx acpi: \(tables.count) tables, \(regions) memory regions and \(rows.count - 1) devices in \(target)")
  return true
}

func acpiFetchQEMU() -> Bool {
  let checkout = "\(acpiCorpus)/qemu-src"
  removeTree(checkout)
  makeDirectory(acpiCorpus)
  let url = "https://gitlab.com/qemu-project/qemu.git"
  guard run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", qemuRelease, url, checkout],
            log: nil).ok,
    run(["git", "-C", checkout, "sparse-checkout", "set", "tests/data/acpi"], log: nil).ok
  else {
    complain("fetching QEMU \(qemuRelease) failed")
    return false
  }
  guard let head = capture(["git", "-C", checkout, "rev-parse", "HEAD"]), trimmed(head) == qemuCommit else {
    complain("QEMU \(qemuRelease) isn't the commit pinned (\(qemuCommit)): check the tag before trusting it")
    return false
  }
  for (from, to) in qemuMachines {
    let target = "\(acpiCorpus)/\(to)"
    removeTree(target)
    makeDirectory(target)
    for file in ((try? FileManager.default.contentsOfDirectory(atPath: "\(checkout)/tests/data/acpi/\(from)")) ?? []) {
      guard let bytes = readFile("\(checkout)/tests/data/acpi/\(from)/\(file)"), writeFile("\(target)/\(file)", bytes)
      else { fail("can't copy \(from)/\(file)") }
    }
    let provenance = """
      QEMU's expected ACPI tables for \(from), from tests/data/acpi in QEMU
      \(qemuRelease) (commit \(qemuCommit)), https://gitlab.com/qemu-project/qemu.
      Files without a suffix are the default machine's; DSDT.x and the like
      are the same machine with other options. QEMU is GPL-2.0: kept out of
      the tree. Fetched by vx acpi fetch-qemu.

      """
    _ = writeFile("\(target)/PROVENANCE", Array(provenance.utf8))
  }
  removeTree(checkout)
  say("vx acpi: QEMU \(qemuRelease)'s tables for \(qemuMachines.count) machines in \(acpiCorpus)")
  return true
}

func acpiList() -> Bool {
  guard let machines = try? FileManager.default.contentsOfDirectory(atPath: acpiCorpus), !machines.isEmpty else {
    say("vx acpi: the corpus is empty; vx acpi import, vx acpi fetch-qemu")
    return true
  }
  for machine in machines.sorted() {
    let dir = "\(acpiCorpus)/\(machine)"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    var aml = 0, amlBytes = 0, others = 0
    for f in files where f != "PROVENANCE" && !f.hasSuffix(".tsv") {
      guard let bytes = readFile("\(dir)/\(f)"), let t = try? Table(bytes) else { continue }
      if t.signature == .dsdt || t.signature == .ssdt {
        aml += 1
        amlBytes += t.length
      } else {
        others += 1
      }
    }
    let oracle = FileManager.default.fileExists(atPath: "\(dir)/linux-devices.tsv") ? ", Linux's device view" : ""
    say("\(machine): \(aml) DSDT/SSDTs (\(amlBytes / 1024) KiB of AML), \(others) other tables\(oracle)")
  }
  return true
}

// MARK: The memory snapshot

/// Ranges of plain firmware memory: top-level /proc/iomem entries named
/// Reserved, ACPI Non-volatile Storage or ACPI Tables, less anything a
/// device claims inside them. Reading these has no side effects. Root
/// only: others see zeros for every address.
func firmwareMemory() -> [(start: UInt64, end: UInt64)] {
  guard let text = readFile("/proc/iomem").map({ String(decoding: $0, as: UTF8.self) }) else { return [] }
  var safe: [(start: UInt64, end: UInt64)] = []
  var claimed: [(start: UInt64, end: UInt64)] = []
  var inFirmware = false
  for line in text.split(separator: "\n") {
    let depth = line.prefix { $0 == " " }.count
    let parts = line.drop { $0 == " " }.split(separator: " : ", maxSplits: 1)
    guard parts.count == 2 else { continue }
    let range = parts[0].split(separator: "-")
    guard range.count == 2, let start = UInt64(range[0], radix: 16), let end = UInt64(range[1], radix: 16), end > 0 else {
      continue
    }
    if depth == 0 {
      inFirmware = ["Reserved", "ACPI Non-volatile Storage", "ACPI Tables"].contains(String(parts[1]))
      if inFirmware { safe.append((start, end)) }
    } else if inFirmware {
      claimed.append((start, end))
    }
  }
  // Take the claimed ranges out.
  var out: [(start: UInt64, end: UInt64)] = []
  for r in safe {
    var pieces = [r]
    for c in claimed {
      pieces = pieces.flatMap { p -> [(start: UInt64, end: UInt64)] in
        guard c.start <= p.end, c.end >= p.start else { return [p] }
        var keep: [(start: UInt64, end: UInt64)] = []
        if c.start > p.start { keep.append((p.start, c.start - 1)) }
        if c.end < p.end { keep.append((c.end + 1, p.end)) }
        return keep
      }
    }
    out += pieces
  }
  return out
}

/// Runs the tables as Linux would, for where their regions are: memory
/// reads come from /dev/mem within firmware memory, writes go to an
/// overlay (never the machine), `_OSI` answers as Windows does.
final class LiveFirmwareHost: ACPIHost {
  let fd: Int32
  let safe: [(start: UInt64, end: UInt64)]
  var overlay: [UInt64: UInt8] = [:]

  init(fd: Int32, safe: [(start: UInt64, end: UInt64)]) {
    self.fd = fd
    self.safe = safe
  }

  func isSafe(_ address: UInt64, _ length: Int) -> Bool {
    safe.contains { address >= $0.start && address &+ UInt64(length) - 1 <= $0.end }
  }

  func memory(_ address: UInt64, _ length: Int) -> [UInt8]? {
    guard isSafe(address, length) else { return nil }
    var bytes = [UInt8](repeating: 0, count: length)
    let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(Int64(bitPattern: address))) }
    return n == length ? bytes : nil
  }

  func supportsInterface(_ name: [UInt8]) -> Bool { OSInterfaces.claims(name) }
  func sleep(milliseconds: UInt64) {}
  func stall(microseconds: UInt64) {}
  func notify(_ node: Int, _ value: UInt64) {}
  func timer() -> UInt64 { UInt64(now() * 1e7) }
  func debug(_ text: [UInt8]) {}
  func fatal(type: UInt8, code: UInt32, argument: UInt64) {}

  func readRegion(_ a: RegionAccess) -> UInt64? {
    guard a.space == 0, var bytes = memory(a.address, a.width) else { return nil }
    for i in 0..<a.width { if let o = overlay[a.address + UInt64(i)] { bytes[i] = o } }
    var v: UInt64 = 0
    for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
    return v
  }

  func writeRegion(_ a: RegionAccess, _ value: UInt64) -> Bool {
    guard a.space == 0, isSafe(a.address, a.width) else { return false }
    for i in 0..<a.width { overlay[a.address + UInt64(i)] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    return true
  }
}

/// Saves each SystemMemory region that lies in firmware memory, whole,
/// as memory/ADDRESS (16 hex digits). Returns how many.
func snapshotMemory(tables: [(String, [UInt8])], into target: String) -> Int {
  let fd = open("/dev/mem", O_RDONLY | O_CLOEXEC)
  guard fd >= 0 else {
    complain("can't open /dev/mem: no memory snapshot (operation regions will read nothing)")
    return 0
  }
  defer { close(fd) }
  let host = LiveFirmwareHost(fd: fd, safe: firmwareMemory())
  var ns = Namespace(integerBits: 64)
  let aml = tables.filter { $0.0 == "DSDT" || $0.0.hasPrefix("SSDT") || $0.0.hasPrefix("dynamic-SSDT") }
    .sorted { ($0.0 == "DSDT" ? 0 : 1, $0.0) < ($1.0 == "DSDT" ? 0 : 1, $1.0) }
  for (name, bytes) in aml {
    guard let t = try? Table(bytes) else { continue }
    do { try ns.load(t, host: host) } catch { complain("\(name): \(error)") }
  }
  let dir = "\(target)/memory"
  removeTree(dir)
  makeDirectory(dir)
  giveBack(dir)
  var saved = 0, refused = 0
  for r in ns.regions(host: host) where r.space == 0 && r.length > 0 && r.length <= 1 << 20 {
    guard host.isSafe(r.base, Int(r.length)) else { continue }  // device registers: never read
    guard let bytes = host.memory(r.base, Int(r.length)) else {
      refused += 1
      continue
    }
    let hex = String(r.base, radix: 16)
    let path = "\(dir)/\(String(repeating: "0", count: max(0, 16 - hex.count)))\(hex)"
    guard writeFile(path, bytes) else { continue }
    giveBack(path)
    saved += 1
  }
  if refused > 0 {
    // CONFIG_IO_STRICT_DEVMEM: the kernel marks ACPI NVS busy, and
    // /dev/mem then refuses it. Booting once with iomem=relaxed allows it.
    complain("""
      /dev/mem refused \(refused) firmware memory regions (the kernel marks ACPI NVS busy under \
      CONFIG_IO_STRICT_DEVMEM). Boot once with iomem=relaxed and import again to snapshot them.
      """)
  }
  return saved
}
