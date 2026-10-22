// SPDX-License-Identifier: BSD-3-Clause

// Workspaces (D116): each output has several, each `space` (free
// placement) or `tile` (placed by a layout). A window is on one; the
// desktop, panels, views and popups are on every one (a popup with its
// owner). Switching shows one workspace's windows and hides the rest.
//
// Both arrangements are kept. A tiled window keeps its spatial frame
// (`spatial`), and back in `space` it is there again: nothing is
// recomputed from the tiles. The scene doesn't call layouts: a change that
// needs one says `.arrange(workspace:)`, Radharc asks the workspace's
// layout off its lock (`tiling`) and hands back the frames
// (`applyTiles`). Until then, and if no layout answers, the frames stay.

/// A workspace: its mode, its layout's name and parameters, its tiled
/// windows in the layout's order, and the window last focused there.
public struct Workspace: Sendable {
  public var mode: RadharcIPC.WorkspaceMode = .space
  public var layout = "master-stack"
  public var params = ""
  public var order: [UInt32] = []
  public var focused: UInt32 = 0
  public init() {}
}

extension Scene {
  /// How many workspaces there are (1 to 9), keeping the first `n`; the
  /// windows of any dropped go to the last kept. Done before any window
  /// opens, from Settings.
  public func setWorkspaceCount(_ n: Int) {
    let n = min(max(n, 1), 9)
    while spaces.count < n { spaces.append(Workspace()) }
    if spaces.count > n { spaces.removeLast(spaces.count - n) }
    for w in windows where w.workspace > n { w.workspace = n }
    if current > n { current = n }
  }

  /// Workspace `n`'s mode, layout and parameters as kept (Settings), with
  /// no arranging: done before any window opens.
  public func restoreWorkspace(_ n: Int, mode: RadharcIPC.WorkspaceMode, layout: String, params: String) {
    guard n >= 1, n <= spaces.count else { return }
    spaces[n - 1].mode = mode
    if !layout.isEmpty { spaces[n - 1].layout = layout }
    spaces[n - 1].params = params
  }

  /// Whether window `w` is placed by a `tile` workspace's layout: an
  /// ordinary window on one, shown, not fullscreen.
  func tileable(_ w: SceneWindow) -> Bool {
    w.workspace > 0 && !w.undecorated && !w.isView && !w.hidden && w.workspace <= spaces.count
      && spaces[w.workspace - 1].mode == .tile
  }

  /// What `n`'s layout is asked: the area (the screen), its windows in
  /// order (any not in the order yet after it, top first), the one focused
  /// and the parameters. nil if `n` isn't tiled.
  public func tiling(_ n: Int) -> (area: Rect, windows: [UInt32], focused: UInt32, layout: String, params: String)? {
    guard n >= 1, n <= spaces.count, spaces[n - 1].mode == .tile else { return nil }
    let mine = windows.filter { $0.workspace == n && tileable($0) }.map { $0.id }
    var order = spaces[n - 1].order.filter { mine.contains($0) }
    for id in mine.reversed() where !order.contains(id) { order.append(id) }
    spaces[n - 1].order = order
    let f = n == current ? focused : spaces[n - 1].focused
    return (Rect(x: 0, y: 0, width: width, height: height), order, order.contains(f) ? f : 0, spaces[n - 1].layout,
            spaces[n - 1].params)
  }

  /// The frames `n`'s layout gave (decorations included), a window each:
  /// each window tiled there takes its frame, its spatial frame kept the
  /// first time; a configure for each that changed size.
  public func applyTiles(_ n: Int, _ frames: [(id: UInt32, frame: Rect)]) -> [SceneEffect] {
    guard n >= 1, n <= spaces.count, spaces[n - 1].mode == .tile else { return [] }
    var effects: [SceneEffect] = []
    for (id, f) in frames {
      guard let w = window(id), w.workspace == n, tileable(w) else { continue }
      let b = w.border, t = w.tabHeight
      let content = Rect(x: f.x + b, y: f.y + t + b, width: max(16, f.width - 2 * b), height: max(16, f.height - t - 2 * b))
      if w.spatial == nil {
        w.spatial = w.zoomedFrom ?? w.content
        w.zoomedFrom = nil
      }
      guard content != w.content else { continue }
      if !w.away { add(damage: w.painted) }
      let resized = content.width != w.content.width || content.height != w.content.height
      w.content = content
      if !w.away { add(damage: w.painted) }
      if resized {
        w.asked = (content.width, content.height)
        effects.append(configure(w))
      }
    }
    return effects
  }

