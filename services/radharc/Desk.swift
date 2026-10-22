// SPDX-License-Identifier: BSD-3-Clause

// Radharc's workspaces off its lock (D116), and the gated `shortcuts`
// (D111, from todhchai's M6k k6b and k6c).
//
// The scene keeps the workspaces (lib's Workspaces.swift) and says when a
// tiled one needs its layout asked. One worker thread does what mustn't
// happen under the lock: it calls layouts, each a process that registered
// a `Layout` channel at `layout` and holds no state, with a deadline, and
// hands the scene their frames; and it writes Settings (`Workspaces`,
// `Frames`, `Grants`). A layout that is gone or late leaves the frames as
// they are; one registering under a name already held replaces it.
//
// The verbs (`windows`'s typed ones and `ctl`'s words, one handler) show
// a workspace, send a window to one, set one's mode or layout, and pass a
// verb to the shown one's layout.
//
// `shortcuts` is in the tree of a client whose manifest grants it, and is
// served once the user allowed it: an answer kept in Grants (`always`),
// or given this session; with neither, Radharc asks on its own prompt and
// holds the channel meanwhile. A recorded grant revoked (Settings follows
// Grants) closes the channels it opened.

import IPC
import Node
import Radharc
import Settings
import Sys

/// The work the worker does, in order.
enum DeskJob {
  case register(UInt32)
  case arrange(Int)
  case act(Int, String)
  case store(area: String, name: String, value: SettingValue)
  /// A gated service the user allowed: served off the lock.
  case serve(GatedAsk)
  /// The theme Settings hold for the workspace shown (D119).
  case theme
}

/// A gated service's channel held while its question is up.
final class GatedAsk: @unchecked Sendable {
  let id: UInt64
  let client: String
  let service: String
  var raw: UInt32
  let serve: (UInt32, Bool) -> Void
  var recorded = false
  init(id: UInt64, client: String, service: String, raw: UInt32, serve: @escaping (UInt32, Bool) -> Void) {
    self.id = id
    self.client = client
    self.service = service
    self.raw = raw
    self.serve = serve
  }
}

/// A registered layout's channel: only the worker calls it.
final class LayoutConn {
  let name: String
  var client: RadharcIPC.LayoutClient
  init(name: String, client: consuming RadharcIPC.LayoutClient) {
    self.name = name
    self.client = client
  }
}

/// Runs `body` when dropped: a server's end.
final class OnGone: @unchecked Sendable {
  let body: () -> Void
  init(_ body: @escaping () -> Void) { self.body = body }
  deinit { body() }
}

/// Under the state's lock, but for `bell`.
final class Desk: @unchecked Sendable {
  /// The theme tree (D119), and the workspace whose theme was settled.
  var themes: ThemeTree?
  var themedSpace = 0
  /// Rung when there's work (no handle if it couldn't be made: then
  /// nothing is arranged or kept).
  let bell: Handle = (try? Counter.create()) ?? Handle(raw: 0)
  var jobs: [DeskJob] = []
  /// The layouts registered, by name (the worker keeps their channels),
  /// and those replaced by another of their name.
  var layouts: [String] = []
  var replaced = 0
  /// Verbs layouts refused, and calls that failed or were late.
  var refused = 0
  var failed = 0
  /// The mode switch's budget (desktop.mode_switch): the latch count at
  /// the verb, whether the new frames are in, and the last switch's
  /// frames.
  var switchAt: Int?
  var switchIn = false
  var switchFrames = 0
  var switches = 0
  /// Chords and their holders (`shortcuts`): each holder's presses not
  /// sent yet, and whether a recorded grant let it in; keys a chord took,
  /// whose key-ups and repeats are taken too.
  var chords: [(id: UInt32, chord: RadharcIPC.Chord, holder: UInt64)] = []
  var holders: [(key: UInt64, server: UInt64, client: String, recorded: Bool, pressed: [UInt32])] = []
  var nextChord: UInt32 = 0
  var consumed: [UInt16] = []
  var chordsPressed = 0
  /// Gated questions up, and what the user allowed this session.
  var asking: [GatedAsk] = []
  var session: [String] = []
  /// Radharc's namespace, for Settings (set once, before serving).
  var ns: Namespace?

  func ask(_ job: DeskJob) {
    // One arrange of a workspace waiting is enough.
    if case .arrange(let n) = job, jobs.contains(where: { if case .arrange(n) = $0 { true } else { false } }) { return }
    jobs.append(job)
    try? Counter.add(bell, 1)
  }

