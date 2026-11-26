// SPDX-License-Identifier: BSD-3-Clause

// bin/audio-test: the audio class through bin/virtio-snd, run by the
// launcher (launcher.until=audio-test) in boot-audio, where QEMU's
// virtio-sound-pci has an output and an input stream. It waits for the
// driver to bring the device up and devmgr to bind it at /dev/audio/0,
// checks its files, plays half a second of a 440 Hz tone and waits for
// the stream to drain, captures a quarter of a second, and plays again
// at another rate. It prints the driver's status and the device's stat,
// and exits 0 if every check passed.

import Node
import Sys

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
  print("audio-test: \(condition ? "ok" : "FAILED"): \(name)")
  if !condition { failures += 1 }
}

func lines(_ text: String) -> [String] { text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) } }

/// Strings compared as bytes: String's == needs Unicode's tables, which
/// the floor doesn't link.
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

func same(_ a: [String], _ b: [String]) -> Bool {
  a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
}

func holds(_ text: String, _ part: String) -> Bool {
  let t = Array(text.utf8), p = Array(part.utf8)
  guard p.count <= t.count else { return false }
  for i in 0...(t.count - p.count) where Array(t[i..<(i + p.count)]) == p { return true }
  return false
}

/// The number after `word ` in the line that starts with `prefix`.
func number(_ text: String, line prefix: String, after word: String) -> UInt64? {
  for l in lines(text) where l.utf8.starts(with: prefix.utf8) {
    let words = l.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    for (i, w) in words.enumerated() where w.utf8.elementsEqual(word.utf8) && i + 1 < words.count {
      var n: UInt64 = 0
      for c in words[i + 1].utf8 {
        guard c >= 0x30, c <= 0x39 else { return nil }
        n = n * 10 + UInt64(c - 0x30)
      }
      return n
    }
  }
  return nil
}

/// A 440 Hz tone of 16-bit stereo frames at `rate`, from a table of a
/// quarter wave (no floating point in the floor's programs is needed).
func tone(frames: Int, rate: Int) -> [UInt8] {
  // sin(i * 2pi / 64) * 8000 for i in 0...16.
  let quarter: [Int] = [0, 784, 1561, 2322, 3061, 3769, 4440, 5067, 5657, 6185, 6652, 7055, 7391, 7657, 7853,
                        7963, 8000]
  func wave(_ i: Int) -> Int {
    let k = i % 64
    if k <= 16 { return quarter[k] }
    if k <= 32 { return quarter[32 - k] }
    if k <= 48 { return -quarter[k - 32] }
    return -quarter[64 - k]
  }
  var out = [UInt8](repeating: 0, count: frames * 4)
  for f in 0..<frames {
    // 64 steps a cycle at 440 Hz.
    let s = Int16(wave(f * 440 * 64 / rate))
    let b = UInt16(bitPattern: s)
    out[4 * f] = UInt8(truncatingIfNeeded: b)
    out[4 * f + 1] = UInt8(truncatingIfNeeded: b >> 8)
    out[4 * f + 2] = out[4 * f]
    out[4 * f + 3] = out[4 * f + 1]
  }
  return out
}

/// Writes `bytes` to the device's data in 8 KiB pieces: whether every
/// byte was taken.
func play(_ ns: Namespace, _ bytes: [UInt8]) -> Bool {
  guard var f = try? ns.open("/dev/audio/0/data") else { return false }
  var done = 0
  while done < bytes.count {
    let n = min(8192, bytes.count - done)
    guard let wrote = try? f.write(offset: 0, Array(bytes[done..<(done + n)])), wrote > 0 else { return false }
    done += Int(wrote)
  }
  return true
}

