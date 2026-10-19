// SPDX-License-Identifier: BSD-3-Clause

// minimal, the SDK's reference app (sdk(2)): a window whose colour cycles
// with each frame; escape, or closing it, quits. Its window, frames and
// input take nine of the SDK's calls (Loop, openWindow, requestFrame,
// wait, cpuSurface, fill, present, requestFrame again and closeWindow);
// the budget is twelve. With an argument N, it quits after N frames.

import VX

@main struct Minimal {
  static func main() {
    let args = processArguments()
    let frameLimit = args.count > 1 ? Int(args[1]) : nil
    var drawn = 0
    guard var loop = try? Loop(), let win = try? loop.openWindow("minimal", width: 320, height: 180) else {
      print("minimal: no window")
      return
    }
    var seq: UInt64 = 0
    loop.requestFrame(win)

    main: while true {
      for e in loop.wait() {
        switch e.payload {
        case .configure(let c): seq = c.configSeq
        case .frame(let f):
          if let px = loop.cpuSurface(win) {
            let t = UInt32(truncatingIfNeeded: f.target.ns / 16_000_000)
            px.fill((t &* 3 & 0xff) << 16 | (t &* 5 & 0xff) << 8 | (t &* 7 & 0xff))
            try? loop.present(win, px, configSeq: seq)
            drawn += 1
            if drawn == frameLimit { break main }
          }
          loop.requestFrame(win)
        case .keyDown(let k) where k.usage == .escape: break main
        case .close: break main
        default: break
        }
      }
    }
    loop.closeWindow(win)
    print("minimal: \(drawn) frames")
  }
}