  func next() -> DeskJob? { jobs.isEmpty ? nil : jobs.removeFirst() }

  /// A latch: a mode switch whose frames are in has taken this many.
  func latched(_ latches: Int) {
    guard let at = switchAt, switchIn else { return }
    switchFrames = latches - at
    switches += 1
    switchAt = nil
  }

  /// A prompt answered: one of the gated questions? Allowed, it's served
  /// (and an `always` recorded), off the lock; denied, closed.
  func answered(_ id: UInt64, _ reply: [UInt8]) -> Bool {
    guard let i = asking.firstIndex(where: { $0.id == id }) else { return false }
    let a = asking.remove(at: i)
    if reply.starts(with: "always".utf8) {
      a.recorded = true
      ask(.store(area: Grants.area, name: Grants.name(a.client, a.service), value: .bool(true)))
      ask(.serve(a))
    } else if reply.starts(with: "session".utf8) || reply.starts(with: "once".utf8) {
      session.append(a.client + "." + a.service)
      ask(.serve(a))
    } else {
      _ = Handle(raw: a.raw)  // closed: refused
      print("radharc: \(a.client) was refused \(a.service)")
    }
    return true
  }

  /// Whether the user allowed `client` `service` this session.
  func allowed(_ client: String, _ service: String) -> Bool {
    session.contains { same($0, client + "." + service) }
  }
}

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// The worker: layouts called, frames applied, Settings written.
func runDesk(_ state: State, _ ns: Namespace) {
  var conns: [LayoutConn] = []
  var seen: Int64 = 0
  while true {
    guard (try? Counter.wait(state.desk.bell, until: seen + 1, deadline: infiniteDeadline)) != nil else { return }
    seen = (try? Counter.read(state.desk.bell)) ?? seen
    while let job = state.lock.withLock({ state.desk.next() }) {
      switch job {
      case .register(let raw):
        var client = RadharcIPC.LayoutClient(channel: Handle(raw: raw))
        client.connection.timeout = 50_000_000
        guard let name = try? client.name(), !name.isEmpty else { continue }
        // One of its name already: replaced, and told to retire (D122).
        for old in conns where same(old.name, name) {
          try? old.client.retire()
          state.lock.withLock { state.desk.replaced += 1 }
        }
        conns.removeAll { same($0.name, name) }
        conns.append(LayoutConn(name: name, client: client))
        print("radharc: layout \(name)")
        state.lock.withLock {
          state.desk.layouts = conns.map { $0.name }
          for (i, s) in state.scene.spaces.enumerated() where s.mode == .tile && same(s.layout, name) {
            state.desk.ask(.arrange(i + 1))
          }
        }
      case .arrange(let n):
        guard let t = state.lock.withLock({ state.scene.tiling(n) }) else { continue }
        guard let c = conns.first(where: { same($0.name, t.layout) }) else { continue }
        let area = RadharcIPC.Area(x: Int32(t.area.x), y: Int32(t.area.y), width: Int32(t.area.width),
                                   height: Int32(t.area.height))
        guard let frames = try? c.client.arrange(area: area, windows: t.windows, focused: t.focused, params: t.params),
          frames.count == t.windows.count
        else {
          gone(c, state, &conns)
          continue
        }
        state.lock.withLock {
          let effects = state.scene.applyTiles(n, zip(t.windows, frames).map { (id: $0, frame: rect($1)) })
          state.apply(effects)
          if state.desk.switchAt != nil { state.desk.switchIn = true }
          state.noteChanges()
          state.wake()
        }
      case .act(let n, let verb):
        guard let t = state.lock.withLock({ state.scene.tiling(n) }),
          let c = conns.first(where: { same($0.name, t.layout) })
        else { continue }
        do throws(IPCError<RadharcIPC.WindowError>) {
          let change = try c.client.act(verb: verb, windows: t.windows, focused: t.focused, params: t.params)
          state.lock.withLock {
            state.apply(state.scene.setLayoutChange(n, order: change.order, focused: change.focused, params: change.params))
            state.desk.ask(.store(area: "Workspaces", name: "Workspaces:\(n):Params", value: .string(change.params)))
            state.noteChanges()
            state.wake()
          }
        } catch .remote {
          state.lock.withLock { state.desk.refused += 1 }
        } catch {
          gone(c, state, &conns)
        }
      case .store(let area, let name, let value):
        if !Settings.store(area, name, value, ns) { print("radharc: can't keep \(name)") }
      case .serve(let a):
        a.serve(a.raw, a.recorded)
      case .theme:
        // A write to Appearance or Workspaces still to come would make what
        // is read now stale; its watch event asks again.
        let pending = state.lock.withLock {
          state.desk.jobs.contains { j in
            if case .store(let area, _, _) = j { return same(area, "Appearance") || same(area, "Workspaces") }
            return false
          }
        }
        if !pending { settleTheme(state, ns) }
      }
    }
  }
}

