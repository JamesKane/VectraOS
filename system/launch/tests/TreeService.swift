// SPDX-License-Identifier: BSD-3-Clause

// A service for the launcher's tests, hosted (LaunchTests' `tree`) and
// natively (bin/launch-service), that serves a tree about itself:
// - `status`: its arguments, its name first;
// - `ns`: its namespace's mount points;
// - `svc`: what its /svc lists;
// - `peer`: the text at the path its second argument names, read through
//   its namespace each time;
// - `utc`: the UTC pages it was given (hosted: natively the floor maps
//   the one to read): `read` for argument 0, `write` for 1, with `!` if
//   the rights aren't those;
// - `ctl`: `exit CODE` ends it; `post NAME` posts its tree to /srv.
// Bytes, not String comparisons: tier 0 has no Unicode tables.

import IPC
import Node
import Sys

/// `text`'s words, split at spaces and newlines.
func testWords(_ text: String) -> [String] {
  var out: [String] = [], word: [UInt8] = []
  for b in text.utf8 {
    if b == 0x20 || b == 0x0A {
      if !word.isEmpty { out.append(String(decoding: word, as: UTF8.self)) }
      word = []
    } else {
      word.append(b)
    }
  }
  if !word.isEmpty { out.append(String(decoding: word, as: UTF8.self)) }
  return out
}

/// Whether `s` is `literal`, as bytes.
func testIs(_ s: String, _ literal: StaticString) -> Bool {
  unsafe s.utf8.elementsEqual(UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
}

/// A decimal number, if `s` is one.
func testNumber(_ s: String) -> Int64? {
  var n: Int64 = 0
  for b in s.utf8 {
    guard b >= 0x30, b <= 0x39 else { return nil }
    n = n * 10 + Int64(b - 0x30)
  }
  return s.utf8.isEmpty ? nil : n
}

/// The board, once asked for.
final class TreeBoard: @unchecked Sendable { var client: SrvIPC.BoardClient? }

/// Serves the tree on its export until it's told to exit; 99 if it can't.
func treeService(_ start: Startup) -> Never {
  do throws(Status) {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.exit(code: 98) }
    let args = start.args
    let dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher)
    let board = TreeBoard()
    board.client = start.board()
    var utc: [String] = []
    for (argument, wanted) in [(UInt32(0), false), (1, true)] {
      guard let page = start.take(HandleType.info(HandleType.vmoUTC, argument)) else { continue }
      let writable = ((try? page.info().rights) ?? []).contains(.write)
      utc.append((argument == 0 ? "read" : "write") + (writable == wanted ? "" : "!"))
    }
    let pages = utc.joined(separator: " ") + "\n"
    tree.text("utc", read: { pages })
    tree.text("status", read: { args.joined(separator: " ") + "\n" })
    tree.text("ns", read: { ns.mountPoints.joined(separator: " ") + "\n" })
    // Its environment (D81): `env` reads $GREETING from its /env, `newenv`
    // a variable written into a group /svc/env's `new` makes.
    tree.text("env", read: { (ns.getenv("GREETING") ?? "none") + "\n" })
    tree.text("newenv", read: {
      guard var group = try? ns.open("/svc/env/new"), var x = try? group.create("x", kind: .file, in: "") else {
        return "no /svc/env\n"
      }
      _ = try? x.write(offset: 0, Array("one\0two\0".utf8))
      guard var again = try? group.open("x"), let bytes = try? again.readAll() else { return "unread\n" }
      return String(decoding: bytes.map { $0 == 0 ? UInt8(ascii: "|") : $0 }, as: UTF8.self) + "\n"
    })
    tree.text("svc", read: { ((try? ns.list("/svc").map { $0.name }) ?? []).joined(separator: " ") + "\n" })
    tree.text("peer", read: {
      guard args.count > 1 else { return "" }
      do throws(NamespaceError) {
        var c = try ns.open(args[1])
        return (try? c.readText()) ?? "error reading\n"
      } catch {
        return "error opening\n"
      }
    })
    tree.text("ctl", read: { "" }, write: { command throws(NodeError) in
      let words = testWords(command)
      if words.count == 2, testIs(words[0], "exit"), let code = testNumber(words[1]) { Process.exit(code: code) }
      guard words.count == 2, testIs(words[0], "post"), board.client != nil else { throw .invalid }
      do throws(Status) {
        let ends = try Channel.create()
        try tree.serve(ends.b)
        try? board.client!.post(words[1], ends.a)
      } catch {
        throw .io
      }
    })
    guard let export = start.export() else { Process.exit(code: 97) }
    try tree.serve(export)
    try dispatcher.run()
  } catch {
    Process.exit(code: 99)
  }
  Process.exit(code: 0)
}
