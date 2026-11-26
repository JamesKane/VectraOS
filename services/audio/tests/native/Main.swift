// SPDX-License-Identifier: BSD-3-Clause

// bin/audio-service-test: push streams through bin/audio, run by the
// launcher (launcher.until=audio-service-test) in boot-audio-service,
// where QEMU's virtio-sound-pci is /dev/audio/0. It checks the service
// idles with no device lent; plays two tones through two streams at once,
// half a second each, and checks that the service leased the device
// (/dev/audio/0's data refused meanwhile), mixed every frame of both,
// took the device's time to do it, and gave the lease back after a
// second of silence; then plays again, a second lease. It prints the
// service's status, and exits 0 if every check passed.

import Node
import Sys

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
  print("audio-service-test: \(condition ? "ok" : "FAILED"): \(name)")
  if !condition { failures += 1 }
}

func lines(_ text: String) -> [String] { text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) } }

func holds(_ text: String, _ part: String) -> Bool {
  let t = Array(text.utf8), p = Array(part.utf8)
  guard p.count <= t.count else { return false }
  for i in 0...(t.count - p.count) where Array(t[i..<(i + p.count)]) == p { return true }
  return false
}

/// The numbers after `word ` on every line that starts with `prefix`.
func numbers(_ text: String, line prefix: String, after word: String) -> [UInt64] {
  var out: [UInt64] = []
  for l in lines(text) where l.utf8.starts(with: prefix.utf8) {
    let words = l.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    for (i, w) in words.enumerated() where w.utf8.elementsEqual(word.utf8) && i + 1 < words.count {
      var n: UInt64 = 0
      var ok = true
      for c in words[i + 1].utf8 {
        guard c >= 0x30, c <= 0x39 else {
          ok = false
          break
        }
        n = n * 10 + UInt64(c - 0x30)
      }
      if ok { out.append(n) }
    }
  }
  return out
}

/// A tone of `frames` 16-bit stereo frames, `steps` samples a cycle, from
/// a table of a quarter wave.
func tone(frames: Int, steps: Int, level: Int) -> [UInt8] {
  let quarter: [Int] = [0, 98, 195, 290, 383, 471, 556, 634, 707, 773, 831, 882, 924, 957, 981, 995, 1000]
  func wave(_ i: Int) -> Int {
    let k = i % 64
    if k <= 16 { return quarter[k] }
    if k <= 32 { return quarter[32 - k] }
    if k <= 48 { return -quarter[k - 32] }
    return -quarter[64 - k]
  }
  var out = [UInt8](repeating: 0, count: frames * 4)
  for f in 0..<frames {
    let b = UInt16(bitPattern: Int16(wave(f * 64 / steps) * level / 1000))
    out[4 * f] = UInt8(truncatingIfNeeded: b)
    out[4 * f + 1] = UInt8(truncatingIfNeeded: b >> 8)
    out[4 * f + 2] = out[4 * f]
    out[4 * f + 3] = out[4 * f + 1]
  }
  return out
}

func status(_ ns: Namespace) -> String { ns.readText("/svc/audio/status") ?? "" }

/// The status once it says `state idle` after its `leases`th lease, or
/// after `seconds`.
func idle(_ ns: Namespace, leases: Int, within seconds: Int64) -> String {
  let deadline = Clock.monotonic() + seconds * 1_000_000_000
  var s = status(ns)
  while Clock.monotonic() < deadline {
    s = status(ns)
    if holds(s, "\nstate idle\n"), holds(s, "\nleases \(leases) ") { break }
    sleep(until: Clock.monotonic() + 20_000_000)
  }
  return s
}

