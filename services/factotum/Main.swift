// SPDX-License-Identifier: BSD-3-Clause

// bin/factotum (D75): every key, and the authentication protocols run
// for the services that use it, which get results and never a key
// (factotum(4)). Its manifest says `export per-client`: the launcher
// alone reaches its own tree, whose `clients` node opens a tree for each
// service that uses it, scoped by that service's `grant factotum` lines.
// It asks the user on Radharc's trusted prompt (D111), `/svc/windows/
// prompt`, where the image has one (its manifest's `use windows
// optional`): a question a thread, which writes it, waits for the
// answer and gives it to the session. Without it, nothing asks the user,
// and a session that would ask is refused (D75). Keys it makes
// (noise-ik's, ed25519's) come from the kernel's CPRNG and last one boot.

import Factotum
import IPC
import NdbFile
import Node
import Sys

func random(_ n: Int) -> [UInt8] {
  do throws(Status) { return try CPRNG.draw(count: n) } catch { Process.fail("no random bytes") }
}

/// A SCRAM nonce: 24 characters from the CPRNG, none a comma.
func nonce() -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
  return String(decoding: random(24).map { alphabet[Int($0 & 63)] }, as: UTF8.self)
}

/// The image's keys, /lib/factotum/keys: a ctl line each, `#` lines and
/// blank ones skipped. A line refused is said, by its number only (it may
/// hold a secret), and the rest still load.
func loadKeys(_ ns: Namespace, into state: FactotumState) {
  var file: NodeIPC.NodeClient
  do throws(NamespaceError) { file = try ns.open("/lib/factotum/keys") } catch { Process.fail("no /lib/factotum/keys") }
  let text: String
  do throws(NodeIPC.NodeClient.Failure) { text = try file.readText() } catch { Process.fail("can't read /lib/factotum/keys") }
  var loaded = 0
  for (i, line) in text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
    guard let first = line.first(where: { $0 != 0x20 && $0 != 0x09 }), first != UInt8(ascii: "#") else { continue }
    do throws(KeyError) {
      _ = try state.control(String(decoding: line, as: UTF8.self))
      loaded += 1
    } catch {
      print("factotum: /lib/factotum/keys:\(i + 1): refused")
    }
  }
  if loaded > 0 { print("factotum: \(loaded) key\(loaded == 1 ? "" : "s") from /lib/factotum/keys") }
}

/// The questions being asked on the prompt, by their sessions' ids.
final class Asking: @unchecked Sendable {
  let lock = Lock()
  var ids: [UInt64] = []

  /// Whether `id` is new: then it is being asked.
  func start(_ id: UInt64) -> Bool {
    lock.withLock {
      guard !ids.contains(id) else { return false }
      ids.append(id)
      return true
    }
  }

  func done(_ id: UInt64) { lock.withLock { ids.removeAll { $0 == id } } }
}

/// The prompt's reply, an ndb entry.
func pairs(_ reply: [UInt8]) -> [NdbPair] {
  reply.split(separator: 0x0A).flatMap { parseLine(Array($0)) }
}

/// The value of `name=` among `pairs`.
func value(_ name: String, in pairs: [NdbPair]) -> String? {
  pairs.first { $0.attr.utf8.elementsEqual(name.utf8) }?.value
}

/// A key's or pattern's terms (rc-quoted, as factotum writes them) as the
/// prompt's ndb attributes: `name=value`, or `name?` for one to type.
func attributes(_ text: String, secrets: Bool) -> String {
  guard let pattern = try? KeyPattern(text) else { return "" }
  var out = ""
  for t in pattern.terms {
    if let v = t.value {
      out += " " + t.name + "=" + ndbQuoted(v)
    } else if secrets {
      out += " " + t.name + "?"
    }
  }
  return out
}

