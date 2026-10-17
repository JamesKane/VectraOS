// SPDX-License-Identifier: BSD-3-Clause

// bin/launch-test: the launcher natively (V2's item 4). bin/launcher
// starts it from its manifest (manifests/launch-test.manifest) beside
// services a and b (bin/launch-service), and exits with its code
// (launcher.until=launch-test, the boot-launch test). It reads its
// namespace from its Startup (D65), reads every /svc/*/status, reaches a
// through b, kills a through /svc/launcher/ctl and reaches its next
// instance by the same paths, and reads UTC from the page every process
// is given (D48), the RTC's on amd64, and checks the services' trees
// against their pages' FILES (D86). It exits 0 if every check passed.

import Guide
import IPC
import Node
import Sys

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("launch-test: FAILED: \(name)")
  }
}

/// A String's bytes are `text`'s.
func same(_ string: String, _ text: StaticString) -> Bool {
  unsafe string.utf8.elementsEqual(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}

/// The text at `path`, if it can be read.
func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var c = try? ns.open(path) else { return nil }
  return try? c.readText()
}

/// Whether `text` has the line `line` (bytes).
func hasLine(_ text: String, _ line: StaticString) -> Bool {
  var current: [UInt8] = []
  for b in text.utf8 {
    if b == 0x0A {
      if same(String(decoding: current, as: UTF8.self), line) { return true }
      current = []
    } else {
      current.append(b)
    }
  }
  return false
}

/// Whether `text` holds `part` anywhere (bytes: Embedded String has no
/// contains).
func holds(_ text: String, _ part: StaticString) -> Bool {
  let t = Array(text.utf8)
  let p = unsafe Array(UnsafeBufferPointer(start: part.utf8Start, count: part.utf8CodeUnitCount))
  guard p.count <= t.count else { return false }
  for i in 0...(t.count - p.count) where Array(t[i..<i + p.count]) == p { return true }
  return false
}

/// The line of `text` that starts with `prefix`, if there is one.
func line(_ text: String, startingWith prefix: StaticString) -> String? {
  let p = unsafe Array(UnsafeBufferPointer(start: prefix.utf8Start, count: prefix.utf8CodeUnitCount))
  var current: [UInt8] = []
  for b in text.utf8 {
    if b == 0x0A {
      if current.starts(with: p) { return String(decoding: current, as: UTF8.self) }
      current = []
    } else {
      current.append(b)
    }
  }
  return nil
}

/// The services' trees against the manual (D86): every page in /lib/man
/// whose FILES names a path under /svc/SERVICE/ claims that file. Each
/// claimed file exists, and a service any page claims has each of its
/// files documented, none more. A path with a parameter, such as
/// /svc/x/<name>, claims nothing, and a service this machine doesn't run
/// is passed over.
func documentedTrees(_ ns: Namespace) {
  guard let index = readText(ns, "/lib/man/index") else { return check(false, "the manual's index") }
  var pages: [String] = []
  for row in index.utf8.split(separator: 0x0A).dropFirst() {
    let f = row.split(separator: 0x09, omittingEmptySubsequences: false)
    guard f.count == 6, f[3].isEmpty else { continue }
    let path = "/lib/man/" + String(decoding: f[2], as: UTF8.self) + "/" + String(decoding: f[1], as: UTF8.self)
    if !pages.contains(where: { $0.utf8.elementsEqual(path.utf8) }) { pages.append(path) }
  }
  var claimed: [(service: String, file: String, path: String)] = []
  for path in pages {
    guard let text = readText(ns, path), let page = try? Page(Array(text.utf8), file: path) else {
      print("launch-test: \(path) can't be read")
      check(false, "every page in the index reads")
      continue
    }
    var files = false
    for b in page.blocks {
      if b.kind == .heading || b.kind == .node { files = b.kind == .heading && b.text == Array("FILES".utf8) }
      guard files, b.kind == .definition, let spans = try? Inline.spans(b.text) else { continue }
      for s in spans where s.kind == .literal && s.text.starts(with: Array("/svc/".utf8)) && !s.text.contains(0x3C) {
        let parts = s.text.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
        guard parts.count >= 3 else { continue }
        claimed.append((parts[1], parts[2], String(decoding: s.text, as: UTF8.self)))
      }
    }
  }
  // Only what this machine runs: the time service, say, runs on amd64 alone.
  let running = ((try? ns.list("/svc")) ?? []).map { $0.name }
  claimed = claimed.filter { c in running.contains { $0.utf8.elementsEqual(c.service.utf8) } }
  var services: [String] = []
  for c in claimed {
    if (try? ns.open(c.path)) == nil {
      print("launch-test: \(c.path) is documented and isn't there")
      check(false, "every documented file is in its tree")
    }
    if !services.contains(where: { $0.utf8.elementsEqual(c.service.utf8) }) { services.append(c.service) }
  }
  for service in services {
    for entry in (try? ns.list("/svc/" + service)) ?? [] {
      let documented = claimed.contains {
        $0.service.utf8.elementsEqual(service.utf8) && $0.file.utf8.elementsEqual(entry.name.utf8)
      }
      if !documented {
        print("launch-test: /svc/\(service)/\(entry.name) is in its tree and on no page")
        check(false, "every file in a documented tree is documented")
      }
    }
  }
  print("launch-test: the manual documents \(claimed.count) files of \(services.count) trees")
  check(!claimed.isEmpty, "the manual documents a tree")
}

/// 9gate (D77, D78): this node's key, 32 bytes in hex; nothing listening
/// or imported until its ctl says so; and a line it can't take refused.
/// A normal image has no listener: no cpu server announces its port (D77).
func gate(_ ns: Namespace) {
  guard let tcp = try? ns.list("/net/tcp") else { return check(false, "/net/tcp lists its conversations") }
  let conversations = tcp.map { $0.name }.filter { n in
    !n.utf8.isEmpty && n.utf8.allSatisfy { (0x30...0x39).contains($0) }
  }
  check(!conversations.contains { n in
    holds(readText(ns, "/net/tcp/\(n)/local") ?? "", "!17019")
      && line(readText(ns, "/net/tcp/\(n)/status") ?? "", startingWith: "Listen") != nil
  }, "no cpu server listens in a normal image")
  let key = Array((readText(ns, "/svc/9gate/key") ?? "").utf8)
  let digit = { (b: UInt8) in (0x30...0x39).contains(b) || (0x61...0x66).contains(b) }
  check(key.count == 65 && key[64] == 0x0A && key[..<64].allSatisfy(digit), "9gate's key is 32 bytes in hex")
  check(readText(ns, "/svc/9gate/status").map { $0.isEmpty } ?? false, "9gate listens for nothing until told")
  guard var ctl = try? ns.open("/svc/9gate/ctl") else { return check(false, "9gate's ctl") }
  check((try? ctl.writeText("listen")) == nil, "9gate's ctl refuses a line it can't take")
}

