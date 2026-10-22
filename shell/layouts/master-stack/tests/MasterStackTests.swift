// SPDX-License-Identifier: BSD-3-Clause

// master-stack (D116): the frames for the order and parameters it's
// given, and its verbs.

import MasterStack
import Testing

let screen = Frame(x: 0, y: 0, width: 1000, height: 600)

@Test func oneWindowHasTheArea() {
  #expect(MasterStack.arrange(screen, count: 1, .init()) == [screen])
  #expect(MasterStack.arrange(screen, count: 0, .init()) == [])
}

@Test func theMasterHasTheRatioAndTheRestStack() {
  let f = MasterStack.arrange(screen, count: 3, .init())
  #expect(f == [Frame(x: 0, y: 0, width: 550, height: 600), Frame(x: 550, y: 0, width: 450, height: 300),
                Frame(x: 550, y: 300, width: 450, height: 300)])
  // Three in the stack: the last takes what doesn't divide.
  let g = MasterStack.arrange(Frame(x: 0, y: 0, width: 1000, height: 601), count: 4, .init())
  #expect(g.map { $0.height } == [601, 200, 200, 201])
}

@Test func mastersAndRatioComeFromTheParameters() {
  let p = MasterStack.Params("ratio 70 masters 2")
  #expect(p.ratio == 70 && p.masters == 2 && p.text == "ratio 70 masters 2")
  let f = MasterStack.arrange(screen, count: 3, p)
  #expect(f.map { $0.x } == [0, 0, 700] && f[0].height == 300)
  // No masters, or all of them: one column.
  #expect(MasterStack.arrange(screen, count: 2, .init("masters 0")).map { $0.width } == [1000, 1000])
  // Out of range, or not a number: the default.
  #expect(MasterStack.Params("ratio 95 masters x") == MasterStack.Params())
  #expect(MasterStack.Params("") == MasterStack.Params())
}

@Test func verbsMoveFocusSwapAndResize() {
  let p = MasterStack.Params()
  let next = MasterStack.act("focus next", windows: [1, 2, 3], focused: 3, p)
  #expect(next?.focused == 1 && next?.order == [1, 2, 3])
  #expect(MasterStack.act("focus prev", windows: [1, 2, 3], focused: 1, p)?.focused == 3)
  #expect(MasterStack.act("swap", windows: [1, 2, 3], focused: 3, p)?.order == [3, 2, 1])
  #expect(MasterStack.act("swap", windows: [1, 2, 3], focused: 1, p)?.order == [2, 1, 3])
  #expect(MasterStack.act("grow", windows: [], focused: 0, p)?.params.ratio == 60)
  #expect(MasterStack.act("shrink", windows: [], focused: 0, .init("ratio 10"))?.params.ratio == 10)
  #expect(MasterStack.act("masters +1", windows: [], focused: 0, p)?.params.masters == 2)
  #expect(MasterStack.act("masters -1", windows: [], focused: 0, .init("masters 0"))?.params.masters == 0)
  #expect(MasterStack.act("dance", windows: [1], focused: 1, p) == nil)
  #expect(MasterStack.act("focus sideways", windows: [1], focused: 1, p) == nil)
}