@main struct AudioServiceTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(Startup.current)
    } catch {
      print("audio-service-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    // The device, once devmgr binds it.
    let deadline = Clock.monotonic() + 30_000_000_000
    while Clock.monotonic() < deadline, ((try? ns.list("/dev/audio")) ?? []).isEmpty {
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    let first = status(ns)
    for l in lines(first) { print("audio-service-test: status: \(l)") }
    check(holds(first, "\nstate idle\n") && holds(first, "leases 0 "), "the service idles, holding no device")
    check(holds(ns.readText("/dev/audio/0/stat") ?? "", "\nout stopped "), "the device is stopped while nothing plays")

    // Two streams, half a second of a tone each, written in turns.
    let frames = 22050
    let a = tone(frames: frames, steps: 100, level: 8000), b = tone(frames: frames, steps: 40, level: 6000)
    var wrote = (0, 0)
    var lentSeen = false, dataRefused = false
    let started = Clock.monotonic()
    if var fa = try? ns.open("/svc/audio/audio"), var fb = try? ns.open("/svc/audio/audio") {
      while wrote.0 < a.count || wrote.1 < b.count {
        if wrote.0 < a.count, let n = try? fa.write(offset: 0, Array(a[wrote.0..<min(a.count, wrote.0 + 8192)])) {
          wrote.0 += Int(n)
        }
        if wrote.1 < b.count, let n = try? fb.write(offset: 0, Array(b[wrote.1..<min(b.count, wrote.1 + 8192)])) {
          wrote.1 += Int(n)
        }
        if !lentSeen, holds(ns.readText("/dev/audio/0/stat") ?? "", "\nout lent ") {
          lentSeen = true
          dataRefused = !ns.writeText("/dev/audio/0/data", "xxxx")
        }
      }
    }
    check(wrote.0 == a.count && wrote.1 == b.count, "both streams take their half second")
    check(lentSeen, "the service leases the device while it plays")
    check(dataRefused, "the lent device's data refuses another writer")
    let playing = status(ns)
    for l in lines(playing) where l.utf8.starts(with: "stream ".utf8) || l.utf8.starts(with: "state".utf8) {
      print("audio-service-test: while playing: \(l)")
    }
    check(numbers(playing, line: "streams", after: "streams").first == 2, "the service holds two streams")

    // Played out, a second of silence, and the lease given back.
    let done = idle(ns, leases: 1, within: 10)
    let elapsed = Clock.monotonic() - started
    for l in lines(done) { print("audio-service-test: after: \(l)") }
    print("audio-service-test: two streams of \(frames) frames played and released in \(elapsed / 1_000_000) ms")
    check(holds(done, "\nstate idle\n") && holds(done, "leases 1 "), "the service gives the lease back once silent")
    check(numbers(done, line: "streams", after: "streams").first == 0, "closed streams are dropped once played out")
    let cycles = numbers(done, line: "leases", after: "cycles").first ?? 0
    check(cycles >= UInt64(frames / 256), "the mixer ran a cycle for each quantum played (\(cycles))")
    let audible = numbers(done, line: "streams", after: "audible").first ?? 0
    check(audible >= UInt64(frames / 256), "every quantum of the tones was mixed (\(audible) audible)")
    // Half a second of frames, then a second of silence before the lease
    // goes: the device's time, not at once.
    check(elapsed >= 1_200_000_000, "the device took the frames at its rate")
    let device = ns.readText("/dev/audio/0/stat") ?? ""
    for l in lines(device) where l.utf8.starts(with: "out ".utf8) { print("audio-service-test: device: \(l)") }
    check(holds(device, "\nout stopped runs 1 "), "the device stops when the lease ends")

    // Again: a second lease.
    var again = false
    if var f = try? ns.open("/svc/audio/audio") {
      again = (try? f.write(offset: 0, tone(frames: 4410, steps: 50, level: 4000))) == 17640
    }
    check(again, "a stream after the lease ended is taken")
    let second = idle(ns, leases: 2, within: 10)
    check(holds(second, "leases 2 ") && holds(second, "\nstate idle\n"), "it plays under a second lease and idles again")
    for l in lines(second) where l.utf8.starts(with: "leases".utf8) || l.utf8.starts(with: "profile".utf8) {
      print("audio-service-test: end: \(l)")
    }

    print("audio-service-test: \(failures == 0 ? "passed" : "\(failures) failed")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