  /// A layout's verb done: `n`'s order, focus and parameters as it left
  /// them; then it is arranged again.
  public func setLayoutChange(_ n: Int, order: [UInt32], focused id: UInt32, params: String) -> [SceneEffect] {
    guard n >= 1, n <= spaces.count, spaces[n - 1].mode == .tile else { return [] }
    let mine = spaces[n - 1].order
    spaces[n - 1].order = order.filter { mine.contains($0) } + mine.filter { !order.contains($0) }
    spaces[n - 1].params = params
    var effects: [SceneEffect] = [.arrange(workspace: n)]
    if n == current, let w = window(id), w.workspace == n, w.shows {
      raise(id)
      effects += focus(id)
    }
    return effects
  }

  /// Window `w` back at its spatial frame, if it was tiled.
  func untile(_ w: SceneWindow) -> [SceneEffect] {
    guard let s = w.spatial else { return [] }
    w.spatial = nil
    if !w.away { add(damage: w.painted) }
    let resized = s.width != w.content.width || s.height != w.content.height
    w.content = s
    if !w.away { add(damage: w.painted) }
    guard resized else { return [] }
    w.asked = (s.width, s.height)
    return [configure(w)]
  }

  /// `.arrange` for window `w`'s workspace, if it's tiled.
  func rearrange(_ w: SceneWindow) -> [SceneEffect] {
    w.workspace > 0 && w.workspace <= spaces.count && spaces[w.workspace - 1].mode == .tile
      ? [.arrange(workspace: w.workspace)] : []
  }

  /// Shows workspace `n`; nil if there's no such workspace. Focus goes to
  /// the window last focused there, or its top one.
  public func switchTo(_ n: Int) -> [SceneEffect]? {
    guard n >= 1, n <= spaces.count else { return nil }
    guard n != current else { return [] }
    spaces[current - 1].focused = focused
    current = n
    for w in windows where w.workspace > 0 { w.away = w.workspace != n }
    followOwners()
    damageAll()
    let last = spaces[n - 1].focused
    if let w = window(last), w.shows { return focus(last) }
    return focus(windows.last { !$0.isView && $0.shows && $0.workspace == n }?.id ?? topVisible?.id ?? 0)
  }

  /// Moves window `id` to workspace `n`, where it takes `n`'s mode: out of
  /// a tiled one at its spatial frame, into one arranged. nil if there's
  /// no such window or workspace; the desktop and panels stay on all.
  public func send(_ id: UInt32, to n: Int) -> [SceneEffect]? {
    guard let w = window(id), n >= 1, n <= spaces.count, !w.isView, w.popupOf == nil else { return nil }
    guard w.workspace > 0, w.workspace != n else { return [] }
    var effects = rearrange(w)
    let from = w.workspace
    spaces[from - 1].order.removeAll { $0 == id }
    effects += untile(w)
    if !w.away { add(damage: w.painted) }
    w.workspace = n
    w.away = n != current
    if spaces[n - 1].mode == .tile {
      spaces[n - 1].order.insert(id, at: 0)
      effects.append(.arrange(workspace: n))
    }
    followOwners()
    if w.away {
      if spaces[n - 1].focused == 0 || window(spaces[n - 1].focused) == nil { spaces[n - 1].focused = id }
      if focused == id {
        effects += focus(windows.last { !$0.isView && $0.shows && $0.workspace == current }?.id ?? topVisible?.id ?? 0)
      }
    } else {
      add(damage: w.painted)
    }
    return effects
  }

  /// Workspace `n`'s mode: to `tile`, arranged (spatial frames kept); to
  /// `space`, every window back at its spatial frame. nil if there's no
  /// such workspace.
  public func setMode(_ n: Int, _ mode: RadharcIPC.WorkspaceMode) -> [SceneEffect]? {
    guard n >= 1, n <= spaces.count else { return nil }
    guard spaces[n - 1].mode != mode else { return [] }
    spaces[n - 1].mode = mode
    guard mode == .space else { return [.arrange(workspace: n)] }
    var effects: [SceneEffect] = []
    for w in windows where w.workspace == n { effects += untile(w) }
    return effects
  }

  /// Workspace `n`'s layout, by name; arranged again if it's tiled.
  public func setLayout(_ n: Int, _ name: String) -> [SceneEffect]? {
    guard n >= 1, n <= spaces.count, !name.isEmpty else { return nil }
    spaces[n - 1].layout = name
    return spaces[n - 1].mode == .tile ? [.arrange(workspace: n)] : []
  }

  /// Each workspace as the `windows` service gives it.
  public func workspaceInfos() -> [RadharcIPC.WorkspaceInfo] {
    spaces.indices.map { i in
      RadharcIPC.WorkspaceInfo(number: UInt32(i + 1), mode: spaces[i].mode, layout: spaces[i].layout,
                               current: i + 1 == current,
                               windows: UInt32(windows.filter { $0.workspace == i + 1 && $0.popupOf == nil }.count))
    }
  }
}
