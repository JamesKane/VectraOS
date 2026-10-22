// SPDX-License-Identifier: BSD-3-Clause

// Workspaces (D116): a window on one, switching shows only its windows,
// sending moves one, and `tile` keeps every window's spatial frame for
// `space` to put back.

import Radharc
import Testing

/// Frames for `n`'s windows as a layout would give them: side by side.
func columns(_ s: Scene, _ n: Int) -> [(id: UInt32, frame: Rect)] {
  guard let t = s.tiling(n) else { return [] }
  let w = t.area.width / max(1, t.windows.count)
  return t.windows.enumerated().map { (i, id) in (id, Rect(x: i * w, y: 0, width: w, height: t.area.height)) }
}

@Test func switchingShowsOneWorkspace() {
  let s = Scene(width: 800, height: 600)
  #expect(s.spaces.count == 4 && s.current == 1)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  #expect(a.workspace == 1 && a.shows)
  #expect(s.switchTo(2) == [.focus(window: 0)])
  #expect(!a.shows && a.away && s.isHidden(a.id))
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  #expect(b.workspace == 2 && s.focused == b.id)
  // Back: focus returns to the window last focused there.
  #expect(s.switchTo(1) == [.focus(window: a.id)])
  #expect(a.shows && !b.shows)
  #expect(s.switchTo(5) == nil && s.switchTo(1) == [])
  #expect(s.workspaceInfos().map { $0.windows } == [1, 1, 0, 0])
}

@Test func panelsAndTheDesktopAreOnEveryWorkspace() {
  let s = Scene(width: 800, height: 600)
  let (bar, _) = s.open(title: "bar", width: 200, height: 20)
  _ = s.setPanel(bar.id, true)
  let (desk, _) = s.open(title: "desk", width: 200, height: 100)
  _ = s.setDesktop(desk.id, true)
  _ = s.switchTo(3)
  #expect(bar.workspace == 0 && bar.shows && desk.shows)
  #expect(s.send(bar.id, to: 2) == [])
}

@Test func sendingMovesAWindowAndFocusStays() {
  let s = Scene(width: 800, height: 600)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  #expect(s.send(b.id, to: 2) == [.focus(window: a.id)])
  #expect(b.workspace == 2 && !b.shows && a.shows)
  // Shown again by `top`, which switches to its workspace.
  _ = s.top(b.id)
  #expect(s.current == 2 && b.shows && !a.shows && s.focused == b.id)
  #expect(s.send(b.id, to: 9) == nil)
}

@Test func tileKeepsSpatialFramesForSpace() {
  let s = Scene(width: 800, height: 600)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  let (b, _) = s.open(title: "b", width: 300, height: 150)
  let spatialA = a.content, spatialB = b.content
  #expect(s.setMode(1, .tile) == [.arrange(workspace: 1)])
  // Not placed until the layout answers.
  #expect(!a.tiled && a.content == spatialA)
  let t = s.tiling(1)
  #expect(t?.windows == [b.id, a.id] && t?.focused == b.id && t?.layout == "master-stack")
  let effects = s.applyTiles(1, columns(s, 1))
  #expect(effects.count == 2)
  #expect(a.tiled && b.tiled && b.frame == Rect(x: 0, y: 0, width: 400, height: 600))
  #expect(a.frame == Rect(x: 400, y: 0, width: 400, height: 600))
  // A drag doesn't move a tiled window, and `move` moves its spatial frame.
  _ = s.moveTo(a.tab.x + 30, a.tab.y + 5)
  _ = s.button(down: true)
  _ = s.moveBy(50, 50)
  _ = s.button(down: false)
  #expect(a.frame.x == 400)
  _ = s.move(a.id, x: spatialA.x + 10, y: spatialA.y)
  // Back to space: every window where it was.
  let back = s.setMode(1, .space)
  #expect(back?.count == 2)
  #expect(a.content == Rect(x: spatialA.x + 10, y: spatialA.y, width: spatialA.width, height: spatialA.height))
  #expect(b.content == spatialB && !a.tiled && !b.tiled)
}

@Test func aTiledWorkspaceIsArrangedAsWindowsComeAndGo() {
  let s = Scene(width: 800, height: 600)
  _ = s.setMode(1, .tile)
  let (a, ea) = s.open(title: "a", width: 200, height: 100)
  #expect(ea.last == .arrange(workspace: 1))
  _ = s.applyTiles(1, columns(s, 1))
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  #expect(s.tiling(1)?.windows == [b.id, a.id])
  _ = s.applyTiles(1, columns(s, 1))
  // The zoom box makes a window the master.
  #expect(s.zoom(a.id) == [.arrange(workspace: 1), .focus(window: a.id)])
  #expect(s.tiling(1)?.windows == [a.id, b.id])
  // Closing a tiled window, hiding one, or sending one away arranges again.
  #expect(s.close(b.id).contains(.arrange(workspace: 1)))
  let (c, _) = s.open(title: "c", width: 200, height: 100)
  _ = s.applyTiles(1, columns(s, 1))
  #expect(s.hide(c.id)?.contains(.arrange(workspace: 1)) == true)
  #expect(s.tiling(1)?.windows == [a.id])
  let sent = s.send(a.id, to: 2) ?? []
  #expect(sent.contains(.arrange(workspace: 1)) && !a.tiled && a.workspace == 2)
  // Into a tiled workspace, it's arranged there, first.
  _ = s.setMode(2, .tile)
  _ = s.show(c.id)
  #expect(s.send(c.id, to: 2)?.contains(.arrange(workspace: 2)) == true)
  #expect(s.tiling(2)?.windows == [c.id, a.id])
}

@Test func aLayoutsVerbSetsOrderFocusAndParameters() {
  let s = Scene(width: 800, height: 600)
  _ = s.setMode(1, .tile)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  let (b, _) = s.open(title: "b", width: 200, height: 100)
  _ = s.tiling(1)
  let e = s.setLayoutChange(1, order: [a.id, b.id, 99], focused: a.id, params: "ratio 60 masters 1")
  #expect(e == [.arrange(workspace: 1), .focus(window: a.id)])
  #expect(s.tiling(1)?.windows == [a.id, b.id] && s.spaces[0].params == "ratio 60 masters 1")
  #expect(s.setLayout(1, "columns") == [.arrange(workspace: 1)] && s.tiling(1)?.layout == "columns")
}

@Test func fullscreenLeavesTheLayout() {
  let s = Scene(width: 800, height: 600)
  let (a, _) = s.open(title: "a", width: 200, height: 100)
  let spatial = a.content
  _ = s.setMode(1, .tile)
  _ = s.applyTiles(1, columns(s, 1))
  #expect(a.tiled)
  let on = s.setFullscreen(a.id, true) ?? []
  #expect(on.contains(.arrange(workspace: 1)) && !a.tiled && s.tiling(1)?.windows == [])
  _ = s.setFullscreen(a.id, false)
  #expect(a.content == spatial && s.tiling(1)?.windows == [a.id])
}
