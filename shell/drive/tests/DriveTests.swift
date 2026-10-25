// SPDX-License-Identifier: BSD-3-Clause

// drive(1)'s scripts as it reads them, its keys as HID usages, and how it
// decides the screen has settled.

import Drive
import Testing

@Test func aScriptsLinesAreItsSteps() throws {
  #expect(try Step.parse("move 960 540") == .move(960, 540))
  #expect(try Step.parse("click") == .click(.left, nil, nil))
  #expect(try Step.parse("click right") == .click(.right, nil, nil))
  #expect(try Step.parse("click 10 20") == .click(.left, 10, 20))
  #expect(try Step.parse("rightclick 1700 900") == .click(.right, 1700, 900))
  #expect(try Step.parse("click middle 5 6") == .click(.middle, 5, 6))
  #expect(try Step.parse("press right") == .press(.right))
  #expect(try Step.parse("key enter esc a f5") == .keys([[0x28], [0x29], [0x04], [0x3E]]))
  #expect(try Step.parse("key ctrl+w shift+tab") == .keys([[0xE0, 0x1A], [0xE1, 0x2B]]))
  #expect(throws: ScriptError.badKey("ctrl+")) { try Step.parse("key ctrl+") }
  #expect(try Step.parse("type Hi 2") == .type([(0x0B, true), (0x0C, false), (0x2C, false), (0x1F, false)]))
  #expect(try Step.parse("wait 250") == .wait(250))
  #expect(try Step.parse("settle") == .settle(quiet: 300, limit: 10_000))
  #expect(try Step.parse("settle 500 3000") == .settle(quiet: 500, limit: 3000))
  #expect(try Step.parse("waitfor Tracker") == .waitFor("Tracker", limit: 10_000))
  #expect(try Step.parse("waitfor Disk Usage 2000") == .waitFor("Disk Usage", limit: 2000))
  #expect(try Step.parse("waitgone Taisce 3000") == .waitGone("Taisce", limit: 3000))
  #expect(try Step.parse("mark the menu, open") == .mark("the menu, open"))
  #expect(try Step.parse("  # a comment") == nil)
  #expect(try Step.parse("") == nil)
  #expect(throws: ScriptError.unknown("fly")) { try Step.parse("fly 3") }
  #expect(throws: ScriptError.badKey("blorp")) { try Step.parse("key blorp") }
  #expect(throws: ScriptError.badButton("fourth")) { try Step.parse("click fourth") }
  #expect(throws: ScriptError.badNumber("-4")) { try Step.parse("move -4 3") }
}

@Test func theScreenSettlesWhenNoFrameComesForTheQuietTime() {
  let ms: Int64 = 1_000_000
  var s = Settling(start: 0, frames: 100)
  var quiet: [Bool] = []
  for (t, f) in [(10, 101), (200, 105), (400, 105), (500, 105)] {
    quiet.append(s.sample(now: Int64(t) * ms, frames: f, quiet: 300 * ms))
  }
  #expect(quiet == [false, false, false, true])
  // Five frames, the first 10 ms and the last 200 ms after the input.
  #expect(s.composed == 5 && s.answered == 10 * ms && s.busy == 200 * ms)
  // A slow app: its first frame 700 ms after the input is waited for.
  var slow = Settling(start: 0, frames: 7)
  var seen: [Bool] = []
  for (t, f) in [(300, 7), (500, 7), (700, 8), (1000, 8), (1100, 8)] {
    seen.append(slow.sample(now: Int64(t) * ms, frames: f, quiet: 400 * ms))
  }
  #expect(seen == [false, false, false, false, true] && slow.busy == 700 * ms)
  // No frame at all: settled after two seconds.
  var none = Settling(start: 0, frames: 7)
  let early = none.sample(now: 1900 * ms, frames: 7, quiet: 400 * ms)
  let late = none.sample(now: 2000 * ms, frames: 7, quiet: 400 * ms)
  #expect(!early && late && none.composed == 0)
}