/// devmgr (V2 item 7c, D74), once it has bound what it binds: edu, bound
/// with a BTI on the machine's IOMMU, its driver's findings (its registers,
/// interrupt and DMA through that BTI); every IOMMU taken; on amd64 the
/// CMOS clock among ACPI's platform devices.
func devices(_ ns: Namespace) {
  var status = ""
  let deadline = Clock.monotonic() + 30_000_000_000
  while Clock.monotonic() < deadline {
    status = readText(ns, "/svc/devmgr/status") ?? ""
    if line(status, startingWith: "bound ") != nil { break }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  print("launch-test: /svc/devmgr/status: \(status)")
  check(line(status, startingWith: "bound ") != nil, "devmgr binds its drivers")
  let edu = line(status, startingWith: "pci-00:10.0 1234:11e8 00.ff.00 edu-00:10.0 running dma ") ?? ""
  check(!edu.isEmpty && !holds(edu, "passthrough") && !holds(edu, "dma none"), "edu is bound, its BTI on the IOMMU")
  let iommus = readText(ns, "/svc/devmgr/iommus") ?? ""
  print("launch-test: /svc/devmgr/iommus: \(iommus)")
  check(holds(iommus, " ok\n") && !holds(iommus, "refused"), "devmgr names the IOMMUs to the kernel")
  let driver = readText(ns, "/svc/devmgr/drivers/edu-00:10.0/status") ?? ""
  print("launch-test: edu: \(driver)")
  check(driver.utf8.starts(with: "edu 1.0, live, 10! = 3628800, config 1234:11e8, bars 0, confined, irq ".utf8),
        "edu's registers, configuration space and confinement")
  check(holds(driver, " level-") && holds(driver, " 100 taken"), "edu's interrupt, routed through _PRT")
  check(holds(driver, "dma 4096 bytes there and back") && !holds(driver, "FAILED"), "edu's DMA through its BTI")
  #if arch(x86_64)
    check(holds(status, " PNP0B00 - - unbound"), "the CMOS clock, a platform device")
  #endif
  keyboard(ns, status)
  network(ns, status)
}


/// The plumber (V2 item 8, D85): plumber(4)'s files at /mnt/plumb. A URL
/// written to send reaches web's reader, rewritten to its port; a message
/// no rule takes is refused; and a rule appended to rules whose `plumb
/// client` starts cat (tier 1's: not rv64 yet) has its message held until
/// cat opens the port, then printed by cat to the log, on the console.
func plumbing(_ ns: Namespace) {
  func message(_ data: String) -> [UInt8] { Array("launch-test\n\n/\ntext\n\n\(data.utf8.count)\n\(data)".utf8) }
  guard var web = try? ns.open("/mnt/plumb/web"), var send = try? ns.open("/mnt/plumb/send") else {
    return check(false, "the plumber's send and web")
  }
  web.connection.timeout = 10_000_000_000
  check((try? send.write(offset: 0, message("https://vectra-os.org"))) != nil, "send takes a URL")
  let got = (try? web.read(offset: 0, max: 8192)) ?? []
  check(got == Array("launch-test\nweb\n/\ntext\n\n21\nhttps://vectra-os.org".utf8), "web's reader gets it")
  check((try? send.write(offset: 0, message("nothing takes this"))) == nil, "a message no rule takes is refused")
  #if !arch(riscv64)
    guard var rules = try? ns.open("/mnt/plumb/rules") else { return check(false, "the plumber's rules") }
    let rule = "type is text\ndata matches 'hello .*'\nplumb to greet\nplumb client cat /mnt/plumb/greet\n"
    check((try? rules.writeText(rule)) != nil, "a rule appended")
    check((try? send.write(offset: 0, message("hello from the plumber"))) != nil, "its message held, cat started")
    var screen = ""
    let deadline = Clock.monotonic() + 10_000_000_000
    while Clock.monotonic() < deadline {
      screen = readText(ns, "/mnt/console/screen") ?? ""
      if holds(screen, "hello from the plumber") { break }
      sleep(until: Clock.monotonic() + 20_000_000)
    }
    check(holds(screen, "hello from the plumber"), "cat read the held message from its port")
  #endif
}

/// Its /env (D81): a group of its own, its manifest's `env` lines in it,
/// each a list of one word ended by a NUL; written and read back.
func environment(_ ns: Namespace) {
  check(ns.environment("LAUNCH_TEST").map { $0.count == 1 && same($0[0], "yes") } ?? false,
        "its /env holds its manifest's env lines")
  try? ns.setEnvironment("words", Array("a\u{0}b c\u{0}".utf8))
  check(ns.getenv("words").map { same($0, "a b c") } ?? false, "a variable written to /env reads back")
}

/// The console (V2 item 8): the log on the framebuffer. A line logged here
/// shows on its screen soon after (its title has scrolled off by then).
func console(_ ns: Namespace) {
  print("launch-test: on the console")
  var screen = ""
  let deadline = Clock.monotonic() + 10_000_000_000
  while Clock.monotonic() < deadline {
    screen = readText(ns, "/mnt/console/screen") ?? ""
    if holds(screen, "> launch-test: on the console") { break }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  check(holds(screen, "> launch-test: on the console"), "a line logged shows on the console")
  let status = readText(ns, "/mnt/console/status") ?? ""
  print("launch-test: /mnt/console/status: \(status)")
  check(holds(status, "framebuffer ") && !holds(status, "records 0 ") && !holds(status, "frames 0 "),
        "the console reads the debuglog and draws it")
}

/// The keyboard (V2 item 7d, D83): virtio-input bound, MSI-X where the
/// kernel has MSIs and INTx on rv64's PLIC, pushing its keys to kbdfs. Keys
/// typed through QEMU's monitor (qemu.sh's `qemu: sendkey`) come out of
/// kbdfs's /dev/cons as a cooked line (to the console's shell where rc is
/// built), then, with /dev/kbd open, as kbd's `k`, `c` and `K` messages.
/// Each read waits for its keys (D84).
func keyboard(_ ns: Namespace, _ status: String) {
  let bound = line(status, startingWith: "pci-00:11.0 1af4:1052 ") ?? ""
  check(holds(bound, " virtio-input-00:11.0 running dma "), "virtio-input is bound")

  if (try? ns.memory("/bin/rc", executable: true)) != nil {
    consoleShell(ns)  // cons is the shell's
  } else if var cons = try? ns.open("/dev/cons") {
    // cons: a line, cooked.
    cons.connection.timeout = 20_000_000_000
    print("qemu: sendkey h i ret")
    var typed: [UInt8] = []
    while !typed.contains(0x0A), let more = try? cons.read(offset: 0, max: 64), !more.isEmpty { typed += more }
    check(typed == Array("hi\n".utf8), "keys typed reach /dev/cons as a line")
  } else {
    check(false, "keys typed reach /dev/cons as a line")
  }

  // kbd: what is held and what was typed.
  if var kbd = try? ns.open("/dev/kbd") {
    kbd.connection.timeout = 20_000_000_000
    print("qemu: sendkey a")
    // Enter's release, from typing the line, may come first: a K after
    // kbd opened, as kbdfs tracks keys held whether kbd is open or not.
    let typed = Array("ka\0ca\0K\0".utf8)
    func seen(_ b: [UInt8]) -> Bool {
      b.count >= typed.count && (0...(b.count - typed.count)).contains { Array(b[$0..<$0 + typed.count]) == typed }
    }
    var bytes: [UInt8] = []
    while !seen(bytes), bytes.count < 64,
      let more = try? kbd.read(offset: 0, max: 64), !more.isEmpty
    {
      bytes += more
    }
    check(seen(bytes), "/dev/kbd: a held (k), typed (c), let go (K)")
  } else {
    check(false, "/dev/kbd: a held (k), typed (c), let go (K)")
  }

  let driver = readText(ns, "/svc/devmgr/drivers/virtio-input-00:11.0/status") ?? ""
  print("launch-test: virtio-input: \(driver)")
  #if arch(riscv64)
    check(holds(driver, "interrupt INTx"), "virtio-input on INTx (the PLIC)")
  #else
    check(holds(driver, "interrupt MSI-X"), "virtio-input on MSI-X")
  #endif
  check(holds(driver, "keys to /dev/kbin") && holds(driver, ", refused 0\n"), "its keys go to kbdfs")
}

/// The console's shell (shell/rc/shell.manifest): rc on kbdfs's /dev/cons,
/// in kbdfs's note group. A line typed runs, its output on the console; a
/// program run has the terminal until Delete interrupts it, and rc reads
/// the next line. Where rc is built (tier 1).
func consoleShell(_ ns: Namespace) {
  check(hasLine(readText(ns, "/svc/launcher/status") ?? "", "shell running restarts 0"), "the console's shell runs")
  check(screenRow(ns, "console shell", typing: "e c h o spc c o n s o l e spc s h e l l ret"),
        "a line typed to the shell runs, on the console")
  // cat, started, has the terminal; Delete ends it, and rc reads on.
  let cats = processes(ns, named: "cat").count
  print("qemu: sendkey c a t ret")
  let deadline = Clock.monotonic() + 10_000_000_000
  while processes(ns, named: "cat").count <= cats && Clock.monotonic() < deadline {
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  check(processes(ns, named: "cat").count > cats, "the shell starts cat")
  print("qemu: sendkey delete")
  check(screenRow(ns, "back", typing: "e c h o spc b a c k ret"), "Delete interrupts cat, and the shell reads on")
  check(processes(ns, named: "cat").count == cats, "cat is gone")
}

/// Whether the console shows `row` as a row of its own within 10 s, after
/// `typing` keys.
func screenRow(_ ns: Namespace, _ row: StaticString, typing: String) -> Bool {
  print("qemu: sendkey \(typing)")
  let deadline = Clock.monotonic() + 10_000_000_000
  while Clock.monotonic() < deadline {
    if hasLine(readText(ns, "/mnt/console/screen") ?? "", row) { return true }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  print("launch-test: the console's screen:\n\(readText(ns, "/mnt/console/screen") ?? "")")
  return false
}

/// The pids of /proc's running processes called `name`.
func processes(_ ns: Namespace, named name: String) -> [String] {
  let prefix = Array(name.utf8) + [0x20]
  return ((try? ns.list("/proc")) ?? []).map({ $0.name }).filter { n in
    guard let status = readText(ns, "/proc/" + n + "/status") else { return false }
    return Array(status.utf8.prefix(prefix.count)) == prefix
  }
}

/// The network's device (V3, D82): virtio-net bound at slot 0x12, its
/// ether(3) directory at /net/ether0. An ARP request for QEMU's gateway
/// (10.0.2.2), written to a conversation of ARP's type, and the gateway's
/// reply read from it: a frame each way through the device. The request
/// itself comes back first, as a broadcast written does in Plan 9.
func network(_ ns: Namespace, _ status: String) {
  check(holds(status, " virtio-net-00:12.0 running dma "), "virtio-net is bound")
  let addr = Array((readText(ns, "/net/ether0/addr") ?? "").utf8)
  check(addr.count == 12, "/net/ether0/addr is an address")
  var mac: [UInt8] = []
  for i in stride(from: 0, to: addr.count - 1, by: 2) {
    mac.append(UInt8(String(decoding: addr[i..<(i + 2)], as: UTF8.self), radix: 16) ?? 0)
  }
  guard mac.count == 6, var ctl = try? ns.open("/net/ether0/clone") else {
    check(false, "an ARP reply from the gateway through /net/ether0")
    return
  }
  let number = String(decoding: ((try? ctl.readAll()) ?? []).filter { $0 != 0x20 }, as: UTF8.self)
  let connected = (try? ctl.writeText("connect 0x806")) != nil
  guard connected, var data = try? ns.open("/net/ether0/\(number)/data") else {
    check(false, "an ARP reply from the gateway through /net/ether0")
    return
  }
  data.connection.timeout = 20_000_000_000
  let us: [UInt8] = [10, 0, 2, 15], gateway: [UInt8] = [10, 0, 2, 2]
  var request: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + mac + [0x08, 0x06]
  request += [0, 1, 0x08, 0x00, 6, 4, 0, 1] + mac + us + [0, 0, 0, 0, 0, 0] + gateway
  request += [UInt8](repeating: 0, count: 60 - request.count)
  let sent = (try? data.write(offset: 0, request)) != nil
  var replied = false
  for _ in 0..<4 {
    guard sent, let f = try? data.read(offset: 0, max: 2048), f.count >= 42 else { break }
    // A reply (op 2) from the gateway, to us.
    if f[20] == 0, f[21] == 2, Array(f[28..<32]) == gateway, Array(f[32..<38]) == mac {
      replied = true
      break
    }
  }
  check(replied, "an ARP reply from the gateway through /net/ether0")
  let stats = readText(ns, "/net/ether0/stats") ?? ""
  print("launch-test: /net/ether0/stats: \(stats)")
  check(holds(stats, "link: 1\n") && !holds(stats, "\nout: 0\n"), "/net/ether0/stats: the link up, a frame out")
  // The same through the one ring (D93): each take waits for a frame.
  var ringReplied = false
  if let channel = try? ns.open("/net/ether0/\(number)/data"), var ring = try? NodeBulkChannel(channel, slots: 4, dataSize: 16 * 1024) {
    ring.timeout = 20_000_000_000
    if (try? ring.write(at: 0, request)) == request.count {
      for _ in 0..<4 {
        guard let f = try? ring.take(max: 2048), f.count >= 42 else { break }
        if f[20] == 0, f[21] == 2, Array(f[28..<32]) == gateway, Array(f[32..<38]) == mac {
          ringReplied = true
          break
        }
      }
    }
  }
  check(ringReplied, "and through the one ring on /net/ether0's data")
  _ = consume data
  _ = consume ctl
  stack(ns)
}

/// The stack on /net/ether0 (D79): DHCP's lease from QEMU, cs and dns,
/// then a dial by name of the echo QEMU forwards 10.0.2.100!7 to (cat), a
/// stream through it both plainly and through the one ring.
func stack(_ ns: Namespace) {
  var lease = ""
  let deadline = Clock.monotonic() + 30_000_000_000
  while Clock.monotonic() < deadline {
    lease = readText(ns, "/net/ndb") ?? ""
    if !lease.isEmpty { break }
    Sys.sleep(until: Clock.monotonic() + 50_000_000)
  }
  // QEMU's restricted network gives no router or name servers.
  check(lease.utf8.elementsEqual("ip=10.0.2.15 ipmask=255.255.255.0\n".utf8), "/net/ndb: DHCP's lease")
  check(holds(readText(ns, "/net/ipifc/0/status") ?? "", "device /net/ether0 "), "/net/ipifc/0/status: the device")
  // Names: cs by the database (/lib/ndb/local's QEMU entries), and dns
  // with no name server to ask.
  let cs = ask(ns, "/net/cs", "tcp!qemu-echo!echo")
  check(cs.answers.count == 1 && same(cs.answers[0], "/net/tcp/clone 10.0.2.100!7"), "/net/cs translates by the database")
  // A name not in the database is dns's to find, and dns has no server.
  check(ask(ns, "/net/cs", "tcp!nowhere!echo").failure == .io, "/net/cs: a name only dns could find")
  check(ask(ns, "/net/cs", "tcp!qemu-echo!nosuch").failure == .invalid, "/net/cs: a service it can't translate")
  check(ask(ns, "/net/dns", "example.com ip").failure == .io, "/net/dns: no name server, a dns failure")
  guard var c = try? ns.dial("tcp!qemu-echo!echo") else { return check(false, "dial tcp!qemu-echo!echo") }
  check(holds(readText(ns, c.dir + "/remote") ?? "", "10.0.2.100!7\n"), "dial tcp!qemu-echo!echo")
  c.data.connection.timeout = 20_000_000_000
  let sent = (0..<16384).map { UInt8(truncatingIfNeeded: $0 % 251) }
  var at = 0
  while at < sent.count, let n = try? c.data.write(offset: 0, Array(sent[at..<min(at + 4096, sent.count)])), n > 0 {
    at += Int(n)
  }
  var echoed: [UInt8] = []
  while echoed.count < sent.count, let bytes = try? c.data.read(offset: 0, max: 8192), !bytes.isEmpty {
    echoed += bytes
  }
  check(echoed == sent, "16 KiB echoed through /net/tcp")
  // The same through the one ring: written whole, read a take at a time.
  var ringEchoed: [UInt8] = []
  if let channel = try? ns.open(c.dir + "/data"), var ring = try? NodeBulkChannel(channel, slots: 4, dataSize: 16 * 1024) {
    ring.timeout = 20_000_000_000
    if (try? ring.put(sent)) != nil {
      while ringEchoed.count < sent.count, let bytes = try? ring.take(max: 8192), !bytes.isEmpty { ringEchoed += bytes }
    }
  }
  check(ringEchoed == sent, "and through the one ring on its data")
  check(holds(readText(ns, c.dir + "/status") ?? "", "Established "), "the connection is established")
  _ = consume c
}

/// A query of /net/cs or /net/dns: its answers, one a read, or why its
/// write failed.
func ask(_ ns: Namespace, _ file: String, _ query: String) -> (answers: [String], failure: NodeIPC.NodeError?) {
  guard var f = try? ns.open(file) else { return ([], .notFound) }
  do throws(NodeIPC.NodeClient.Failure) {
    _ = try f.write(offset: 0, Array(query.utf8))
  } catch {
    if case .remote(let code) = error { return ([], code) }
    return ([], .io)
  }
  var answers: [String] = []
  while let bytes = try? f.read(offset: 0, max: 1024), !bytes.isEmpty { answers.append(String(decoding: bytes, as: UTF8.self)) }
  return (answers, nil)
}

/// The last word of `text`, as a decimal number.
func lastNumber(_ text: String) -> Int64? {
  var n: Int64 = 0, digits = 0
  for b in text.utf8 {
    if b >= 0x30 && b <= 0x39 {
      n = n * 10 + Int64(b - 0x30)
      digits += 1
    } else if b == 0x20 {
      n = 0
      digits = 0
    }
  }
  return digits > 0 ? n : nil
}

/// rc from /bin, given this process's /svc and /bin (its programs, the
/// bootfs service's: D71), an environment group of its own (D81), a job,
/// and stdio, and with `data` this process's /data: `script` run by
/// `rc -c`, which must write `expected` and exit 0.
func rcRuns(_ rc: ProgramEntry, _ script: String, _ expected: [UInt8], _ ns: Namespace, job: borrowing Handle, data: Bool = false,
            _ name: StaticString) {
  do throws(Status) {
    let startup = Startup(args: ["rc", "-c", script])
    guard let svc = try? ns.connect("/svc"), let bin = try? ns.connect("/bin") else { return check(false, name) }
    startup.mount(svc, at: "/svc")
    startup.mount(bin, at: "/bin")
    if let man = try? ns.connect("/lib/man") { startup.mount(man, at: "/lib/man") }  // the manual (D86)
    guard let env = try? ns.connect("/svc/env/new") else { return check(false, name) }
    startup.mount(env, at: "/env")  // a group of its own (D81)
    if let proc = try? ns.connect("/proc") { startup.mount(proc, at: "/proc") }
    if data, let volume = try? ns.connect("/data") { startup.mount(volume, at: "/data", create: true) }  // fs(4)'s volume
    startup.add(try Job.create(parent: job), info: HandleType.info(HandleType.jobDefault))
    // stdin, stdout, and a stderr of its own (D46: a ring per descriptor).
    let stdio = try ChildStdio(for: startup, descriptors: [(0, true), (1, false), (2, false)])
    let process = try Process.create(job: job, name: "rc")
    let thread = try Process.start(process, entry: rc, startup)
    try stdio.closeInput(deadline: Clock.monotonic() + 5_000_000_000)
    let out = try stdio.readAll(deadline: Clock.monotonic() + 10_000_000_000)
    let err = try stdio.stream(2)!.readAll(deadline: Clock.monotonic() + 5_000_000_000)
    _ = try process.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
    let code = try Process.info(process).returnCode
    print("launch-test: rc -c '\(script)' wrote \(out.count) bytes, exited \(code)")
    if !err.isEmpty { print("launch-test:   its stderr: \(String(decoding: err, as: UTF8.self))") }
    check(code == 0 && out == expected, name)
    _ = consume thread
  } catch {
    check(false, name)
    print("launch-test: rc: \(error.rawValue)")
  }
}

/// A terminal of this test's own, as a window is (D75): a cons file in a
/// tree served here, which its program finds at /dev/cons. A read takes
/// a line typed (waiting for one), an empty one ^D's end; a write is shown.
final class TestTerminal: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var cons: TreeNode?
  let typed = Locked<[[UInt8]]>([])
  let shown = Locked<[UInt8]>([])

  init() throws(Status) {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    let typed = self.typed, shown = self.shown
    cons = tree.stream("cons", NodeStream(
      take: { max in
        typed.withLock { (t: inout [[UInt8]]) -> [UInt8]? in t.isEmpty ? nil : Array(t.removeFirst().prefix(max)) }
      },
      write: { (bytes: [UInt8]) throws(NodeError) -> UInt32? in
        shown.withLock { $0 += bytes }
        return UInt32(bytes.count)
      }))
    let d = dispatcher
    _ = try Thread.spawn { try? d.run() }.release()
  }

  /// A channel to its tree, to mount at /dev.
  func channel() throws(Status) -> Handle {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return ends.a
  }

  /// A line typed; "" is ^D.
  func type(_ line: String) {
    typed.withLock { $0.append(Array(line.utf8)) }
    if let cons { tree.ready(cons) }
  }

  /// What it has shown since the last time, once that holds `want`, or
  /// after 5 s.
  func shown(until want: String) -> [UInt8] {
    let end = Clock.monotonic() + 5_000_000_000
    while !contains(shown.withLock { $0 }, Array(want.utf8)) && Clock.monotonic() < end {
      sleep(until: Clock.monotonic() + 10_000_000)
    }
    return shown.withLock { (s: inout [UInt8]) -> [UInt8] in
      defer { s = [] }
      return s
    }
  }

  deinit { dispatcher.stop() }
}

/// rc on a terminal's /dev/cons, as on the console or in a cpu session:
/// started with no descriptors, it takes /dev/cons as its terminal. It
/// prompts, runs a line, lends the terminal to a program reading it (cat,
/// ended by ^D), takes interrupts posted to its note group (killing the
/// program, abandoning the rest of the line, or running its sigint), and
/// runs its sigexit as it exits.
func rcOnCons(_ rc: ProgramEntry, _ ns: Namespace, job: borrowing Handle) {
  do {
    let terminal = try TestTerminal()
    let startup = Startup(args: ["rc"])
    guard let svc = try? ns.connect("/svc"), let bin = try? ns.connect("/bin") else {
      return check(false, "rc on a cons: /svc and /bin")
    }
    startup.mount(svc, at: "/svc")
    startup.mount(bin, at: "/bin")
    startup.mount(try terminal.channel(), at: "/dev")
    if let env = try? ns.connect("/svc/env/new") { startup.mount(env, at: "/env") }
    // Its own note group, which its programs share.
    let group = try Job.create(parent: job)
    startup.add(try group.duplicate(), info: HandleType.info(HandleType.jobDefault))
    let process = try Process.create(job: group, name: "rc")
    let pid = try process.info().koid
    let thread = try Process.start(process, entry: rc, startup)
    func interrupt() {
      sleep(until: Clock.monotonic() + 500_000_000)  // cat started
      if var g = try? ns.open("/proc/\(pid)/notepg") { try? g.writeText("interrupt") }
    }
    func shows(_ bytes: [UInt8], _ text: String) -> Bool { contains(bytes, Array(text.utf8)) }
    check(shows(terminal.shown(until: "% "), "% "), "rc on a cons prompts")
    terminal.type("echo hi\n")
    check(shows(terminal.shown(until: "hi\n% "), "hi\n% "), "rc on a cons runs a typed line")
    // A program given rc's stdin has the terminal while it runs; ^D ends
    // its input (it writes what it read at its end), not rc's.
    terminal.type("cat\n")
    sleep(until: Clock.monotonic() + 500_000_000)  // cat started
    terminal.type("typed\n")
    terminal.type("")
    check(shows(terminal.shown(until: "typed\n% "), "typed\n% "), "rc lends the terminal to the program it runs, until ^D")
    // An interrupt kills the program that has the terminal.
    terminal.type("cat\n")
    interrupt()
    check(shows(terminal.shown(until: "% "), "% "), "an interrupt kills the program, and rc prompts")
    // With no sigint function the rest of the line is abandoned.
    terminal.type("cat; echo a^b\n")
    interrupt()
    check(!shows(terminal.shown(until: "% "), "ab\n"), "an interrupt abandons the rest of rc's line")
    // With one, it runs, and the line goes on; sigexit runs as rc exits.
    terminal.type("fn sigint { echo caught }; fn sigexit { echo bye }\n")
    _ = terminal.shown(until: "% ")
    terminal.type("cat; echo a^c\n")
    interrupt()
    check(shows(terminal.shown(until: "ac\n% "), "caught\nac\n% "), "rc runs its sigint for an interrupt")
    terminal.type("exit ''\n")  // $status is the killed cat's
    check(shows(terminal.shown(until: "bye\n"), "bye\n"), "rc runs its sigexit")
    _ = try process.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
    check(try Process.info(process).returnCode == 0, "rc on a cons exits")
    _ = consume thread
  } catch {
    print("launch-test: rc on a cons: \(error)")
    check(false, "rc on a cons")
  }
}

/// rc's `cat /svc/*/status` (V2's exit test), and a pipeline of programs
/// (each a child of rc's, rc relaying between them), checked against the
/// statuses read here.
func runRc(_ start: Startup, _ ns: Namespace, _ names: [String]) {
  guard let job = start.take(HandleType.info(HandleType.jobDefault)) else { return check(false, "a job to start rc in") }
  // /bin is the bootfs service's (D71): what's there, and rc from it.
  let listed = (try? ns.list("/bin", fields: 0))?.map { $0.name } ?? []
  check(listed.contains { same($0, "launch-test") } && listed.contains { same($0, "launcher") }, "/bin lists bootfs's programs")
  guard let memory = try? ns.memory("/bin/rc", executable: true) else {
    print("launch-test: no /bin/rc (tier 1 isn't built here): rc's checks skipped")
    return
  }
  let rc = ProgramEntry(image: memory.vmo.raw, offset: 0, length: Int(memory.size), name: "rc")
  // The glob's order: the names' bytes.
  let sorted = names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  var all: [UInt8] = []
  for name in sorted { all += Array((readText(ns, "/svc/" + name + "/status") ?? "").utf8) }
  rcRuns(rc, "cat /svc/*/status", all, ns, job: job, "rc runs cat /svc/*/status")
  let ab = Array(((readText(ns, "/svc/a/status") ?? "") + (readText(ns, "/svc/b/status") ?? "")).utf8)
  rcRuns(rc, "cat /svc/a/status /svc/b/status | cat | cat", ab, ns, job: job,
         "rc pipes program to program")
  rcRuns(rc, "x=b; cat <<EOF\na $x c\nEOF", Array("a b c\n".utf8), ns, job: job,
         "rc gives a program a here document")
  rcRuns(rc, "{ cat /svc/a/status } & wait", Array((readText(ns, "/svc/a/status") ?? "").utf8), ns, job: job,
         "rc runs a compound command in the background")
  // Programs by $path: /bin/NAME is its namespace's (the bootfs
  // service's bin/NAME, D71), which ls lists and rfork N takes away; an
  // rc started by rc can start programs too, and its exit code is its
  // status.
  let a = Array((readText(ns, "/svc/a/status") ?? "").utf8)
  rcRuns(rc, "/bin/cat /svc/a/status", a, ns, job: job, "rc runs a program by its path")
  // $apid: a background job's koid (a program's process, a compound's
  // thread), which `wait` takes, the job's status then rc's.
  rcRuns(rc, "{ ~ a b } & x=$apid; ~ $x [0-9]* && ! ~ $x $pid && echo number; wait $x; ~ $status '' || echo failed; cat /svc/a/status & wait $apid",
         Array("number\nfailed\n".utf8) + a, ns, job: job, "rc's $apid is a job's koid, which wait takes")
  rcRuns(rc, "path=() whatis cat || echo none", Array("none\n".utf8), ns, job: job,
         "rc finds nothing on an empty $path")
  rcRuns(rc, "for (p in `{ls /bin}) if (~ $p /bin/rc) echo listed; rfork N; whatis cat || echo gone", Array("listed\ngone\n".utf8),
         ns, job: job, "rc's programs are its namespace's /bin")
  // A program's status is Plan 9's wait message (D72): its name, its koid,
  // and the exit string it ended with.
  rcRuns(rc, "rc -c 'cat /svc/a/status'; rc -c 'exit 3'; ~ $status 'rc '[0-9]*': 3' && echo said", a + Array("said\n".utf8),
         ns, job: job, "rc runs rc, which runs programs and exits with its status")
  rcRuns(rc, "rc -e -c 'echo a; ~ a b; echo never'; ~ $status 'rc '[0-9]*': no match' && echo stopped",
         Array("a\nstopped\n".utf8), ns, job: job, "rc -e stops at a command that fails")
  rcRuns(rc, "x=`{ls /nope >[2=1]}; ~ $status 'ls '[0-9]*': errors' && echo $x; x=`{cat /svc/a/status /nope >[2=1]}; ~ $status 'cat '[0-9]*': can''t open /nope: file does not exist: ''/nope''' && echo fatal; x=`{ls -z >[2=1]}; ~ $status 'ls '[0-9]*': usage' && echo usage",
         Array("ls: /nope: file does not exist: '/nope'\nfatal\nusage\n".utf8), ns, job: job,
         "the commands say what 9front's do, and end with their exit strings")
  rcRuns(rc, "x=(a 'b c'); fn f { echo f $* }; rc -c 'echo $#x; f z'", Array("2\nf z\n".utf8), ns, job: job,
         "rc passes rc its lists and functions")
  // Split at : alone, the status keeps its newline.
  rcRuns(rc, "x=(a b); n=x; echo $$n; echo `:{cat /svc/a/status}", Array("a b\na first\n\n".utf8), ns, job: job,
         "rc takes $$x and `split{}")
  // Descriptors of their own (D46): a program's stderr apart from its
  // stdout, fds above 2, and <{} as /dev/fd/N.
  rcRuns(rc, "x=`{cat /nope}; echo $#x; y=`{cat /nope >[2=1]}; ~ $#y 0 || echo caught", Array("0\ncaught\n".utf8),
         ns, job: job, "rc gives a program a stderr of its own")
  rcRuns(rc, "cat /dev/fd/3 <[3]/svc/a/status", a, ns, job: job, "rc gives a program fd 3")
  // The manual, from bootfs (D86): a page found by name, one by its key,
  // and a page printed whole.
  rcRuns(rc, "man -w lookman; lookman launcher service; x=`{man 6 manifest}; ~ $x(1) 'MANIFEST(6)' && echo page",
         Array("/lib/man/1/man\nman 6 manifest # the launcher's service manifests\npage\n".utf8), ns, job: job,
         "rc runs man, lookman and a page")
  rcRuns(rc, "cat <{cat /svc/a/status} <{echo two}", a + Array("two\n".utf8), ns, job: job,
         "rc runs <{} on the device")
  // Where 9front forks, a copy of rc on a system of its own: a cd there is
  // its own (a pipeline's earlier stage, a subshell, a backquote, `&`),
  // and its programs start there; the last stage runs in rc.
  rcRuns(rc, "cd /svc; cat a/status; cd /; {cd /svc} | cat; @{cd /svc}; x=`{cd /svc}; {cd /svc; cat a/status} & wait; pwd; echo | cd /svc; pwd",
         a + a + Array("/\n/svc\n".utf8), ns, job: job, "rc's forks have directories of their own")
  // rfork: n a copy of rc's namespace, N an empty one (/bin gone with it,
  // so nothing runs), E what was given hidden, F every descriptor gone.
  rcRuns(rc, "rfork n; cat /svc/a/status; rfork N; cat /svc/a/status || echo gone", a + Array("gone\n".utf8), ns,
         job: job, "rc's rfork n and N")
  rcRuns(rc, "x=1; rc -c 'echo $x'; rfork E; rc -c 'echo $#x'; x=2; rc -c 'echo $x'; echo a; {rfork F; echo b}; echo c; exit ''",
         Array("1\n0\n2\na\n".utf8), ns, job: job, "rc's rfork E and F")
  // rfork e: a copy of the group, what's in it kept; a child's changes
  // reach rc's group, which it shares (D81).
  rcRuns(rc, "x=1; rfork e; rc -c 'echo $x; y=2; rc -c true'; cat /env/y", Array("1\n2\0".utf8), ns, job: job,
         "rc's rfork e, and the group its programs share")
  // A note posted to rc through /proc runs its sigint function (D87), at
  // its next look between commands.
  rcRuns(rc, "fn sigint {caught=yes}; echo interrupt >/proc/$pid/note; while(! ~ $caught yes) x=`{ls /proc}; echo caught",
         Array("caught\n".utf8), ns, job: job, "rc takes a note through /proc")
  // ps and kill over /proc (D79): kill names this process's note.
  if let me = try? Process.current(), let koid = try? me.info().koid {
    rcRuns(rc, "x=`{ps -a}; ~ $#x 0 && echo none; kill launch-test", Array("@{echo kill>/proc/\(koid)/note} # launch-test\n".utf8), ns,
           job: job, "rc runs ps and kill over /proc")
  }
  // A write a file refuses, as the launcher's ctl refuses a service it
  // doesn't know: echo says so, as 9front's does, and fails.
  rcRuns(rc, "echo restart nobody >[2=1] >/svc/launcher/ctl; ~ $status 'write error' && echo failed",
         Array("echo: write error: file does not exist\nfailed\n".utf8), ns, job: job,
         "rc's echo says when its write fails")
  // Files on fs(4)'s volume (D8): made, copied, moved, listed and removed.
  rcRuns(rc, "echo hello >/data/x; cp /data/x /data/y; mv /data/y /data/z; mkdir /data/d; cp /data/z /data/d; ls /data /data/d; cat /data/d/z; rm /data/x /data/z /data/d/z; rm /data/d; ls /data",
         Array("/data/d\n/data/x\n/data/z\n/data/d/z\nhello\n".utf8), ns, job: job, data: true,
         "rc makes, copies, moves and removes files on /data")
  rcOnCons(rc, ns, job: job)
  _ = consume memory  // rc is started from it until here
}

func contains(_ bytes: [UInt8], _ part: [UInt8]) -> Bool {
  guard part.count <= bytes.count else { return part.isEmpty }
  for i in 0...(bytes.count - part.count) where Array(bytes[i..<(i + part.count)]) == part { return true }
  return false
}

@main struct LaunchTest {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(start)
    } catch {
      print("launch-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(ns.mountPoints.count == 10 && same(ns.mountPoints[0], "/bin") && same(ns.mountPoints[1], "/data")
            && same(ns.mountPoints[2], "/dev") && same(ns.mountPoints[3], "/env") && same(ns.mountPoints[4], "/lib/man")
            && same(ns.mountPoints[5], "/mnt/console") && same(ns.mountPoints[6], "/mnt/plumb")
            && same(ns.mountPoints[7], "/net") && same(ns.mountPoints[8], "/proc") && same(ns.mountPoints[9], "/svc"),
          "the namespace is /bin, /data, /dev, /env, /lib/man, /mnt/console, /mnt/plumb, /net, /proc and /svc")
    environment(ns)

    // devmgr first: its status is still growing until it has bound.
    devices(ns)
    console(ns)
    plumbing(ns)
    gate(ns)
    documentedTrees(ns)

    // cat /svc/*/status
    let names = ((try? ns.list("/svc")) ?? []).map { $0.name }
    #if arch(x86_64)
      let expected = 12  // and the time service
    #else
      let expected = 11
    #endif
    check(names.count == expected && names.contains { same($0, "a") } && names.contains { same($0, "b") }
            && names.contains { same($0, "launcher") }
            && names.contains { same($0, "devmgr") } && names.contains { same($0, "env") }
            && names.contains { same($0, "net") } && names.contains { same($0, "cs") }
            && names.contains { same($0, "dns") } && names.contains { same($0, "9gate") }
            && names.contains { same($0, "fs") } && names.contains { same($0, "ramdisk") },
          "/svc holds what the manifest uses")
    // env is the launcher's groups (D81), with no status.
    for name in names where !same(name, "env") {
      let status = readText(ns, "/svc/" + name + "/status")
      check(status != nil, "each /svc/*/status reads")
      if let status { print("launch-test: /svc/\(name)/status: \(status)") }
    }
    check(readText(ns, "/svc/a/status").map { same($0, "a first\n") } ?? false, "a's status")
    check(readText(ns, "/svc/b/peer").map { same($0, "a first\n") } ?? false, "b reaches a through its own /svc")
    let status = readText(ns, "/svc/launcher/status") ?? ""
    check(hasLine(status, "a running restarts 0") && hasLine(status, "b running restarts 0")
            && hasLine(status, "launch-test running restarts 0"), "the launcher's status")

    // UTC (D48): the page every process maps, at least the launcher's
    // backstop; on amd64, the RTC's reading, which the time service set.
    let backstop: Int64 = 1_767_225_600 * 1_000_000_000
    let utc = Clock.realtime()
    check(utc >= backstop, "UTC reads the page, at least its backstop")
    #if arch(x86_64)
      let time = readText(ns, "/svc/time/status") ?? ""
      check(time.utf8.starts(with: "set from rtc ".utf8), "the time service set UTC from the RTC")
      if let set = lastNumber(time) {
        check(utc >= set && utc - set < 60_000_000_000, "UTC follows the RTC's reading")
      } else {
        check(false, "UTC follows the RTC's reading")
      }
    #endif

    // rc runs `cat /svc/*/status` (V2's exit test): rc from /bin, given
    // this process's /svc and /bin, a job, and stdio;
    // what it writes is every status, in the glob's order. Tier 1: not on
    // rv64 yet.
    runRc(start, ns, names)

    // A crash, as the launcher's ctl makes one: a restarts (`restart always`).
    if var ctl = try? ns.open("/svc/launcher/ctl") {
      check((try? ctl.writeText("kill a")) != nil, "ctl kills a")
    } else {
      check(false, "ctl kills a")
    }
    var restarted = false
    let deadline = Clock.monotonic() + 5_000_000_000
    while !restarted && Clock.monotonic() < deadline {
      restarted = hasLine(readText(ns, "/svc/launcher/status") ?? "", "a running restarts 1")
      if !restarted { sleep(until: Clock.monotonic() + 10_000_000) }
    }
    check(restarted, "a restarted")
    check(readText(ns, "/svc/a/status").map { same($0, "a first\n") } ?? false, "the new a, by the same path")
    check(readText(ns, "/svc/b/peer").map { same($0, "a first\n") } ?? false, "and through b")

    files(ns)
    procs(ns)
    servicesMemory(ns)
    print("launch-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}

/// The services' resident memory (V2's exit: < 32 MiB), from the
/// fs(4)'s volume at /data (D8), on ramdisk(4)'s disk: a file written and
/// read back, committed within the volume's delay, and there again
/// through /svc/fs/volume once fs has restarted, the disk kept.
func files(_ ns: Namespace) {
  let ctl = readText(ns, "/svc/ramdisk/sdZ0/ctl") ?? ""
  check(hasLine(ctl, "inquiry ramdisk0") && hasLine(ctl, "geometry 16384 4096") && hasLine(ctl, "part data 0 16384"),
        "the RAM disk says its geometry, as sd(3)'s ctl")
  check(hasLine(readText(ns, "/svc/fs/status") ?? "", "volume data"), "fs serves the volume it made, labelled data")
  // Push and run is the cpu images' alone (etc/launcher/push): here the
  // launcher made no bin on the volume, and runs nothing from it.
  check((try? ns.open("/svc/fs/volume/bin")) == nil, "a normal image has no /dev/bin to push to")
  /// The groups fs has committed, from its status's `commits` line.
  func commits() -> Int64 {
    let status = readText(ns, "/svc/fs/status") ?? ""
    for line in status.utf8.split(separator: 0x0A) where line.starts(with: "commits ".utf8) {
      return lastNumber(String(decoding: line, as: UTF8.self)) ?? -1
    }
    return -1
  }
  let before = commits()
  var made = false
  if var f = try? ns.create("/data/kept", kind: .file), (try? f.writeText("kept\n")) != nil { made = true }
  check(made && (readText(ns, "/data/kept").map { same($0, "kept\n") } ?? false), "a file on /data reads back")
  let deadline = Clock.monotonic() + 5_000_000_000
  while commits() <= before && Clock.monotonic() < deadline { sleep(until: Clock.monotonic() + 50_000_000) }
  check(before >= 0 && commits() > before, "the volume commits within its delay")
  if var ctl = try? ns.open("/svc/launcher/ctl") {
    check((try? ctl.writeText("kill fs")) != nil, "ctl kills fs")
  } else {
    check(false, "ctl kills fs")
  }
  var restarted = false
  let again = Clock.monotonic() + 5_000_000_000
  while !restarted && Clock.monotonic() < again {
    restarted = hasLine(readText(ns, "/svc/launcher/status") ?? "", "fs running restarts 1")
    if !restarted { sleep(until: Clock.monotonic() + 10_000_000) }
  }
  check(restarted, "fs restarted")
  check(readText(ns, "/svc/fs/volume/kept").map { same($0, "kept\n") } ?? false,
        "the new fs finds the file on the disk the RAM disk kept")
  check(readText(ns, "/data/kept").map { same($0, "kept\n") } ?? false,
        "/data reconnects to the new fs (PA_NS_RECONNECT)")
}

/// launcher's `memory`: each service's private and scaled-shared bytes,
/// with what it started, summed over every service but this one (a test,
/// not a service) and the launcher's own, after the checks above have
/// used them. The bench judges the budget (vx bench's services boot);
/// here, only that the launcher says it for each.
func servicesMemory(_ ns: Namespace) {
  guard let text = readText(ns, "/svc/launcher/memory") else { return check(false, "the launcher's memory reads") }
  var total: UInt64 = 0, lines = 0
  for line in text.utf8.split(separator: 0x0A) {
    let words = line.split(separator: 0x20).map { Array($0) }
    guard words.count == 9, let privateBytes = decimal(words[4]), let scaled = decimal(words[8]) else {
      return check(false, "the launcher's memory lines")
    }
    lines += 1
    print("launch-test: memory \(String(decoding: line, as: UTF8.self))")
    if words[0] != Array("launch-test".utf8) { total += privateBytes + scaled }
  }
  check(lines >= 5 && total > 0, "the launcher says each service's memory")
  print("launch-test: budget name=services.rss value=\(total) unit=bytes limit=33554432")
}

/// `bytes` as a decimal number, if they are one.
func decimal(_ bytes: [UInt8]) -> UInt64? {
  guard !bytes.isEmpty else { return nil }
  var n: UInt64 = 0
  for b in bytes {
    guard b >= 0x30 && b <= 0x39 else { return nil }
    n = n * 10 + UInt64(b - 0x30)
  }
  return n
}

/// /proc (D79): a directory for each process under the launcher's job,
/// with Plan 9's status line; a note posted through it kills a process
/// that doesn't take notes (D87), which the launcher then restarts.
func procs(_ ns: Namespace) {
  let names = ((try? ns.list("/proc")) ?? []).map { $0.name }
  check(names.count >= 8, "/proc lists the services' processes")
  /// The koid of the process whose status starts with `service` and a blank.
  func koid(_ service: String) -> String? {
    let prefix = Array(service.utf8) + [0x20]
    for n in ((try? ns.list("/proc")) ?? []).map({ $0.name }) {
      guard let status = readText(ns, "/proc/" + n + "/status") else { continue }
      if Array(status.utf8.prefix(prefix.count)) == prefix && hasWord(status, "Running") { return n }
    }
    return nil
  }
  guard let a = koid("a") else { return check(false, "/proc has a's status") }
  let status = readText(ns, "/proc/" + a + "/status") ?? ""
  print("launch-test: /proc/\(a)/status: \(status)")
  check(status.utf8.count == 27 + 1 + 27 + 1 + 11 + 9 * 12 + 1, "its status is Plan 9's line")
  check(readText(ns, "/proc/" + a + "/args").map { same($0, "a") } ?? false, "its args")
  if var note = try? ns.open("/proc/" + a + "/note") {
    check((try? note.writeText("interrupt\n")) != nil, "a note posted through /proc")
  } else {
    check(false, "a note posted through /proc")
  }
  var restarted = false
  let deadline = Clock.monotonic() + 5_000_000_000
  while !restarted && Clock.monotonic() < deadline {
    restarted = hasLine(readText(ns, "/svc/launcher/status") ?? "", "a running restarts 2")
    if !restarted { sleep(until: Clock.monotonic() + 10_000_000) }
  }
  check(restarted, "kills it, and a restarts")
  check(readText(ns, "/proc/" + a + "/status") == nil, "its directory goes with it")
}

/// Whether `text` holds `word` between blanks.
func hasWord(_ text: String, _ word: String) -> Bool {
  let w = Array(word.utf8)
  return text.utf8.split(separator: 0x20).contains { Array($0) == w }
}
