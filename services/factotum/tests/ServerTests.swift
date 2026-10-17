// SPDX-License-Identifier: BSD-3-Clause

// The keyring served (M6k part k4c), over the hosted kernel's channels:
// trees opened per client (as the launcher opens them) with their scope
// and `admin`'s ctl, a SCRAM exchange between two apps' sessions, a
// `pass` session that waits on the prompt and hears `answered`, a denial,
// a key typed into the prompt, and a session's question gone with it.

import IPC
@testable import Keyring
import Launch
import Node
import Sys
import Synchronization
import Testing

final class Rig {
  let dispatcher: IPCDispatcher
  let state: KeyringState
  var thread: Handle?

  init() throws {
    dispatcher = try IPCDispatcher()
    var n = 0
    state = KeyringState(dispatcher: dispatcher, nonce: {
      n += 1
      return "nonce\(n)"
    })
    let d = dispatcher
    thread = try Thread.spawn { try? d.run() }
  }

  /// `client`'s tree, as the launcher opens it.
  func tree(_ client: String, _ grants: [String]) throws -> NodeIPC.NodeClient {
    let c = try Channel.create(), node = try Channel.create()
    try state.serveClients(c.b)
    var clients = LaunchIPC.ClientsClient(channel: c.a)
    try clients.open(client: client, grants: grants, node: node.b)
    return NodeIPC.NodeClient(channel: node.a)
  }

  func keyring(_ tree: inout NodeIPC.NodeClient) throws -> AuthIPC.KeyringClient {
    AuthIPC.KeyringClient(channel: try tree.open("keyring").takeChannel())
  }

  func session(_ k: inout AuthIPC.KeyringClient, _ pattern: String, _ role: AuthIPC.Role = .client) throws
    -> AuthIPC.AuthSessionClient
  {
    let ends = try Channel.create()
    try k.startSession(pattern: pattern, role: role, session: ends.b)
    return AuthIPC.AuthSessionClient(channel: ends.a)
  }

  func stop() throws {
    dispatcher.stop()
    if let t = thread.take() { try Thread.join(t) }
  }
}

/// Waits for the session's `answered` event.
func answered(_ s: inout AuthIPC.AuthSessionClient) -> Bool {
  guard case .answered? = try? s.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else { return false }
  return true
}

/// Waits until the prompt has `n` questions.
func questions(_ state: KeyringState, _ n: Int) -> [(id: UInt64, question: Question)] {
  for _ in 0..<400 {
    let q = state.questions
    if q.count == n { return q }
    sleep(until: Clock.monotonic() + 5_000_000)
  }
  return state.questions
}

@Test func twoAppsAuthenticateThroughTheirTrees() throws {
  let rig = try Rig()
  var admin = try rig.tree("db", ["admin", "proto=scram-sha-256 server=db"])
  var ctl = try admin.open("ctl")
  try ctl.writeText("key proto=scram-sha-256 role=server server=db user=u !password=pw salt=c2FsdA== i=4096")
  try ctl.writeText("key proto=scram-sha-256 server=db user=u !password=pw")
  #expect(try ctl.readText() == """
    key proto=scram-sha-256 role=server server=db user=u !password? salt=c2FsdA== i=4096
    key proto=scram-sha-256 server=db user=u !password?

    """)
  var client = try rig.tree("psql", ["proto=scram-sha-256 server=db"])
  // A tree without `admin` has no ctl.
  #expect(throws: NodeIPC.NodeClient.Failure.self) { _ = try client.open("ctl") }
  var ck = try rig.keyring(&client), sk = try rig.keyring(&admin)
  var c = try rig.session(&ck, "proto=scram-sha-256 server=db")
  var s = try rig.session(&sk, "proto=scram-sha-256 server=db", .server)
  #expect(try s.next().kind == .need)
  let first = try c.next()
  #expect(first.kind == .send)
  try s.feed(first.bytes)
  let serverFirst = try s.next()
  try c.feed(serverFirst.bytes)
  let final = try c.next()
  try s.feed(final.bytes)
  let serverFinal = try s.next()
  #expect(try s.next() == AuthIPC.Step(kind: .done, bytes: [], text: "", user: "u", peer: "db", secret: []))
  try c.feed(serverFinal.bytes)
  #expect(try c.next().kind == .done)
  // Outside its scope.
  var k2 = try rig.keyring(&client)
  let e = try Channel.create()
  do throws(IPCError<AuthIPC.AuthError>) {
    try k2.startSession(pattern: "proto=scram-sha-256 server=elsewhere", role: .client, session: e.b)
    Issue.record("started outside its scope")
  } catch .remote(.notAllowed) {
  } catch {
    Issue.record("\(error)")
  }
  try rig.stop()
}

@Test func thePromptAnswersAndTheAppHears() throws {
  let rig = try Rig()
  var admin = try rig.tree("keys", ["admin"])
  var ctl = try admin.open("ctl")
  try ctl.writeText("key proto=pass server=mail user=jk !password=secret")
  var mail = try rig.tree("mail", [])
  var k = try rig.keyring(&mail)
  // Allowed: the password, after the yes.
  var s = try rig.session(&k, "proto=pass server=mail")
  let ask = try s.next()
  #expect(ask.kind == .needConfirm && ask.text == "mail wants to use the key proto=pass server=mail user=jk !password?")
  let q = questions(rig.state, 1)
  #expect(q.first?.question == .confirm(app: "mail", key: "proto=pass server=mail user=jk !password?"))
  rig.state.answer(q[0].id, confirm: true)
  let heard1 = answered(&s)
  #expect(heard1)
  #expect(try s.next() == AuthIPC.Step(kind: .done, bytes: [], text: "", user: "jk", peer: "mail",
                                        secret: Array("secret".utf8)))
  #expect(questions(rig.state, 0).isEmpty)
  // Denied.
  var no = try rig.session(&k, "proto=pass server=mail")
  _ = try no.next()
  rig.state.answer(questions(rig.state, 1)[0].id, confirm: false)
  let heard2 = answered(&no)
  #expect(heard2)
  do {
    _ = try no.next()
    Issue.record("not denied")
  } catch .remote(.denied) {
  } catch {
    Issue.record("\(error)")
  }
  // A key typed into the prompt.
  var typed = try rig.session(&k, "proto=pass server=news")
  let need = try typed.next()
  #expect(need.kind == .needKey && need.text == "proto=pass server=news")
  #expect(questions(rig.state, 1).first?.question == .key(app: "mail", pattern: "proto=pass server=news"))
  rig.state.answer(questions(rig.state, 1)[0].id, user: "reader", password: "hunter2")
  let heard3 = answered(&typed)
  #expect(heard3)
  #expect(try typed.next().kind == .needConfirm)  // pass asks before revealing it
  rig.state.answer(questions(rig.state, 1)[0].id, confirm: true)
  let heard4 = answered(&typed)
  #expect(heard4)
  #expect(try typed.next().secret == Array("hunter2".utf8))
  #expect(rig.state.listing.contains("key proto=pass server=news user=reader !password?"))
  // A session that goes while asking takes its question with it.
  var gone = try rig.session(&k, "proto=pass server=mail")
  _ = try gone.next()
  #expect(questions(rig.state, 1).count == 1)
  _ = consume gone
  #expect(questions(rig.state, 0).isEmpty)
  try rig.stop()
}

@Test func aMalformedGrantIsRefused() throws {
  let rig = try Rig()
  do {
    _ = try rig.tree("bad", ["proto=pass 'unfinished"])
    Issue.record("opened")
  } catch {}
  try rig.stop()
}
