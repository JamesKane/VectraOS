// SPDX-License-Identifier: BSD-3-Clause

// bin/rio (D75, D107): Plan 9's rio as text windows in Radharc, which
// stays the compositor and window manager. Each window is a Kit app
// (RioWindow) running rc: rio serves the window's files (WindowFiles) in
// its tree at wsys/N, and starts rc in a namespace of its own, rio's with
// those files before /dev and an environment group of its own, in a job
// of its own under its manifest's `programs`. rc, with no descriptors,
// takes /dev/cons as its terminal. Delete posts `interrupt` to rc's note
// group; closing the window posts `hangup` and kills the job; when rc
// ends, the window goes. wctl's verbs are done on the window's next wake:
// moves by placing it, sizes, raising and hiding through Radharc's window
// list (`/svc/windows/windows`), by the window's id there. rio's own
// `wctl`, at the top of its tree, takes `new`. It opens one window at the
// start, and stays when the last has closed. A window's `surface`
// (RioIPC.Surface) is lent to a program in it, vt: its view is embedded
// over the window's content, sized with it, until the view closes.

import IPC
import Kbdfs
import Kit
import KitPlatform
import Node
import Radharc
import Rio
import Synchronization
import Sys
import VX
import VectraOSLibc

/// A window's rc: its process and job, held until both are done with.
final class Programs: @unchecked Sendable {
  let process: UInt32
  let job: UInt32
  let pid: UInt64
  let namespace: Namespace

  init(process: consuming Handle, job: consuming Handle, pid: UInt64, namespace: Namespace) {
    self.process = process.release()
    self.job = job.release()
    self.pid = pid
    self.namespace = namespace
  }

  /// A note to its note group (the job's processes rc started with it).
  func note(_ text: String) {
    if var group = try? namespace.open("/proc/\(pid)/notepg") { try? group.writeText(text) }
  }

  func kill() {
    let j = Handle(raw: job)
    try? Sys.kill(j)
    _ = j.release()
  }

  /// Waits for rc to end.
  func wait() {
    let p = Handle(raw: process)
    _ = try? p.wait(for: Signals.terminated)
    _ = p.release()
  }

  deinit { Sys.close(raw: [process, job]) }
}

/// A channel of a window's snarf: the clipboard's text read once, from
/// its first read on; what is written, committed when it closes.
final class SnarfChannel: Sendable {
  let text = Mutex<[UInt8]?>(nil)
  let written = Mutex<[UInt8]>([])

  func take(_ max: Int) -> [UInt8] {
    text.withLock { t in
      if t == nil { t = Array((Snarf.read() ?? "").utf8) }
      let n = min(max, t!.count)
      defer { t!.removeFirst(n) }
      return Array(t![..<n])
    }
  }

  func commit() {
    let w = written.withLock { $0 }
    if !w.isEmpty { Snarf.write(String(decoding: w, as: UTF8.self)) }
  }
}

/// The windows whose rc ended.
final class Ended: Sendable {
  let ids = Mutex<[Int]>([])
}

/// A window's streams, made after its files (whose `ready` names them).
final class Streams: @unchecked Sendable {
  var cons: TreeNode?
  var kbd: TreeNode?
  var wctl: TreeNode?
}

@MainActor final class OpenWindow {
  let app: RioWindow
  let kit: KitWindow
  let directory: TreeNode
  var programs: Programs?
  var place: (x: Int32, y: Int32)
  var visible = true
  /// The keys held, as kbd's messages name them (kbdfs's runes).
  var held: [UInt32] = []
  /// The view the surface is lent to: its token until it is embedded
  /// (raw, 0: none), whether it is, and the size it was last given.
  var surface: UInt32 = 0
  var lent = false
  var embedded: (width: Int32, height: Int32)?

  init(app: RioWindow, kit: KitWindow, directory: TreeNode, place: (x: Int32, y: Int32)) {
    self.app = app
    self.kit = kit
    self.directory = directory
    self.place = place
  }
}

