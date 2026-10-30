// SPDX-License-Identifier: BSD-3-Clause

// bin/send [-i FROM] [-s SOURCE] SNAPSHOT TARGET (send(1), D153): copies a
// stream of a volume's snapshot, or of its changes since snapshot FROM,
// from fs's `send` (SOURCE, /svc/fs/send by default) to TARGET, another
// fs's `receive/<sys>`, most often through 9gate's import of a member's
// tree. A write of the names starts the stream; reads take it, in order,
// and each piece is written on at the same offset.

import IPC
import Node
import Sys

let usage = "usage: send [-i FROM] [-s SOURCE] SNAPSHOT TARGET"

/// A failure in Plan 9's words (Embedded Swift prints no enum).
func words(_ e: NodeIPC.NodeClient.Failure) -> String {
  switch e {
  case .remote(.notFound): "file does not exist"
  case .remote(.exists): "file already exists"
  case .remote(.invalid): "bad arg in system call"
  case .remote(.denied): "permission denied"
  case .remote(.isDirectory): "is a directory"
  case .remote(.unsupported): "operation not supported"
  case .remote: "i/o error"
  case .transport: "i/o on hungup channel"
  case .wire: "protocol error"
  }
}

@main struct SendProgram {
  static func main() {
    let start = Startup.current
    var args = start.args.dropFirst()
    var from: String?, source = "/svc/fs/send"
    var rest: [String] = []
    while let arg = args.popFirst() {
      if NodeIPC.same(arg, "-i") {
        guard let f = args.popFirst() else { Process.fail(usage) }
        from = f
      } else if NodeIPC.same(arg, "-s") {
        guard let s = args.popFirst() else { Process.fail(usage) }
        source = s
      } else {
        rest.append(arg)
      }
    }
    guard rest.count == 2 else { Process.fail(usage) }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    var src: NodeIPC.NodeClient
    do throws(NamespaceError) { src = try ns.open(source) } catch { Process.fail("can't open \(source)") }
    var spec = rest[0]
    if let from { spec = from + " " + spec }
    do throws(NodeIPC.NodeClient.Failure) {
      try src.write(offset: 0, Array(spec.utf8))
    } catch {
      Process.fail("\(source) won't send \(spec): \(words(error))")
    }
    var dst: NodeIPC.NodeClient
    do throws(NamespaceError) { dst = try ns.open(rest[1]) } catch { Process.fail("can't open \(rest[1])") }
    var at: UInt64 = 0
    while true {
      let bytes: [UInt8]
      do throws(NodeIPC.NodeClient.Failure) {
        bytes = try src.read(offset: at, max: UInt32(NodeIPC.maxIO))
      } catch {
        Process.fail("reading \(source): \(words(error))")
      }
      if bytes.isEmpty { break }
      do throws(NodeIPC.NodeClient.Failure) {
        try dst.write(offset: at, bytes)
      } catch {
        Process.fail("\(rest[1]) refused the stream at byte \(at): \(words(error))")
      }
      at += UInt64(bytes.count)
    }
    print("send: \(at) bytes")
  }
}