/// A layout that failed or was late: dropped; its workspaces keep their
/// frames until one registers under its name again.
func gone(_ c: LayoutConn, _ state: State, _ conns: inout [LayoutConn]) {
  print("radharc: layout \(c.name) is gone")
  conns.removeAll { $0 === c }
  let names = conns.map { $0.name }
  state.lock.withLock {
    state.desk.layouts = names
    state.desk.failed += 1
  }
}

/// A layout registering (`layout`): its channel goes to the worker.
struct LayoutProviderSession: RadharcIPC.LayoutProviderHandler {
  let state: State
  func register(layout: consuming Handle) {
    let raw = layout.release()
    state.lock.withLock { state.desk.ask(.register(raw)) }
  }
}

// MARK: The verbs

/// A workspace number from a word: 1 to the count.
func workspaceNumber(_ w: Substring.UTF8View?, _ state: State) -> Int? {
  guard let w, !w.isEmpty, w.count <= 2, w.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
  let n = w.reduce(0) { $0 * 10 + Int($1 - 0x30) }
  return n >= 1 && n <= state.scene.spaces.count ? n : nil
}

/// Workspace `n`'s mode set, kept, and timed (desktop.mode_switch). Under
/// the lock.
func setMode(_ n: Int, _ mode: RadharcIPC.WorkspaceMode, _ state: State) -> Bool {
  guard let effects = state.scene.setMode(n, mode) else { return false }
  guard !effects.isEmpty else { return true }
  if n == state.scene.current {
    state.desk.switchAt = state.latches
    state.desk.switchIn = mode == .space
  }
  state.apply(effects)
  state.desk.ask(.store(area: "Workspaces", name: "Workspaces:\(n):Mode", value: .string(mode == .tile ? "tile" : "space")))
  return true
}

/// `ctl`'s words: `workspace N`, `send N [ID]`, `mode tile|space|toggle
/// [N]`, `layout NAME [N]`, `act VERB...`. Whether they were understood
/// and done. Under the lock.
func deskVerb(_ text: String, _ state: State) -> Bool {
  let words = text.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 })
  guard let verb = words.first.map({ String(decoding: $0, as: UTF8.self) }) else { return false }
  let scene = state.scene
  var done = true
  switch verb {
  case _ where same(verb, "theme"):
    // A workspace's own theme (D119), or `none`: Appearance's.
    guard words.count == 2 || words.count == 3 else { return false }
    let n = words.count == 3 ? workspaceNumber(words[2], state) : scene.current
    let name = String(decoding: words[1], as: UTF8.self)
    guard let n, same(name, "none") || state.desk.themes?.installed(name) == true else { return false }
    state.desk.ask(.store(area: "Workspaces", name: "Workspaces:\(n):Theme", value: .string(same(name, "none") ? "" : name)))
    state.desk.ask(.theme)
  case _ where same(verb, "lock"):
    // The lock screen (D118): refused if nothing could unlock it.
    guard words.count == 1 else { return false }
    done = state.lockScreen(now: Clock.monotonic())
  case _ where same(verb, "workspace"):
    guard words.count == 2, let n = workspaceNumber(words[1], state), let e = scene.switchTo(n) else { return false }
    state.apply(e)
  case _ where same(verb, "send"):
    guard words.count == 2 || words.count == 3, let n = workspaceNumber(words[1], state) else { return false }
    var id = scene.focused
    if words.count == 3 {
      guard words[2].count <= 9, words[2].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
      id = UInt32(words[2].reduce(0) { $0 * 10 + Int($1 - 0x30) })
    }
    guard let e = scene.send(id, to: n) else { return false }
    state.apply(e)
  case _ where same(verb, "mode"):
    guard words.count == 2 || words.count == 3 else { return false }
    let n = words.count == 3 ? workspaceNumber(words[2], state) : scene.current
    guard let n else { return false }
    let word = String(decoding: words[1], as: UTF8.self)
    let mode: RadharcIPC.WorkspaceMode
    if same(word, "tile") {
      mode = .tile
    } else if same(word, "space") {
      mode = .space
    } else if same(word, "toggle") {
      mode = scene.spaces[n - 1].mode == .tile ? .space : .tile
    } else {
      return false
    }
    done = setMode(n, mode, state)
  case _ where same(verb, "layout"):
    guard words.count == 2 || words.count == 3 else { return false }
    let n = words.count == 3 ? workspaceNumber(words[2], state) : scene.current
    let name = String(decoding: words[1], as: UTF8.self)
    guard let n, let e = scene.setLayout(n, name) else { return false }
    state.apply(e)
    state.desk.ask(.store(area: "Workspaces", name: "Workspaces:\(n):Layout", value: .string(name)))
  case _ where same(verb, "act"):
    guard words.count >= 2, scene.spaces[scene.current - 1].mode == .tile else { return false }
    let rest = words.dropFirst().map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    state.desk.ask(.act(scene.current, rest))
  default:
    return false
  }
  state.noteChanges()
  state.wake()
  return done
}

