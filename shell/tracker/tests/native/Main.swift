// SPDX-License-Identifier: BSD-3-Clause

// tracker-test (boot-tracker): Tracker on the desktop, its plumber ports
// (`folder` and `find`), the file chooser (`choose`, D111) embedding
// Tracker's `ChooserView` in Radharc's trusted prompt and returning a
// confined `FsIPC.File` channel to the calling window, and the warm 100k
// folder listing check (`tracker.list_100k`).

import Fs
import IPC
import Node
import Plumber
import Radharc
import Settings
import Sys
import Tracker
import VX
import VectraOSLibc

func numbers(_ ns: Namespace, _ word: String) -> [Int] {
  let line = (ns.readText("/svc/windows/status") ?? "").split(separator: "\n")
    .first { $0.hasPrefix(word + " ") } ?? ""
  return line.split(separator: " ").dropFirst().compactMap { Int($0) }
}

func click(_ ns: Namespace, _ x: Int, _ y: Int) -> Bool {
  let p = numbers(ns, "pointer")
  guard p.count == 2 else { return false }
  print("qemu: mouse_move \(x - p[0]) \(y - p[1])")
  guard within(10, { numbers(ns, "pointer") == [x, y] }) else { return false }
  print("qemu: mouse_button 1")
  sleep(until: Clock.monotonic() + 100_000_000)
  print("qemu: mouse_button 0")
  return true
}

func waitChosen(_ loop: inout Loop, _ wid: WindowID, seconds: Int) -> Bool? {
  let end = Clock.monotonic() + Int64(seconds) * 1_000_000_000
  while Clock.monotonic() < end {
    for e in loop.wait(until: .now + .milliseconds(50)) where e.window == wid {
      if case .chosen(let ok) = e.payload { return ok }
    }
  }
  return nil
}