/// stat once its `prefix` line says `stopped`, or after `seconds`.
func stopped(_ ns: Namespace, _ prefix: String, within seconds: Int64) -> String {
  let deadline = Clock.monotonic() + seconds * 1_000_000_000
  var stat = ""
  while Clock.monotonic() < deadline {
    stat = ns.readText("/dev/audio/0/stat") ?? ""
    if lines(stat).contains(where: { $0.utf8.starts(with: (prefix + " stopped").utf8) }) { break }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  return stat
}

@main struct AudioTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(Startup.current)
    } catch {
      print("audio-test: FAILED: no namespace")
      Process.exit(code: 1)
    }

    // The driver, once it has brought the device up or failed.
    let deadline = Clock.monotonic() + 30_000_000_000
    var status = ""
    var driver = "virtio-snd"
    while Clock.monotonic() < deadline {
      let drivers = ((try? ns.list("/svc/devmgr/drivers")) ?? []).map { $0.name }
        .filter { $0.utf8.starts(with: "virtio-snd".utf8) }
      if let d = drivers.first {
        driver = d
        status = ns.readText("/svc/devmgr/drivers/\(d)/status") ?? ""
        if holds(status, "streams ") || holds(status, "FAILED") { break }
      }
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    for l in lines(status) { print("audio-test: status: \(l)") }
    check(holds(status, "stream 0 out") && holds(status, "stream 1 in"), "virtio-snd finds an output and an input stream")
    check(!holds(status, "FAILED") && !holds(status, "control failed"), "virtio-snd brings the device up")

    var names: [String] = []
    while Clock.monotonic() < deadline {
      names = ((try? ns.list("/dev/audio")) ?? []).map { $0.name }
      if !names.isEmpty { break }
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    check(same(names, ["0"]), "devmgr binds the device at /dev/audio/0")
    let files = ((try? ns.list("/dev/audio/0")) ?? []).map { $0.name }
    check(same(files, ["ctl", "stat", "volume", "data"]), "/dev/audio/0 holds ctl, stat, volume and data")
    let ctl = ns.readText("/dev/audio/0/ctl") ?? ""
    check(same(ctl, "speed 44100\nformat s16 2\nperiod 1024\n"), "the device starts in 9front's format")
    let stat = ns.readText("/dev/audio/0/stat") ?? ""
    for l in lines(stat) { print("audio-test: stat: \(l)") }
    check(holds(stat, "device virtio-snd\n") && holds(stat, "\nout formats ") && holds(stat, "\nin formats "),
          "stat names the device and what each stream takes")
    check(lines(stat).first?.utf8.starts(with: "bufsize  32768 buffered      0 offset ".utf8) == true,
          "stat's first line is 9front's audiostat")

    // Half a second of the tone, played and drained.
    let frames = 22050
    let started = Clock.monotonic()
    check(play(ns, tone(frames: frames, rate: 44100)), "half a second written to /dev/audio/0/data is taken")
    let played = stopped(ns, "out", within: 10)
    let elapsed = Clock.monotonic() - started
    for l in lines(played) where l.utf8.starts(with: "out ".utf8) || l.utf8.starts(with: "bufsize".utf8) {
      print("audio-test: after playing: \(l)")
    }
    print("audio-test: played \(frames) frames in \(elapsed / 1_000_000) ms")
    check(holds(played, "\nout stopped runs 1 "), "the stream stops once drained")
    let periods = number(played, line: "out ", after: "periods") ?? 0
    check(periods >= UInt64((frames + 1023) / 1024), "the device played every period written (\(periods))")
    let offset = number(played, line: "bufsize", after: "offset") ?? 0
    check(offset >= UInt64(frames * 4), "stat's offset counts the bytes played (\(offset))")
    // The device takes frames at its rate: half a second can't drain in
    // much less (a loaded host only makes it longer).
    check(elapsed >= 400_000_000, "the device takes the frames at its rate, not at once")

    // A quarter of a second captured.
    var captured = 0
    if var f = try? ns.open("/dev/audio/0/data") {
      while captured < 44100, let part = try? f.read(offset: 0, max: 8192), !part.isEmpty { captured += part.count }
    }
    check(captured >= 44100, "a quarter of a second is read from /dev/audio/0/data (\(captured) bytes)")
    check(ns.writeText("/dev/audio/0/ctl", "stop in\n"), "ctl stops capture")
    let recorded = ns.readText("/dev/audio/0/stat") ?? ""
    for l in lines(recorded) where l.utf8.starts(with: "in ".utf8) { print("audio-test: after capture: \(l)") }
    check(holds(recorded, "\nin stopped runs 1 "), "capture stopped")

    // Another rate: the stream set up again.
    check(ns.writeText("/dev/audio/0/ctl", "speed 48000\n"), "ctl takes speed 48000")
    check(same(ns.readText("/dev/audio/0/ctl") ?? "", "speed 48000\nformat s16 2\nperiod 1024\n"), "ctl reads back the new rate")
    check(!ns.writeText("/dev/audio/0/ctl", "speed 12345\n"), "ctl refuses a rate the device lacks")
    check(play(ns, tone(frames: 4800, rate: 48000)), "a tenth of a second at 48 kHz is taken")
    let again = stopped(ns, "out", within: 10)
    check(holds(again, "\nout stopped runs 2 "), "the stream runs again at the new rate and drains")

    let end = ns.readText("/svc/devmgr/drivers/\(driver)/status") ?? ""
    for l in lines(end) where l.utf8.starts(with: "periods".utf8) || l.utf8.starts(with: "events".utf8) {
      print("audio-test: status: \(l)")
    }
    print("audio-test: \(failures == 0 ? "passed" : "\(failures) failed")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