/// The `workspaces` file: a line each, `N MODE LAYOUT current|- WINDOWS
/// PARAMS`.
func workspacesText(_ state: State) -> String {
  state.scene.spaces.enumerated().map { (i, s) in
    let n = i + 1
    let count = state.scene.windows.filter { $0.workspace == n && $0.popupOf == nil }.count
    return "\(n) \(s.mode == .tile ? "tile" : "space") \(s.layout) \(n == state.scene.current ? "current" : "-") \(count)"
      + (s.params.isEmpty ? "" : " " + s.params) + "\n"
  }.joined()
}

/// The workspaces kept in Settings (D116), before any window opens.
func restoreWorkspaces(_ state: State, _ ns: Namespace) {
  let kept = Settings.read("Workspaces", ns)
  func string(_ name: String) -> String? {
    guard case .string(let s)? = kept.first(where: { same($0.name, name) })?.value else { return nil }
    return s
  }
  if case .int(let n)? = kept.first(where: { same($0.name, "Workspaces:Count") })?.value {
    state.scene.setWorkspaceCount(Int(n))
  }
  for n in 1...state.scene.spaces.count {
    let mode: RadharcIPC.WorkspaceMode = string("Workspaces:\(n):Mode").map { same($0, "tile") } == true ? .tile : .space
    state.scene.restoreWorkspace(n, mode: mode, layout: string("Workspaces:\(n):Layout") ?? "",
                                 params: string("Workspaces:\(n):Params") ?? "")
  }
}

// MARK: Themes (D119)

/// The theme in force from Settings, off the lock: the shown workspace's
/// (`Workspaces:<n>:Theme`), else `Appearance:Theme`; with
/// `Appearance:HighContrast` and `Appearance:Accent`'s knob. With no
/// volume, the theme stays as `ctl` left it.
func settleTheme(_ state: State, _ ns: Namespace) {
  guard let themes = state.desk.themes, (try? ns.open("/data")) != nil else { return }
  let n = state.lock.withLock { state.scene.current }
  let app = Settings.read("Appearance", ns), spaces = Settings.read("Workspaces", ns)
  func string(_ kept: [(name: String, value: SettingValue)], _ name: String) -> String? {
    guard case .string(let s)? = kept.first(where: { same($0.name, name) })?.value, !s.isEmpty else { return nil }
    return s
  }
  let theme = string(spaces, "Workspaces:\(n):Theme") ?? string(app, Settings.theme.name) ?? "platinum-indigo"
  var contrast = false
  if case .bool(true)? = app.first(where: { same($0.name, Settings.highContrast.name) })?.value { contrast = true }
  let accent = string(app, Settings.accent.name) ?? "theme"
  themes.settle(theme: theme, highContrast: contrast, knobs: same(accent, "theme") ? [] : [("accent", "accent." + accent)])
}

// MARK: The lock screen (D118)

/// `Lock:Minutes` (10 if unset; 0 never), and `Lock:Locked`: a lock that
/// outlives Radharc's restart. Under the lock.
func restoreLock(_ state: State, _ ns: Namespace) {
  let kept = Settings.read("Lock", ns)
  state.lockAfter = lockMinutes(kept) * 60_000_000_000
  if case .bool(true)? = kept.first(where: { same($0.name, "Lock:Locked") })?.value {
    state.scene.setLocked(true, now: Clock.monotonic())
  }
}