@MainActor final class Rio {
  let session: Session
  let namespace: Namespace
  let tree: NodeTree
  let dispatcher: IPCDispatcher
  /// The job each window's own is made under (its manifest's `programs`).
  let parent: UInt32
  let screen: WctlRect
  let cascade = Cascade()
  var windows: [OpenWindow] = []
  var nextID = 1
  var list: RadharcIPC.WindowsClient?
  /// rio's own wctl (`new` only), as a window 0's files.
  let top: WindowFiles
  /// Windows whose rc ended, from their waiting threads.
  let ended = Ended()

  init(session: Session, namespace: Namespace, tree: NodeTree, dispatcher: IPCDispatcher, parent: UInt32,
       screen: WctlRect) {
    self.session = session
    self.namespace = namespace
    self.tree = tree
    self.dispatcher = dispatcher
    self.parent = parent
    self.screen = screen
    top = WindowFiles(id: 0, label: "rio", wdir: "/", screen: screen, cascade: cascade, changed: session.waker)
    tree.directory("wsys")
    let top = top
    tree.text("wctl", read: {
      "\(screen.minX)".padded + "\(screen.minY)".padded + "\(screen.maxX)".padded + "\(screen.maxY)".padded
        + "nowindow    nowindow    "
    }, write: { (text: String) throws(NodeError) in
      if top.command(text) != nil { throw .invalid }
    })
    session.stayOpen = true
    session.onWake = { [unowned self] in wake() }
    session.onClose = { [unowned self] w in if let o = window(w) { delete(o) } }
    session.onMoved = { [unowned self] w, x, y in
      if let o = window(w) {
        o.place = (x, y)
        report(o)
      }
    }
    session.afterFrame = { [unowned self] w in
      if let o = window(w) {
        report(o)
        embed(o)
      }
      return false
    }
    // The view the surface was lent to closed: the window's text again.
    session.onViewGone = { [unowned self] w, _ in if let o = window(w) { takeBack(o) } }
    session.onKey = { [unowned self] w, k, down in
      guard let o = window(w), o.app.files.kbdOpen else { return false }
      kbd(o, k, down)
      return true
    }
  }

  func window(_ w: KitWindow) -> OpenWindow? { windows.first { $0.kit === w } }

  /// Opens a window running `command` (none: an interactive rc) in
  /// `directory`, at `rect`.
  @discardableResult
  func open(command: String, directory: String, rect: WctlRect, hidden: Bool = false) -> Bool {
    let id = nextID
    nextID += 1
    let streams = Streams()
    let tree = tree
    let files = WindowFiles(id: id, label: command.isEmpty ? "rc" : command, wdir: directory, screen: screen,
                            cascade: cascade,
                            ready: { file in
                              let node: TreeNode? = switch file {
                              case .cons: streams.cons
                              case .kbd: streams.kbd
                              case .wctl: streams.wctl
                              }
                              if let node { tree.ready(node) }
                            }, changed: session.waker)
    let app = RioWindow(files: files)
    let kit: KitWindow
    do {
      kit = try session.open(app, width: Int32(rect.width), height: Int32(rect.height),
                             at: (Int32(rect.minX), Int32(rect.minY)))
    } catch {
      print("rio: no window: \(error)")
      return false
    }
    let dir = "wsys/\(id)"
    let o = OpenWindow(app: app, kit: kit, directory: tree.directory(dir), place: (Int32(rect.minX), Int32(rect.minY)))
    serve(files, at: dir, streams)
    app.changed = { [unowned self] in session.redraw(kit) }
    app.interrupt = { [unowned o] in o.programs?.note("interrupt") }
    app.clipboard = Clipboard(read: { Snarf.read() }, write: { Snarf.write($0) })
    windows.append(o)
    if hidden { hide(o, true) }
    guard let programs = start(command, in: directory, serving: o.directory) else {
      files.write(Array("rio: can't start rc\n".utf8))
      return true
    }
    o.programs = programs
    let ended = ended, waker = session.waker
    _ = try? Thread.spawn {
      programs.wait()
      ended.ids.withLock { $0.append(id) }
      waker()
    }.release()
    return true
  }