@main struct TrackerTest {
  static func main() {
    guard let ns = processNamespace() else {
      print("tracker-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(within(30) {
      (ns.readText("/svc/tracker/status") ?? "").contains("ready\n")
        && (ns.readText("/svc/windows/list") ?? "").contains(" Taisce\n")
    }, "Tracker starts and opens the desktop window")

    guard let dataCh = try? ns.connect("/data") else {
      check(false, "connect /data")
      Process.exit(code: 1)
    }
    let volume = Volume(root: FsIPC.DirectoryClient(channel: dataCh))
    _ = try? volume.makeFile(in: "", named: "notes.md", contents: Array("# notes\n".utf8))
    _ = try? volume.makeFile(in: "", named: "secret.txt", contents: Array("secret\n".utf8))

    var loop: Loop
    do { loop = try Loop() } catch {
      check(false, "a loop")
      Process.exit(code: 1)
    }
    guard let wid = try? loop.openWindow("chooser-client", width: 200, height: 120) else {
      check(false, "a client window")
      Process.exit(code: 1)
    }
    // Drain initial configure/frame events.
    _ = loop.wait(until: .now + .milliseconds(100))

    var screen: RadharcIPC.ScreenInfo?
    if let ch = try? ns.connect("/svc/windows/compositor") {
      var c = RadharcIPC.CompositorClient(channel: ch)
      screen = try? c.screen()
    }
    let (sw, sh) = screen.map { (Int($0.width), Int($0.height)) } ?? (800, 600)

    // 1. Open file chooser (`save: false`, filtered to `text/markdown`).
    check((try? loop.choose(wid, save: false, types: ["text/markdown"], name: "")) != nil,
          "window.choose(open) starts a chooser prompt")
    check(within(10) {
      numbers(ns, "prompts").first == 1 && (ns.readText("/svc/tracker/status") ?? "").contains("chooser ")
    }, "the chooser prompt is on screen")
    sleep(until: Clock.monotonic() + 600_000_000)
    // `up` with no selection picks the last visible entry (`notes.md`;
    // `secret.txt` is filtered out by `text/markdown`).
    print("qemu: sendkey up")
    sleep(until: Clock.monotonic() + 200_000_000)
    let openQ = PromptQuestion(choosing: false, id: 0, asker: "tracker-test", app: "", types: ["text/markdown"], view: 1)
    let openLayout = PromptLayout(openQ, screenWidth: sw, screenHeight: sh)
    let openBtn = openLayout.buttons[openLayout.buttons.count - 1]
    check(click(ns, openBtn.x + openBtn.width / 2, openBtn.y + openBtn.height / 2), "click Open on the prompt")
    let openOk = waitChosen(&loop, wid, seconds: 10)
    check(openOk == true, "the window hears chosen(true)")
    if let h = loop.takeChosen(wid) {
      var file = FsIPC.FileClient(channel: h)
      let bytes = (try? file.readAll()) ?? []
      check(bytes == Array("# notes\n".utf8), "the chosen file's channel reads notes.md")
      check((try? file.write(Array("no".utf8), at: 0)) == nil, "an open chooser's channel is read-only")
      let escaped = (try? file.node { (n: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        _ = try n.run([.walk(names: [".."])])
      }) != nil
      check(!escaped, "the chosen file's channel cannot walk ..")
    } else {
      check(false, "takeChosen returns the file handle")
    }
    _ = within(10) { numbers(ns, "prompts").first == 0 }

    // 2. Save file chooser (`save: true`, pre-filled name `saved.txt`).
    check((try? loop.choose(wid, save: true, types: ["text/plain"], name: "saved.txt")) != nil,
          "window.choose(save) starts a save prompt")
    check(within(10) {
      numbers(ns, "prompts").first == 1 && (ns.readText("/svc/tracker/status") ?? "").contains("chooser ")
    }, "the save prompt is on screen")
    sleep(until: Clock.monotonic() + 600_000_000)
    let saveQ = PromptQuestion(choosing: true, id: 0, asker: "tracker-test", app: "", types: ["text/plain"], view: 1)
    let saveLayout = PromptLayout(saveQ, screenWidth: sw, screenHeight: sh)
    let saveBtn = saveLayout.buttons[saveLayout.buttons.count - 1]
    check(click(ns, saveBtn.x + saveBtn.width / 2, saveBtn.y + saveBtn.height / 2), "click Save on the prompt")
    let saveOk = waitChosen(&loop, wid, seconds: 10)
    check(saveOk == true, "the window hears chosen(true) for save")
    if let h = loop.takeChosen(wid) {
      var file = FsIPC.FileClient(channel: h)
      check((try? file.write(Array("saved via chooser\n".utf8), at: 0)) != nil, "the save channel is writable")
    } else {
      check(false, "takeChosen returns the save handle")
    }
    check(ns.readText("/data/saved.txt") == "saved via chooser\n", "saved.txt holds what was written")
    _ = within(10) { numbers(ns, "prompts").first == 0 }

    // 3. Cancel file chooser with Escape.
    check((try? loop.choose(wid, save: false, types: [], name: "")) != nil, "a third chooser prompt")
    check(within(10) {
      numbers(ns, "prompts").first == 1 && (ns.readText("/svc/tracker/status") ?? "").contains("chooser ")
    }, "the third prompt is on screen")
    sleep(until: Clock.monotonic() + 600_000_000)
    print("qemu: sendkey esc")
    check(waitChosen(&loop, wid, seconds: 10) == false && loop.takeChosen(wid) == nil,
          "Escape cancels the chooser and gives no handle")
    _ = within(10) { numbers(ns, "prompts").first == 0 }

    // 4. Plumber ports: `folder` opens a folder window, `find` opens a query window.
    _ = try? volume.makeFolder(in: "", named: "home")
    check((try? loop.route(RouteMessage(src: "tracker-test", wdir: "/data", type: "folder", data: "/data/home"))) != nil,
          "plumb /data/home to folder")
    check(within(10) { (ns.readText("/svc/windows/list") ?? "").contains(" home\n") },
          "Tracker opens home's folder window")
    check((try? loop.route(RouteMessage(src: "tracker-test", wdir: "/data", type: "tracker/find", data: "find"))) != nil,
          "plumb tracker/find to find")
    check(within(10) { (ns.readText("/svc/windows/list") ?? "").contains(" Find · query\n") },
          "Tracker opens a Find query window")

    // 5. The 100k-entry warm listing check (`tracker.list_100k`), where timing is real.
    if Clock.timingIsReal, let raw = try? ns.connect("/data") {
      var data = FsIPC.DirectoryClient(channel: raw)
      if (try? data.makeDirectory("listing")) != nil, let dirRaw = try? data.walk(to: "listing") {
        var node = NodeIPC.NodeClient(channel: dirRaw)
        var made = 0
        while made < 100_000 {
          var ops: [NodeIPC.Op] = []
          for i in made..<Swift.min(made + 16, 100_000) {
            ops += [.create(name: "e\(i)", kind: .file), .walk(names: [".."])]
          }
          guard (try? node.run(ops)) != nil else { break }
          made += ops.count / 2
        }
        check(made == 100_000, "100k entries made for Tracker")
        func listAndSort() -> (count: Int, elapsed: Int64) {
          let t0 = Clock.monotonic()
          var folder = Folder(path: "listing", sort: SortOrder())
          guard var listing = try? volume.list("listing", columns: FolderState.defaultColumns) else { return (-1, 0) }
          while !listing.done {
            guard let batch = try? listing.next() else { return (-1, 0) }
            folder.add(batch)
          }
          let n = folder.ordered().count
          return (n, Clock.monotonic() - t0)
        }
        _ = listAndSort()  // cold: builds the wholeListing VMO
        let warm = listAndSort()
        check(warm.count == 100_000, "Tracker lists and sorts 100k entries warm (\(warm.elapsed / 1_000_000) ms)")
        print("tracker-test: budget name=tracker.list_100k value=\(warm.elapsed) unit=ns limit=100000000")
      } else {
        check(false, "a directory for the 100k listing")
      }
    }

    loop.closeWindow(wid)
    print(failures == 0 ? "tracker-test: passed" : "tracker-test: \(failures) failed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