func lockMinutes(_ kept: [(name: String, value: SettingValue)]) -> Int64 {
  guard case .int(let m)? = kept.first(where: { same($0.name, "Lock:Minutes") })?.value, m >= 0 else { return 10 }
  return Int64(m)
}

// MARK: Spatial memory

/// An app's window closing: its spatial frame kept in `Frames` (`APP` =
/// `WORKSPACE X Y W H`), for the app's next window. Under the lock.
func keepFrame(_ w: SceneWindow, _ state: State) {
  guard !w.app.isEmpty, !w.isView, w.popupOf == nil, !w.desktop, !w.panel, w.workspace > 0 else { return }
  let f = w.spatial ?? (w.fullscreen ? nil : w.content)
  guard let f else { return }
  state.desk.ask(.store(area: "Frames", name: "Frames:" + w.app,
                        value: .string("\(w.workspace) \(f.x) \(f.y) \(f.width) \(f.height)")))
}

/// An app's frame as kept, if any: read off the lock.
func keptFrame(_ app: String, _ ns: Namespace) -> (workspace: Int, frame: Radharc.Rect)? {
  guard case .string(let s)? = Settings.read("Frames", ns).first(where: { same($0.name, "Frames:" + app) })?.value
  else { return nil }
  var v: [Int] = []
  for w in s.utf8.split(separator: 0x20) {
    var neg = false, n = 0, digits = 0
    for b in w {
      if b == 0x2D && digits == 0 && !neg { neg = true; continue }
      guard b >= 0x30 && b <= 0x39, digits < 6 else { return nil }
      n = n * 10 + Int(b - 0x30)
      digits += 1
    }
    guard digits > 0 else { return nil }
    v.append(neg ? -n : n)
  }
  guard v.count == 5, v[3] >= 16, v[4] >= 16 else { return nil }
  return (v[0], Radharc.Rect(x: v[1], y: v[2], width: v[3], height: v[4]))
}

/// Window `id` of `app` opening where the app's last window was, if it's
/// the app's only one and hasn't placed itself: on its workspace, at its
/// frame. Under the lock.
func placeAtKept(_ id: UInt32, _ app: String, _ kept: (workspace: Int, frame: Radharc.Rect), _ state: State) {
  let scene = state.scene
  guard let w = scene.window(id), !w.placed, !w.undecorated,
    !scene.windows.contains(where: { $0.id != id && same($0.app, app) && !$0.isView && $0.popupOf == nil })
  else { return }
  var effects: [SceneEffect] = []
  if kept.workspace != w.workspace, let e = scene.send(id, to: kept.workspace) { effects += e }
  let f = kept.frame
  let x = min(max(f.x, 0), scene.width - 32), y = min(max(f.y, Scene.tabHeight), scene.height - 32)
  effects += scene.move(id, x: x, y: y) ?? []
  if f.width != w.content.width || f.height != w.content.height {
    effects += scene.resize(id, width: min(f.width, scene.width), height: min(f.height, scene.height)) ?? []
  }
  state.apply(effects)
}

// MARK: shortcuts

struct ShortcutsSession: RadharcIPC.ShortcutsHandler {
  let state: State
  let key: UInt64
  let end: OnGone
  func register(_ chord: RadharcIPC.Chord) throws(RadharcIPC.WindowError) -> UInt32 {
    let id = state.lock.withLock { () -> UInt32? in
      guard !state.desk.chords.contains(where: { $0.chord == chord }) else { return nil }
      state.desk.nextChord += 1
      state.desk.chords.append((state.desk.nextChord, chord, key))
      return state.desk.nextChord
    }
    guard let id else { throw .invalid }
    return id
  }
  func unregister(_ id: UInt32) {
    state.lock.withLock { state.desk.chords.removeAll { $0.id == id && $0.holder == key } }
  }
}