/// Asks `question` on the prompt and gives the session its answer: no, if
/// there is no prompt or it says deny. It is done asking first, as the
/// answer may lead the session to ask again.
func ask(_ ns: Namespace, _ id: UInt64, _ question: Question, _ state: FactotumState, _ asking: Asking) {
  var entry: String
  switch question {
  case .confirm(let app, let key):
    // What the key is, its secrets (shown as `!name?`) left out.
    entry = "ask=confirm app=" + ndbQuoted(app) + attributes(key, secrets: false)
  case .key(let app, let pattern):
    entry = "ask=key app=" + ndbQuoted(app) + attributes(pattern, secrets: true)
    if (try? KeyPattern(pattern))?.terms.contains(where: { $0.name.utf8.elementsEqual("user".utf8) }) != true {
      entry += " user?"
    }
    entry += " !password?"
  }
  var reply: [NdbPair] = []
  if var prompt = try? ns.open("/svc/windows/prompt"), (try? prompt.writeText(entry + "\n")) != nil,
    let bytes = try? prompt.read(offset: 0, max: 4096)
  {
    reply = pairs(bytes)
  }
  let yes = reply.first.map { $0.attr.utf8.elementsEqual("once".utf8) && $0.value.isEmpty } ?? false
  asking.done(id)
  switch question {
  case .confirm: state.answer(id, confirm: yes)
  case .key:
    if yes, let password = value("!password", in: reply) {
      state.answer(id, user: value("user", in: reply), password: password)
    } else {
      state.answer(id, user: nil, password: nil)
    }
  }
}

/// The lock screen's half that is factotum's (D118), for its status.
final class Unlocking: @unchecked Sendable {
  let lock = Lock()
  var following = false
  var unlocks = 0
  var wrong = 0
  var status: String {
    lock.withLock { "lock \(following ? "following" : "none") unlocks \(unlocks) wrong \(wrong)\n" }
  }
}

/// Radharc's `lock` (its manifest's `grant windows lock`), while there
/// is a login key: says it is ready to unlock, and each time the screen
/// is locked asks for the password on the prompt until it is the login
/// key's, then unlocks. Radharc restarted, it opens `lock` again.
func followLock(_ ns: Namespace, _ state: FactotumState, _ u: Unlocking) {
  guard let user = state.loginUser else { return }
  var misses = 0
  while misses < 120 {
    guard var lock = try? ns.open("/svc/windows/lock"), (try? lock.writeText("ready user=\(user)\n")) != nil else {
      misses += 1
      sleep(until: Clock.monotonic() + 500_000_000)
      continue
    }
    misses = 0
    u.lock.withLock { u.following = true }
    while let bytes = try? lock.read(offset: 0, max: 64), !bytes.isEmpty {
      guard bytes.starts(with: "locked".utf8) else { continue }
      var again = false
      while true {
        let entry = "ask=unlock user=" + ndbQuoted(user) + (again ? " again" : "") + " !password?\n"
        guard var prompt = try? ns.open("/svc/windows/prompt"), (try? prompt.writeText(entry)) != nil,
          let reply = try? prompt.read(offset: 0, max: 4096)
        else { break }
        let password = value("!password", in: pairs(reply)) ?? ""
        if state.checkLogin(password) {
          if (try? lock.writeText("unlock\n")) != nil { u.lock.withLock { u.unlocks += 1 } }
          break
        }
        u.lock.withLock { u.wrong += 1 }
        again = true
      }
    }
    u.lock.withLock { u.following = false }
  }
}

@main struct FactotumProgram {
  static func main() {
    let start = Startup.current
    guard start.args.count == 1 else { Process.fail("usage: factotum") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { Process.fail("can't make a dispatcher") }
    let state = FactotumState(dispatcher: dispatcher, nonce: nonce, random: random)
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    // Each question new, asked on a thread of its own; with no prompt, or
    // no thread, answered no.
    let asking = Asking()
    state.onQuestions = {
      for q in state.questions where asking.start(q.id) {
        let (id, question) = q
        do throws(Status) {
          _ = try Thread.spawn { ask(ns, id, question, state, asking) }
        } catch {
          asking.done(id)
          switch question {
          case .confirm: state.answer(id, confirm: false)
          case .key: state.answer(id, user: nil, password: nil)
          }
        }
      }
    }
    loadKeys(ns, into: state)
    let unlocking = Unlocking()
    _ = try? Thread.spawn { followLock(ns, state, unlocking) }
    let tree = NodeTree(dispatcher: dispatcher)
    tree.service("clients") { (channel: consuming Handle) throws(Status) in try state.serveClients(channel) }
    tree.text("status", read: {
      "keys \(state.listing.utf8.split(separator: 0x0A).count)\nlogin \(state.loginUser ?? "none")\n" + unlocking.status
    })
    do throws(Status) {
      guard let export = start.export() else { Process.fail("no export (its manifest's `export per-client`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error)")
    }
  }
}
