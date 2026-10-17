// SPDX-License-Identifier: BSD-3-Clause

// man, lookman and sig over a manual served by a NodeTree at /lib/man.

import Commands
import Glibc
import IPC
import Node
import Testing

final class ManualRig: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let ns = Namespace()
  var thread = pthread_t()

  static let index = """
    name\tpage\tsection\tnode\tsummary\tkeys
    ls\tls\t1\t\tlist contents of directory\tdirectory files
    lc\tls\t1\t\tlist contents of directory\tdirectory files
    close\thandle\t2\t\thandles and their objects\t
    Handle.close\thandle\t2\t\thandles and their objects\t
    flags\tls\t1\tflags\tThe flags\t

    """
  static let ls = """
    page ls 1
    summary list contents of directory
    names ls lc

    # SYNOPSIS

    ```usage
    ls [-d] [file ...]
    ```

    # DESCRIPTION

    Lists.

    @node flags The flags

    ## Short ones

    : `-d`
      Itself.

    """
  static let handle = """
    page handle 2
    summary handles and their objects
    names close Handle.close
    lang swift

    # SYNOPSIS

    ```swift
    public func close(_ h: UInt32)
    public struct Handle { public consuming func close() }
    ```

    # DESCRIPTION

    Closing.

    """

  init() throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    tree.file("index", Array(Self.index.utf8))
    tree.file("1/ls", Array(Self.ls.utf8))
    tree.file("2/handle", Array(Self.handle.utf8))
    pthread_create(&thread, nil, { arg in
      let r = Unmanaged<ManualRig>.fromOpaque(arg!).takeUnretainedValue()
      try? r.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try ns.mount(ends.a, at: "/lib/man", create: true)
  }

  func run(_ name: String, _ args: String...) -> Commands.Result { Commands.run(name, args, pwd: "/", in: ns) }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

@Test func manPrintsAPageByAnyOfItsNames() throws {
  let rig = try ManualRig()
  defer { rig.stop() }
  let r = rig.run("man", "lc")
  #expect(r.status == "" && r.errors.isEmpty)
  #expect(text(r).hasPrefix("LS(1)"))
  #expect(text(r).contains("NAME\n     ls, lc — list contents of directory\n"))
  #expect(text(rig.run("man", "1", "ls", "flags")).hasPrefix("THE FLAGS\n"))
  #expect(text(rig.run("man", "-w", "ls")) == "/lib/man/1/ls\n")
  #expect(text(rig.run("man", "-t", "ls")) == "SYNOPSIS\nDESCRIPTION\nflags  The flags\n        Short ones\n")
}

@Test func manSaysWhatItCantFind() throws {
  let rig = try ManualRig()
  defer { rig.stop() }
  let none = rig.run("man", "2", "ls")
  #expect(none.status == "no manual page for ls" && none.errors == ["man: no manual page for ls"])
  #expect(rig.run("man", "ls", "nodes").status == "ls(1): no node 'nodes'")
  let bad = rig.run("man", "-x", "ls")
  #expect(bad.status == "usage" && bad.errors == ["usage: man [-tw] [section ...] title [node]"])
}

@Test func lookmanMatchesEveryKeyAsAWord() throws {
  let rig = try ManualRig()
  defer { rig.stop() }
  #expect(text(rig.run("lookman", "Directory", "list")) == "man 1 ls # list contents of directory\n")
  #expect(text(rig.run("lookman", "handles")) == "man 2 handle # handles and their objects\n")
  #expect(rig.run("lookman", "dir").status == "no match")
}

@Test func sigPrintsDeclarationsFromTheSynopsis() throws {
  let rig = try ManualRig()
  defer { rig.stop() }
  #expect(text(rig.run("sig", "close")) == """
    public func close(_ h: UInt32)
    public struct Handle { public consuming func close() }

    """)
  let missing = rig.run("sig", "ls")
  #expect(missing.status == "no declaration" && missing.errors == ["sig: no declaration of ls"])
}