  /// The window's files in rio's tree.
  func serve(_ files: WindowFiles, at dir: String, _ streams: Streams) {
    streams.cons = tree.stream(dir + "/cons", NodeStream(
      take: { files.readCons($0) },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32? in
        files.write(data)
        return UInt32(data.count)
      }))
    tree.stream(dir + "/consctl", NodeStream(
      take: { _ in [] },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32? in
        guard files.control(String(decoding: data, as: UTF8.self)) else { throw .invalid }
        return UInt32(data.count)
      },
      opened: { files.consctlOpened() }, closed: { files.consctlClosed() }))
    streams.kbd = tree.stream(dir + "/kbd", NodeStream(
      take: { files.readKbd($0) }, opened: { files.kbdOpened() }, closed: { files.kbdClosed() }))
    tree.text(dir + "/label", read: { files.label }, write: { (text: String) throws(NodeError) in files.label = text })
    tree.text(dir + "/text", read: { String(decoding: files.text, as: UTF8.self) },
              write: { (text: String) throws(NodeError) in files.write(Array(text.utf8)) })
    streams.wctl = tree.stream(dir + "/wctl", NodeStream(
      perChannel: {
        let read = files.wctlReader()
        return NodeStreamChannel(take: { (max: Int) throws(NodeError) -> [UInt8]? in read(max) })
      },
      write: { (data: [UInt8]) throws(NodeError) -> UInt32? in
        if files.command(String(decoding: data, as: UTF8.self)) != nil { throw .invalid }
        return UInt32(data.count)
      }))
    tree.text(dir + "/wdir", read: { files.wdir }, write: { (text: String) throws(NodeError) in files.setWdir(text) })
    tree.text(dir + "/winid", read: { files.winid })
    // The clipboard (D112), passed to rio's own: snarf read only while the
    // window is focused and has had input since, its writes committed
    // when the channel closes; clip is Radharc's, mounted.
    tree.stream(dir + "/snarf", NodeStream(perChannel: {
      let channel = SnarfChannel()
      return NodeStreamChannel(
        take: { (max: Int) throws(NodeError) -> [UInt8]? in
          guard files.mayRead else { throw .denied }
          return channel.take(max)
        },
        write: { (data: [UInt8]) throws(NodeError) -> UInt32? in
          channel.written.withLock { $0 += data }
          return UInt32(data.count)
        },
        closed: { channel.commit() })
    }))
    if let clip = try? namespace.connect("/svc/windows/clip") { tree.mount(dir + "/clip", clip, removeWhenGone: false) }
    let dispatcher = dispatcher
    tree.service(dir + "/surface") { (channel: consuming Handle) throws(Status) in
      try dispatcher.add(RioIPC.SurfaceServer(channel: channel, impl: Surface(files: files)))
    }
  }

  /// The surface's view, lent: shown over the content.
  func embed(_ o: OpenWindow) {
    if let raw = o.app.files.takeLent() {
      if o.surface != 0 { _ = Handle(raw: o.surface) }
      o.surface = raw
      o.lent = true
      o.embedded = nil
      o.app.text.keyRunes = true
    }
    guard o.lent, let c = o.kit.configuration, o.embedded.map({ $0 != (c.width, c.height) }) ?? true else { return }
    do throws(WindowError) {
      // The token goes with the first embed; after, the embedding is placed.
      if o.surface != 0 {
        let token = Handle(raw: o.surface)
        o.surface = 0
        try session.embed(o.kit, token: token, id: 1, x: 0, y: 0, width: c.width, height: c.height)
      } else {
        try session.placeEmbedding(o.kit, id: 1, x: 0, y: 0, width: c.width, height: c.height)
      }
      o.embedded = (c.width, c.height)
    } catch {
      // Not a view's, or the view's gone already.
      takeBack(o)
    }
  }

  /// The window's text shown again, its surface free to lend.
  func takeBack(_ o: OpenWindow) {
    guard o.lent else { return }
    session.unembed(o.kit, id: 1)
    if o.surface != 0 { _ = Handle(raw: o.surface) }
    o.surface = 0
    o.lent = false
    o.embedded = nil
    o.app.text.keyRunes = false
    o.app.files.returned()
    session.redraw(o.kit)
  }

  /// rc in a namespace of the window's: rio's, its files before /dev, a
  /// new environment group with PWD its directory.
  func start(_ command: String, in directory: String, serving files: TreeNode) -> Programs? {
    do throws(Status) {
      guard let wns = try? namespace.clone(), let rc = try? namespace.memory("/bin/rc", executable: true) else {
        return nil
      }
      let ends = try Channel.create()
      try tree.serve(ends.a, at: files)
      guard (try? wns.mount(ends.b, at: "/dev", .before)) != nil else { return nil }
      if let group = try? wns.connect("/svc/env/new") { try? wns.mount(group, at: "/env") }
      try? wns.setEnvironment("PWD", Array(directory.utf8) + [0])
      var entry = ProgramEntry(image: rc.vmo.raw, offset: 0, length: Int(rc.size), name: "rc")
      entry.libraries = namespace.libraries
      let p = Handle(raw: parent)
      let made = Result { () throws(Status) in try Job.create(parent: p) }
      _ = p.release()
      let job = try made.get()
      // (rc takes $PWD only reading its input: a command is run after a cd.)
      let quoted = "'" + directory.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "''") + "'"
      let startup = Startup(args: command.isEmpty ? ["rc", "-i"] : ["rc", "-c", "cd " + quoted + "; " + command])
      guard (try? startup.mount(wns)) != nil else { return nil }
      // Its programs start in its own job: interrupts reach all of them.
      startup.add(try job.duplicate(), info: HandleType.info(HandleType.jobDefault))
      let process = try Process.create(job: job, name: "rc")
      let pid = try process.info().koid
      _ = try Process.start(process, entry: entry, startup)
      _ = consume rc
      return Programs(process: process, job: job, pid: pid, namespace: namespace)
    } catch {
      print("rio: starting rc: \(error.rawValue)")
      return nil
    }
  }

  /// The window's state for wctl: its content on the screen, its focus,
  /// whether it is shown.
  func report(_ o: OpenWindow) {
    guard let c = o.kit.configuration else { return }
    let r = WctlRect(minX: Int(o.place.x), minY: Int(o.place.y), maxX: Int(o.place.x) + Int(c.width),
                     maxY: Int(o.place.y) + Int(c.height))
    o.app.files.place(r, screen: screen, current: c.focused, visible: o.visible)
  }

  /// A wake: windows whose rc ended go, wctl's verbs are done, and a
  /// surface lent is shown.
  func wake() {
    for o in windows { embed(o) }
    for id in ended.ids.withLock({ e in
      defer { e = [] }
      return e
    }) {
      if let o = windows.first(where: { $0.app.files.id == id }) { remove(o) }
    }
    for c in top.takeCommands() { run(c, from: nil) }
    for o in windows {
      for c in o.app.files.takeCommands() { run(c, from: o) }
    }
  }

  /// A verb from window `from`'s wctl (nil: rio's own).
  func run(_ c: WctlCommand, from: OpenWindow?) {
    var target = from
    if let id = c.id {
      guard let o = windows.first(where: { $0.app.files.id == id }) else { return }
      target = o
    }
    if c.verb == .new {
      open(command: c.command, directory: c.directory ?? from?.app.files.wdir ?? "/", rect: c.rect, hidden: c.hidden)
      return
    }
    guard let o = target else { return }
    switch c.verb {
    case .move:
      session.place(o.kit, x: Int32(c.rect.minX), y: Int32(c.rect.minY))
    case .resize:
      session.place(o.kit, x: Int32(c.rect.minX), y: Int32(c.rect.minY))
      o.place = (Int32(c.rect.minX), Int32(c.rect.minY))
      if let id = session.listID(o.kit) { onList { try? $0.resize(id: id, width: UInt32(c.rect.width), height: UInt32(c.rect.height)) } }
    case .top, .current:
      if let id = session.listID(o.kit) { onList { try? $0.top(id: id) } }
    case .hide: hide(o, true)
    case .unhide: hide(o, false)
    case .delete: delete(o)
    case .scroll, .noscroll, .set, .new, .bottom: break
    }
    report(o)
  }

  func hide(_ o: OpenWindow, _ on: Bool) {
    guard o.visible == on, let id = session.listID(o.kit) else { return }
    onList { list in if on { try? list.hide(id: id) } else { try? list.show(id: id) } }
    o.visible = !on
  }

  /// A call on Radharc's window list, connected the first time.
  func onList(_ body: (inout RadharcIPC.WindowsClient) -> Void) {
    if list == nil, let ch = try? namespace.connect("/svc/windows/windows") { list = RadharcIPC.WindowsClient(channel: ch) }
    if list != nil { body(&list!) }
  }

  /// The window closed: its programs hear `hangup`, then go.
  func delete(_ o: OpenWindow) {
    o.programs?.note("hangup")
    o.programs?.kill()
    remove(o)
  }

  func remove(_ o: OpenWindow) {
    guard let i = windows.firstIndex(where: { $0 === o }) else { return }
    windows.remove(at: i)
    if o.surface != 0 { _ = Handle(raw: o.surface) }
    if let raw = o.app.files.takeLent() { _ = Handle(raw: raw) }
    o.programs?.kill()
    o.app.files.delete()
    tree.remove(o.directory)
    session.close(o.kit)
  }

  /// A key for kbd, as kbdfs's messages: `k` or `K` with the keys held,
  /// each its rune without modifiers, and `c` with the rune a press types.
  func kbd(_ o: OpenWindow, _ k: VX.Key, _ down: Bool) {
    guard k.usage.rawValue < 256 else { return }
    let usage = UInt8(k.usage.rawValue)
    let rune = Keymap.us[.none, usage]
    guard rune != 0 else { return }
    if down {
      if !o.held.contains(rune) { o.held.append(rune) }
    } else {
      o.held.removeAll { $0 == rune }
    }
    func runes(_ r: [UInt32]) -> String { String(String.UnicodeScalarView(r.compactMap { Unicode.Scalar($0) })) }
    o.app.files.key((down ? "k" : "K") + runes(o.held))
    if down {
      let layer: Keymap.Layer = k.modifiers.contains(.control) ? .ctl : k.modifiers.contains(.shift) ? .shift : .none
      let typed = Keymap.us[layer, usage]
      if typed != 0 { o.app.files.key("c" + runes([typed])) }
    }
  }
}