/// Serves `shortcuts` on channel `raw` for `client` (off the lock).
func serveShortcuts(_ raw: UInt32, _ client: String, recorded: Bool, _ state: State) {
  let key = state.lock.withLock { () -> UInt64 in
    state.nextSubscriber += 1
    return state.nextSubscriber
  }
  let end = OnGone {
    state.lock.withLock {
      state.desk.holders.removeAll { $0.key == key }
      state.desk.chords.removeAll { $0.holder == key }
    }
  }
  let server = RadharcIPC.ShortcutsServer(channel: Handle(raw: raw), impl: ShortcutsSession(state: state, key: key, end: end))
  guard let id = try? state.dispatcher.add(server, wake: {
    (s: inout RadharcIPC.ShortcutsServer<ShortcutsSession>) throws(IPCError<Never>) in
    let pressed = state.lock.withLock { () -> [UInt32] in
      guard let i = state.desk.holders.firstIndex(where: { $0.key == key }) else { return [] }
      defer { state.desk.holders[i].pressed.removeAll() }
      return state.desk.holders[i].pressed
    }
    for p in pressed { try RadharcIPC.ShortcutsEventSender.sendPressed(p, on: s.connection) }
  }) else { return }
  print("radharc: \(client) holds shortcuts")
  state.lock.withLock { state.desk.holders.append((key, id, client, recorded, [])) }
}

/// A key matched against the chords held, before focus: a chord's holder
/// hears it, and nothing else does, its key-up and repeats included.
/// Whether the key was taken. Under the lock.
func chordTaken(_ e: InputEvent, _ state: State) -> Bool {
  let desk = state.desk
  let held = e.modifiers & ~InputEvent.Modifier.capsLock
  if e.kind == .keyDown, e.flags & InputEvent.isRepeat == 0,
    let c = desk.chords.first(where: { $0.chord.code == e.code && $0.chord.modifiers == held }),
    let k = desk.holders.firstIndex(where: { $0.key == c.holder })
  {
    desk.holders[k].pressed.append(c.id)
    desk.chordsPressed += 1
    state.dispatcher.wake(desk.holders[k].server)
    desk.consumed.append(e.code)
    return true
  }
  if e.kind == .keyUp, let i = desk.consumed.firstIndex(of: e.code) {
    desk.consumed.remove(at: i)
    return true
  }
  return e.kind == .keyDown && desk.consumed.contains(e.code)  // its repeats
}

/// A gated service at `service` in `client`'s tree: served if the user
/// allowed it (recorded, or this session), refused if they recorded no,
/// else asked on the prompt with the channel held.
func gated(_ tree: NodeTree, _ service: String, client: String, _ ns: Namespace, _ state: State,
           _ serve: @escaping (UInt32, Bool) -> Void)
{
  tree.service(service) { (channel: consuming Handle) throws(Status) in
    let raw = channel.release()
    let kept = Grants.recorded(client, service, ns)
    if kept == true { return serve(raw, true) }
    if kept == false {
      _ = Handle(raw: raw)
      print("radharc: \(client) was refused \(service)")
      return
    }
    let now = state.lock.withLock { () -> Bool in
      if state.desk.allowed(client, service) { return true }
      let entry = "ask=confirm app=\(client) service=\(service) answers=session,always\n"
      guard let q = try? PromptQuestion(parsing: Array(entry.utf8), id: state.scene.newPromptID(), asker: "radharc") else {
        _ = Handle(raw: raw)
        return false
      }
      state.desk.asking.append(GatedAsk(id: q.id, client: client, service: service, raw: raw, serve: serve))
      state.asked += 1
      state.scene.ask(q, now: Clock.monotonic())
      return false
    }
    if now { serve(raw, false) } else { state.wake() }
  }
}

/// Follows Grants (Settings' watch): a recorded grant revoked, or changed
/// to no, closes the channels it opened.
func followGrants(_ state: State, _ ns: Namespace) {
  guard var watch = Settings.watch(ns) else {
    print("radharc: no /data/Settings: grants revoked close nothing until restart")
    return
  }
  while let e = try? watch.nextEvent() {
    guard case .changed(let c) = e else { continue }
    if Settings.touches(c, "Appearance") || Settings.touches(c, "Workspaces") {
      state.lock.withLock { state.desk.ask(.theme) }
    }
    if Settings.touches(c, "Lock") {
      let after = lockMinutes(Settings.read("Lock", ns)) * 60_000_000_000
      state.lock.withLock { state.lockAfter = after }
      state.wake()
    }
    guard Settings.touches(c, Grants.area) else { continue }
    let held = state.lock.withLock { state.desk.holders.filter { $0.recorded }.map { ($0.server, $0.client) } }
    for (server, client) in held where Grants.recorded(client, "shortcuts", ns) != true {
      print("radharc: \(client)'s shortcuts revoked")
      state.dispatcher.unwatch(server)
    }
  }
}
