// SPDX-License-Identifier: BSD-3-Clause

// bin/master-stack (D116): the first layout for Radharc's `tile`
// workspaces, a process (D92) that registers a `Layout` channel at
// /svc/windows/layout and answers Radharc's calls with MasterStack's
// frames. It holds no state, so restarting it loses nothing. When Radharc
// closes the channel (it restarted), this ends with a failure, and the
// launcher starts it again to register anew.

import IPC
import Node
import Radharc
import Sys

func fail(_ what: String) -> Never {
  print("master-stack: \(what)")
  Process.exit(code: 2)
}

struct LayoutSession: RadharcIPC.LayoutHandler {
  func name() -> String { MasterStack.name }

  func arrange(area: RadharcIPC.Area, windows: [UInt32], focused: UInt32, params: String) -> [RadharcIPC.Area] {
    let a = Frame(x: Int(area.x), y: Int(area.y), width: Int(area.width), height: Int(area.height))
    return MasterStack.arrange(a, count: windows.count, MasterStack.Params(params)).map {
      RadharcIPC.Area(x: Int32($0.x), y: Int32($0.y), width: Int32($0.width), height: Int32($0.height))
    }
  }

  func act(verb: String, windows: [UInt32], focused: UInt32, params: String) throws(RadharcIPC.WindowError)
    -> RadharcIPC.LayoutChange
  {
    guard let r = MasterStack.act(verb, windows: windows, focused: focused, MasterStack.Params(params)) else {
      throw .invalid
    }
    return RadharcIPC.LayoutChange(order: r.order, focused: r.focused, params: r.params.text)
  }
}

@main struct MasterStackService {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    guard let ch = try? ns.connect("/svc/windows/layout") else {
      fail("no /svc/windows/layout (its manifest's `grant windows layout`)")
    }
    guard let pair = try? Channel.create() else { fail("no channel") }
    var provider = RadharcIPC.LayoutProviderClient(channel: ch)
    do throws(IPCError<Never>) { try provider.register(layout: pair.a) } catch { fail("Radharc refused it") }
    print("master-stack: registered")
    var server = RadharcIPC.LayoutServer(channel: pair.b, impl: LayoutSession())
    try? server.serve()
    fail("Radharc closed its channel")
  }
}