/// A window's surface, served on the dispatcher's thread: the view's
/// token goes to the window's next wake.
struct Surface: RioIPC.SurfaceHandler {
  let files: WindowFiles
  func lend(view: consuming Handle) throws(RioIPC.SurfaceError) {
    guard (try? view.info()) != nil else { throw .invalid }
    let raw = view.release()
    guard files.lend(raw) else {
      _ = Handle(raw: raw)
      throw .lent
    }
  }
}

extension String {
  /// Right aligned in 11 columns, then a space, as rio's numbers.
  var padded: String { String(repeating: " ", count: max(0, 11 - utf8.count)) + self + " " }
}

@main struct RioMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { Process.fail("no namespace") }
    guard let job = start.take(HandleType.info(HandleType.jobDefault)) else {
      Process.fail("no job to start windows' programs in (its manifest's `programs`)")
    }
    guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { Process.fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let session: Session
    do { session = try Session() } catch { Process.fail("no session: \(error)") }
    session.appName = "rio"
    // The screen, for wctl's rectangles.
    var size = (width: 1280, height: 800)
    if let ch = try? ns.connect("/svc/windows/compositor") {
      var compositor = RadharcIPC.CompositorClient(channel: ch)
      if let s = try? compositor.screen() { size = (Int(s.width), Int(s.height)) }
    }
    let screen = WctlRect(minX: 0, minY: 0, maxX: size.width, maxY: size.height)
    let rio = Rio(session: session, namespace: ns, tree: tree, dispatcher: dispatcher, parent: job.release(),
                  screen: screen)
    do throws(Status) {
      try tree.serve(export)
      _ = try Thread.spawn { try? dispatcher.run() }.release()
    } catch {
      Process.fail("can't serve: \(error.rawValue)")
    }
    let directory = ns.getenv("PWD").flatMap { $0.isEmpty ? nil : $0 } ?? "/"
    guard rio.open(command: "", directory: directory, rect: Wctl.newRect(screen: screen, cascade: rio.cascade.current))
    else { Process.fail("no first window") }
    rio.cascade.advance()
    print("rio: ready")
    await session.run()
    _ = rio
  }
}
