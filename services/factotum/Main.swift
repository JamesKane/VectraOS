// SPDX-License-Identifier: BSD-3-Clause

// bin/factotum (D75): every key, and the authentication protocols run
// for the services that use it, which get results and never a key
// (factotum(4)). Its manifest says `export per-client`: the launcher
// alone reaches its own tree, whose `clients` node opens a tree for each
// service that uses it, scoped by that service's `grant factotum` lines.
// It is headless: nothing asks the user, so a session that would ask is
// refused (D75), and keys it makes (noise-ik's, ed25519's) come from the
// kernel's CPRNG and last one boot.

import Factotum
import IPC
import Node
import Sys

func fail(_ what: String) -> Never {
  print("factotum: \(what)")
  Process.exit(code: 1)
}

func random(_ n: Int) -> [UInt8] {
  do throws(Status) { return try CPRNG.draw(count: n) } catch { fail("no random bytes") }
}

/// A SCRAM nonce: 24 characters from the CPRNG, none a comma.
func nonce() -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
  return String(decoding: random(24).map { alphabet[Int($0 & 63)] }, as: UTF8.self)
}

@main struct FactotumProgram {
  static func main() {
    let start = Startup.current
    guard start.args.count == 1 else { fail("usage: factotum") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let state = FactotumState(dispatcher: dispatcher, nonce: nonce, random: random)
    // No one to ask: each question is answered no as it comes.
    state.onQuestions = {
      for q in state.questions {
        switch q.question {
        case .confirm: state.answer(q.id, confirm: false)
        case .key: state.answer(q.id, user: nil, password: nil)
        }
      }
    }
    let tree = NodeTree(dispatcher: dispatcher)
    tree.service("clients") { (channel: consuming Handle) throws(Status) in try state.serveClients(channel) }
    tree.text("status", read: { "keys \(state.listing.utf8.split(separator: 0x0A).count)\n" })
    do throws(Status) {
      guard let export = start.export() else { fail("no export (its manifest's `export per-client`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error)")
    }
  }
}
