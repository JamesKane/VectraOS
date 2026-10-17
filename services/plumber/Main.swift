// SPDX-License-Identifier: BSD-3-Clause

// bin/plumber (V2 item 8, D85): Plan 9's plumber(4). Its tree, which
// manifests mount at /mnt/plumb:
//   send     write a plumb(6) message: routed by the rules to its port
//   rules    the rules in force; a write appends more
//   PORT     one for each port the rules name (`plumb to`): a read waits
//            for the next message (D84), each channel open on it its own copy
// With no reader on a message's port, a ruleset's `plumb client` starts
// its program (from /bin, under the job `programs` grants), the message
// held until the program opens the port, and `plumb start` starts it and
// drops the message; with neither, the write to send fails. A program it
// starts gets its tree at /mnt/plumb and its /bin. What it routes and
// refuses goes to its log.

import IPC
import Node
import Plumber
import Sys

func fail(_ what: String) -> Never {
  print("plumber: \(what)")
  Process.exit(code: 2)
}

@main struct PlumberService {
  static func main() {
    let start = Startup.current
    // The job `programs` grants, kept for the programs it starts.
    final class Owned { let job: Handle; init(_ job: consuming Handle) { self.job = job } }
    var job: Owned?
    if let j = start.take(HandleType.info(HandleType.jobDefault)) { job = Owned(j) }
    let owned = job
    let namespace: Namespace
    do throws(NamespaceError) { namespace = try Namespace(start) } catch { fail("no namespace") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)

    /// Starts `argv[0]` from /bin with the rest as its arguments.
    func run(_ argv: [String], _ wdir: String) -> String? {
      guard let owned else { return "no job to start programs in (its manifest's `programs`)" }
      do throws(Status) {
        let memory: NodeIPC.Memory
        do throws(NamespaceError) {
          memory = try namespace.memory("/bin/" + argv[0], executable: true)
        } catch {
          return "no /bin/\(argv[0])"
        }
        let process = try Process.create(job: owned.job, name: argv[0])
        let startup = Startup(args: argv)
        let ends = try Channel.create()
        try tree.serve(ends.b)
        startup.mount(ends.a, at: "/mnt/plumb")
        if let bin = try? namespace.connect("/bin") { startup.mount(bin, at: "/bin") }
        let entry = ProgramEntry(image: memory.vmo.raw, offset: 0, length: Int(memory.size), name: argv[0])
        _ = try Process.start(process, entry: entry, startup)
        _ = consume memory  // its VMO, until the program is loaded from it
        print("plumber: started \(argv.joined(separator: " ")) in \(wdir)")
        return nil
      } catch {
        return "status \(error.rawValue)"
      }
    }

    let plumber: Plumber
    do throws(RuleError) {
      plumber = try Plumber(rules: Rules.defaults, host: PlumberHost(start: run))
    } catch {
      fail("its own rules: \(error.description)")
    }

    var ports: [(name: String, node: TreeNode)] = []
    /// A port file for each port the rules name that has none yet.
    func addPorts() {
      for name in plumber.portNames where !ports.contains(where: { $0.name.utf8.elementsEqual(name.utf8) }) {
        let node = tree.stream(name, NodeStream(perChannel: {
          guard let reader = plumber.open(port: name) else { return NodeStreamChannel(take: { _ in [] }) }
          return NodeStreamChannel(take: { reader.take($0) }, closed: { plumber.close(reader, port: name) })
        }))
        ports.append((name, node))
      }
    }
    addPorts()

    tree.stream("send", NodeStream(take: { _ in [] }, write: { (data: [UInt8]) throws(NodeError) -> UInt32 in
      do throws(PlumbError) {
        let port = try plumber.send(data)
        print("plumber: \(port): \(data.count) bytes")
        if let node = ports.first(where: { $0.name.utf8.elementsEqual(port.utf8) })?.node { tree.ready(node) }
        return UInt32(data.count)
      } catch {
        print("plumber: refused: \(error.text)")
        switch error {
        case .badMessage: throw .invalid
        case .noRule: throw .notFound
        case .noReader, .startFailed: throw .io
        }
      }
    }))
    tree.text("rules", read: { plumber.rulesText }, write: { (text: String) throws(NodeError) in
      do throws(RuleError) {
        try plumber.append(rules: text)
        addPorts()
      } catch {
        print("plumber: rules refused: \(error.description)")
        throw .invalid
      }
    })

    guard let export = start.export() else { fail("no export (its manifest's `export`)") }
    do throws(Status) {
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error.rawValue)")
    }
  }
}
