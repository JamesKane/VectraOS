// SPDX-License-Identifier: BSD-3-Clause

// bin/vt (D75, D107): Plan 9's vt, an xterm for a program that wants one,
// in the rio window it runs in. It opens a view the window's size (from
// /dev/wctl) and lends it to the window (/dev/surface, RioIPC.Surface),
// which shows it over its text, then runs the program on stdio rings in
// a namespace of its own, `TERM=xterm-256color` and the screen's size as
// `COLUMNS` and `LINES` in an environment group of its own. The window is
// raw (/dev/consctl's rawon) while vt runs: its keys, as rio's runes, come
// on vt's stdin from rc, and go to the program as xterm sends them
// (RuneKeys); the program's output is fed to TerminalCore's screen, drawn
// in the view (TerminalModel). When the program ends, vt writes its main
// screen's text to its stdout, so the window keeps it, and ends; the
// window shows its text again.

import IPC
import Kit
import KitPlatform
import Node
import Rio
import Synchronization
import Sys
import TerminalApp
import TerminalCore
import VX
import VectraOSLibc

/// The program's stdin.
final class ProgramLink: TerminalLink, @unchecked Sendable {
  let stdin: ChildStream
  init(_ s: ChildStream) { stdin = s }
  func write(_ bytes: [UInt8]) { try? stdin.write(bytes) }
  /// The program has no way to hear a new size: there is no pty.
  func resize(columns: Int, rows: Int) {}
}

/// Set once, read on the main actor.
final class Flag: Sendable {
  let value = Atomic<Bool>(false)
  func set() { value.store(true, ordering: .releasing) }
  var isSet: Bool { value.load(ordering: .acquiring) }
}

/// The program's link, made after the model (which it is given later).
final class LaterLink: TerminalLink, @unchecked Sendable {
  let link = Mutex<ProgramLink?>(nil)
  func write(_ bytes: [UInt8]) { link.withLock { $0 }?.write(bytes) }
  func resize(columns: Int, rows: Int) {}
}

@main struct VtMain {
  @MainActor static func main() async {
    let start = Startup.current
    var args = Array(processArguments().dropFirst())
    if args.isEmpty { args = ["rc", "-i"] }
    guard let ns = processNamespace() else { Process.fail("no namespace") }
    guard let job = start.take(HandleType.info(HandleType.jobDefault)) else { Process.fail("no job to start the program in") }
    let path = args[0].hasPrefix("/") || args[0].hasPrefix("./") ? args[0] : "/bin/" + args[0]
    guard let program = try? ns.memory(path, executable: true) else { Process.fail("\(args[0]): not found") }

    // The window's size, from its wctl's first read.
    var size = (width: Int32(640), height: Int32(400))
    if var wctl = try? ns.open("/dev/wctl"), let b = try? wctl.read(offset: 0, max: 128) {
      let f = String(decoding: b, as: UTF8.self).split(separator: " ").compactMap { Int32($0) }
      if f.count == 4, f[2] > f[0], f[3] > f[1] { size = (f[2] - f[0], f[3] - f[1]) }
    }
    guard var consctl = try? ns.open("/dev/consctl"), (try? consctl.writeText("rawon")) != nil else {
      Process.fail("not in a rio window: no /dev/consctl")
    }

    let session: Session
    do { session = try Session() } catch { Process.fail("no session: \(error)") }
    let painter = Painter(theme: session.theme, fonts: session.fonts)
    let style = session.theme.style("terminal")
    let link = LaterLink()
    let model = TerminalModel(link: link, theme: session.theme,
                              cell: CellMetrics(width: painter.measure("M", style), height: painter.lineHeight(style)))
    let view: KitWindow
    do { view = try session.openView(model, width: size.width, height: size.height) } catch {
      Process.fail("no view: \(error)")
    }
    guard let token = session.viewToken(view), let channel = try? ns.connect("/dev/surface") else {
      Process.fail("not in a rio window: no /dev/surface")
    }
    var surface = RioIPC.SurfaceClient(channel: channel)
    do { try surface.lend(view: token) } catch { Process.fail("the window's surface: \(error)") }

    // Keys: rc relays the window's raw cons to vt's stdin.
    let waker = session.waker
    _ = try? Thread.spawn {
      var buffer = [UInt8](repeating: 0, count: 256)
      while true {
        let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        model.deliverKeys(Array(buffer[0..<n]))
        waker()
      }
    }

    // The program starts once the screen has its size, after the first frame.
    let ended = Flag()
    var started = false
    // The program's end seen, and the frame after it asked for, which
    // feeds the screen what came last.
    var ending = false
    var stdio: ChildStdio? = nil
    session.afterFrame = { _ in
      if !started {
        started = true
        guard let s = run(program, args, ns: ns, job: job, columns: model.screen.columns, rows: model.screen.rows) else {
          print("vt: can't start \(args[0])")
          return true
        }
        stdio = s
        link.link.withLock { $0 = ProgramLink(s.stream(0)!) }
        let out = s.stream(1)!
        _ = try? Thread.spawn {
          while let bytes = try? out.read(), !bytes.isEmpty {
            model.deliver(bytes)
            waker()
          }
          ended.set()
          waker()
        }
      }
      guard ended.isSet else { return false }
      if ending { return true }
      ending = true
      session.redraw(view)
      return false
    }
    await session.run()
    // Its main screen, left in the window as text.
    if model.screen.alternate { model.screen.feed(Array("\u{1B}[?1049l".utf8)) }
    var rows = (0..<model.screen.rows).map { model.screen.text(row: $0) }
    while rows.last?.isEmpty == true { rows.removeLast() }
    for r in rows { print(r) }
    _ = consume consctl
    _ = stdio
    exit(0)
  }

  /// `program` started with `args` on stdio rings, in a job under vt's, in
  /// a namespace of its own: vt's, with an environment group of its own
  /// holding TERM, COLUMNS and LINES.
  static func run(_ program: borrowing NodeIPC.Memory, _ args: [String], ns: Namespace, job: borrowing Handle,
                  columns: Int, rows: Int) -> ChildStdio? {
    guard let pns = try? ns.clone() else { return nil }
    if let group = try? pns.connect("/svc/env/new") { try? pns.mount(group, at: "/env") }
    for (name, value) in [("TERM", "xterm-256color"), ("COLUMNS", String(columns)), ("LINES", String(rows))] {
      try? pns.setEnvironment(name, Array(value.utf8) + [0])
    }
    let name = String(args[0].split(separator: "/").last ?? "program")
    var entry = ProgramEntry(image: program.vmo.raw, offset: 0, length: Int(program.size), name: name)
    entry.libraries = ns.libraries
    let startup = Startup(args: args)
    guard (try? startup.mount(pns)) != nil else { return nil }
    do throws(Status) {
      let own = try Sys.Job.create(parent: job)
      startup.add(try own.duplicate(), info: HandleType.info(HandleType.jobDefault))
      let stdio = try ChildStdio(for: startup)
      let process = try Process.create(job: own, name: name)
      _ = try Process.start(process, entry: entry, startup)
      return stdio
    } catch {
      return nil
    }
  }
}
