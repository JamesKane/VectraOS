// SPDX-License-Identifier: BSD-3-Clause

// vx qemu-monitor SOCKET COMMAND... (croi's tools/qemu-monitor.py, in
// Swift): sends one command to a QEMU human monitor on a Unix socket,
// waits for its prompt to come back, and prints the reply (`info
// registers -a`, `screendump FILE`).
//
// `backtrace [START END LINK]` is croi's own: for every CPU, its PC and
// the return addresses along the frame-pointer chain (amd64: rbp; arm64:
// x29), read through the monitor's `x` with that CPU's page tables.
// Symbolize them with llvm-symbolizer --obj=build/<arch>/kernel/kernel.elf.
// With KASLR the kernel runs away from its link address: START END LINK
// (the kernel's `kaslr: image <start>-<end>, link <link>` line; qemu.sh
// passes it) prints addresses in the image as link addresses.

import HostSystem

private struct Monitor {
  let fd: Int32

  init(path: String) {
    fd = socket(AF_UNIX, streamSocket, 0)
    guard fd >= 0 else { fail("qemu-monitor: socket: \(errno)") }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("qemu-monitor: socket path too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (i, b) in bytes.enumerated() { buffer[i] = b }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { fail("qemu-monitor: can't connect to \(path)") }
    _ = untilPrompt()
  }

  /// Everything up to and including the next "(qemu) " prompt.
  func untilPrompt() -> [UInt8] {
    var data: [UInt8] = []
    let prompt = Array("(qemu) ".utf8)
    var chunk = [UInt8](repeating: 0, count: 4096)
    while !data.ends(with: prompt) {
      let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
      if n <= 0 { break }
      data += chunk[..<n]
    }
    return data
  }

  /// A command's reply, without the echoed command line and the prompt.
  func command(_ text: String) -> String {
    let line = Array((text + "\n").utf8)
    _ = line.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    let reply = String(decoding: untilPrompt().filter { $0 != 0x0D }, as: UTF8.self)
    var lines = reply.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
    if lines.last?.hasPrefix("(qemu)") == true { lines = lines.dropLast() }
    return lines.joined(separator: "\n")
  }
}

extension Array where Element: Equatable {
  func ends(with suffix: [Element]) -> Bool { count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix }
}

/// The hex value after `key=` (as in `RIP=ffffffff8000a000`), anywhere in `text`.
private func register(_ key: String, in text: String) -> UInt64? {
  var search = text[...]
  while let r = search.firstRange(of: key + "=") {
    // A whole word: "RIP=" but not "XRIP=".
    let wordStart = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
    let digits = search[r.upperBound...].prefix { $0.isHexDigit }
    if wordStart, let v = UInt64(digits, radix: 16) { return v }
    search = search[r.upperBound...]
  }
  return nil
}

private func backtrace(_ monitor: Monitor, image: (start: UInt64, end: UInt64, link: UInt64)?) {
  func atLink(_ address: UInt64) -> UInt64 {
    // arm64 return addresses are signed (K14p): the PAC bits off first
    // (bit 55 says which half), a no-op for canonical addresses.
    let a = (address >> 55) & 1 == 1 ? address | 0xFFFF_0000_0000_0000 : address & 0x0000_FFFF_FFFF_FFFF
    if let image, image.start <= a, a < image.end { return a - image.start + image.link }
    return a
  }
  func hex(_ v: UInt64) -> String { String(v, radix: 16) }

  let cpus = monitor.command("info cpus")
  var indices: [Int] = []
  var rest = cpus[...]
  while let r = rest.firstRange(of: "CPU #") {
    if let n = Int(rest[r.upperBound...].prefix { $0.isNumber }) { indices.append(n) }
    rest = rest[r.upperBound...]
  }
  for index in indices {
    _ = monitor.command("cpu \(index)")
    let registers = monitor.command("info registers")
    let pc = register("RIP", in: registers) ?? register("PC", in: registers)
    let fp = register("RBP", in: registers) ?? register("X29", in: registers)
    var line = pc.map { "cpu \(index): pc \(hex(atLink($0)))" } ?? "cpu \(index): pc ?"
    if let flags = register("RFL", in: registers) { line += " (interrupts \(flags & 0x200 != 0 ? "on" : "masked"))" }
    var frames: [String] = []
    var address = fp ?? 0
    for _ in 0..<24 {
      if address == 0 || address % 8 != 0 { break }
      // "ffff...: 0x<previous> 0x<return>"
      let reply = monitor.command("x/2gx 0x\(hex(address))")
      guard let colon = reply.firstIndex(of: ":") else { break }
      let words = reply[reply.index(after: colon)...].split(whereSeparator: \.isWhitespace)
        .prefix(2).compactMap { $0.hasPrefix("0x") ? UInt64($0.dropFirst(2), radix: 16) : nil }
      guard words.count == 2 else { break }
      let (previous, ret) = (words[0], words[1])
      if ret == 0 { break }
      frames.append(hex(atLink(ret)))
      if previous <= address { break }
      address = previous
    }
    say(line + (frames.isEmpty ? "" : " <- " + frames.joined(separator: " <- ")))
  }
}

func qemuMonitorCommand(_ args: [String]) -> Bool {
  guard args.count >= 2 else { fail("usage: vx qemu-monitor SOCKET COMMAND...") }
  let monitor = Monitor(path: args[0])
  defer { close(monitor.fd) }
  if args[1] == "backtrace" {
    var image: (UInt64, UInt64, UInt64)?
    if args.count >= 5 {
      let v = args[2...4].compactMap { UInt64($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) }
      if v.count == 3 { image = (v[0], v[1], v[2]) }
    }
    if image != nil { say("(kernel addresses below are link addresses)") }
    backtrace(monitor, image: image)
  } else {
    let reply = monitor.command(args.dropFirst().joined(separator: " "))
    if !reply.isEmpty { say(reply) }
  }
  usleep(200_000)  // let QEMU finish writing any output file
  return true
}
