// SPDX-License-Identifier: BSD-3-Clause

// Loinnir's window (compose-test, boot-venus; D174, "Presentation, as designed"): a window of Radharc's whose frames are a
// ring of GPU images given to it as its own (the SDK's addImage), cleared by the GPU and presented, with no copy by the CPU
// and no read-back to it. Thirty frames of a changing colour are presented, paced by Radharc's frames, and the pixel Radharc
// composed for the last is Loinnir's colour, exactly.

import GPUClient
import GPUCore
import Loinnir
import Node
import Sys
import VX

private func hex2(_ v: Int) -> [UInt8] {
  let digits = Array("0123456789abcdef".utf8)
  return [digits[(v >> 4) & 15], digits[v & 15]]
}

/// A line of Radharc's window list for the window titled `title`: its content rectangle.
private func windowRect(_ ns: Namespace, title: String) -> (x: Int, y: Int, width: Int, height: Int)? {
  for line in lines(ns, "/svc/windows/list") {
    let words = line.split(separator: 0x20)
    guard words.count >= 7, Array(words[6]) == Array(title.utf8) else { continue }
    var numbers: [Int] = []
    for w in words[1...4] where w.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { numbers.append(w.reduce(0) { $0 * 10 + Int($1) - 0x30 }) }
    if numbers.count == 4 { return (numbers[0], numbers[1], numbers[2], numbers[3]) }
  }
  return nil
}

/// Radharc's composed pixel at the screen's (x, y), as six hex digits, or nil.
private func composedPixel(_ ns: Namespace, _ x: Int, _ y: Int) -> [UInt8]? {
  var probe = try? ns.open("/svc/windows/pixel")
  _ = try? probe?.writeText("\(x) \(y)")
  guard let text = (try? probe?.readText()) ?? nil else { return nil }
  return text.utf8.filter { $0 != 0x0A }
}

func loinnirPresentCheck(_ ns: Namespace) {
  if GPUClient.GPUContext.namespace == nil { GPUClient.GPUContext.namespace = ns }
  let title = "loinnir-present"
  guard var loop = try? Loop() else {
    check(false, "a loop for Loinnir's window")
    return
  }
  guard let win = try? loop.openWindow(title, width: 200, height: 150) else {
    check(false, "Radharc opens Loinnir's window")
    return
  }
  var config: Configure?
  var waited = 0
  while config == nil && waited < 100 {
    for e in loop.wait(until: Deadline(ns: Deadline.now.ns &+ 50_000_000)) where e.window == win {
      if case .configure(let c) = e.payload { config = c }
    }
    waited += 1
  }
  guard let first = config, let gpu = try? Loinnir.open(window: win, loop: &loop) else {
    check(false, "Loinnir opens on the window")
    return
  }
  var drawn = 0
  var last = (r: 0, g: 0, b: 0)
  var config2 = first
  for n in 0..<30 {
    // One present at a time (FIFO): until the last one's frame has come back.
    var spins = 0
    while !loop.canPresent(win) && spins < 400 {
      loop.requestFrame(win)
      for e in loop.wait(until: Deadline(ns: Deadline.now.ns &+ 25_000_000)) where e.window == win {
        if case .configure(let c) = e.payload { config2 = c }
      }
      spins += 1
    }
    let color = (r: (n * 8 + 8) & 255, g: 255 - ((n * 8) & 255), b: 64 + n)
    last = color
    do throws(LoinnirError) {
      if try gpu.clear((Float(color.r) / 255, Float(color.g) / 255, Float(color.b) / 255, 1), loop: &loop, config: config2) { drawn += 1 }
    } catch {
      check(false, "Loinnir draws and presents frame \(n)")
      return
    }
  }
  let counts = gpu.presentCounts
  print("compose-test: Loinnir drew \(drawn) frames into its window's ring and presented \(counts.presented), dropped \(counts.dropped)")
  check(counts.presented >= 25, "Loinnir presented its frames to the window (\(counts.presented) of 30)")

  // What Radharc composed for the last frame: the colour Loinnir cleared to, in the middle of the window.
  let want = hex2(last.r) + hex2(last.g) + hex2(last.b)
  var got: [UInt8]?
  var tries = 0
  while !(got.map { $0.elementsEqual(want) } ?? false) && tries < 100 {
    for _ in loop.wait(until: Deadline(ns: Deadline.now.ns &+ 50_000_000)) {}
    if let r = windowRect(ns, title: title) { got = composedPixel(ns, r.x + r.width / 2, r.y + r.height / 2) }
    tries += 1
  }
  let matches = got.map { $0.elementsEqual(want) } ?? false
  let gotText = got.map { String(decoding: $0, as: UTF8.self) } ?? "nothing"
  print("compose-test: Radharc composed \(gotText) in Loinnir's window (the frame's colour \(String(decoding: want, as: UTF8.self)))")
  check(matches, "the pixel Radharc composed in Loinnir's window is the last frame's colour, exactly")
  if matches && counts.presented >= 25 {
    print("compose-test: ok: Loinnir presented to a window of Radharc's through the present ring, with no CPU copy")
  }
  loop.closeWindow(win)
}
