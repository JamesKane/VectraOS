// SPDX-License-Identifier: BSD-3-Clause

// The launcher (N0e): manifests and their errors, processes with only what
// their manifests grant (their Startup, D65), restarts and reconnecting,
// /srv. bin/launch-test checks the same natively.

import IPC
import Launch
import Node
import Testing

/// A program that serves a tree about itself (TreeService.swift).
let treeProgram = ProgramEntry { start in treeService(start) }

/// A program that exits at once with the code its argument gives.
let exiter = ProgramEntry { start in
  let args = start.args
  Process.exit(code: args.count > 1 ? Int64(args[1]) ?? 0 : 0)
}

let programs = [("tree", treeProgram), ("exiter", exiter)]

func launcher() throws -> Launcher { try Launcher(programs: programs, rootJob: try Job.root()) }

func read(_ l: Launcher, _ service: String, _ leaf: String) throws -> String {
  var root = try l.open(service)
  var c = try root.open(leaf)
  return try c.readText()
}

/// Waits until the launcher's status has `line`.
func waitFor(_ l: Launcher, _ line: String, ms: Int = 3000) -> Bool {
  for _ in 0..<(ms / 5) {
    if l.status.split(separator: "\n").contains(where: { $0 == line }) { return true }
    sleep(until: Clock.monotonic() + 5_000_000)
  }
  return false
}

func launchError(_ files: [(String, String)]) -> String {
  do {
    let l = try launcher()
    defer { l.stop() }
    try l.start(files.map { (path: $0.0, text: $0.1) })
    return "started"
  } catch {
    return "\(error)"
  }
}

@Test func manifestsFailLoudlyWithTheirLine() {
  let ok = "service a\nprogram tree\nexport\n"
  #expect(launchError([("a.m", "service a\nprogram tree\nbogus 1\n")]) == "a.m:3: unknown directive 'bogus'")
  #expect(launchError([("a.m", "# comment\nprogram tree\n")]) == "a.m:2: 'service' must come first")
  #expect(launchError([("a.m", "service a\n")]) == "a.m: no 'program'")
  #expect(launchError([("a.m", "service a\nprogram tree\nrestart sometimes\n")])
    == "a.m:3: 'restart' takes never, on-failure or always")
  #expect(launchError([("a.m", "service a\nprogram tree\nexport now\n")]) == "a.m:3: 'export' takes 0 arguments")
  #expect(launchError([("a.m", "service a\nprogram tree\nmount data a\n")]) == "a.m:3: bad path 'data'")
  #expect(launchError([("a.m", "service a\nprogram tree\nmount /data a sideways\n")])
    == "a.m:3: unknown mount option 'sideways'")
  #expect(launchError([("a.m", "service a\nprogram nothing\n")]) == "a.m:2: no program 'nothing'")
  #expect(launchError([("a.m", ok), ("b.m", "service b\nprogram tree\n\nuse block\n")]) == "b.m:4: no service 'block'")
  #expect(launchError([("a.m", "service a\nprogram tree\n"), ("b.m", "service b\nprogram tree\nuse a\n")])
    == "b.m:3: service 'a' exports nothing")
  #expect(launchError([("a.m", ok), ("a2.m", "# again\nservice a\nprogram tree\n")])
    == "a2.m:2: service 'a' is also defined at a.m:1")
  #expect(launchError([("a.m", ok + "use b\n"), ("b.m", "service b\nprogram tree\nexport\nuse a\n")])
    == "a.m:1: services depend on each other: a → b → a")
  #expect(launchError([("a.m", "service a\nprogram tree\nseal\n")]) == "a.m:3: unknown directive 'seal'")
}

@Test func processesGetWhatTheirManifestsGrantAndNothingElse() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\narg hello there\n"),
    ("b.m", "service b\nprogram tree\nexport\nuse a\narg /svc/a/status\n"),
    ("c.m", "service c\nprogram tree\nexport\n"),
    ("d.m", "service d  # mounts a's tree directly\nprogram tree\nexport\nmount /data a\narg /data/status\n"),
  ])
  #expect(try read(l, "a", "status") == "a hello there\n")
  #expect(try read(l, "b", "peer") == "a hello there\n")
  #expect(try read(l, "b", "ns") == "/env /svc\n")
  #expect(try read(l, "b", "svc") == "a\n")  // only what it uses
  #expect(try read(l, "c", "ns") == "/env\n")
  #expect(try read(l, "d", "peer") == "a hello there\n")
  #expect(try read(l, "d", "ns") == "/data /env\n")
  #expect(l.status == "a running restarts 0\nb running restarts 0\nc running restarts 0\nd running restarts 0\n")
}

@Test func mountsKeepTheirPlacesInAUnion() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\narg from-a\n"),
    ("b.m", "service b\nprogram tree\nexport\narg from-b\n"),
    ("u.m", "service u\nprogram tree\nexport\nmount /u a\nmount /u b before\narg /u/status\n"),
  ])
  #expect(try read(l, "u", "peer") == "b from-b\n")  // b's, mounted before a's
  #expect(try read(l, "u", "ns") == "/env /u\n")
}

@Test func aRestartedServiceIsReachedAgainThroughSvc() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\nrestart always\narg first\n"),
    ("b.m", "service b\nprogram tree\nexport\nuse a\narg /svc/a/status\n"),
  ])
  #expect(try read(l, "b", "peer") == "a first\n")
  var held = try l.open("a")
  var ctl = try held.open("ctl")
  _ = try? ctl.writeText("exit 3")  // the reply never comes: it has ended
  #expect(waitFor(l, "a running restarts 1"))
  // A channel to the old instance is closed; b's next open reaches the new one.
  var closed = false
  do throws(NodeIPC.NodeClient.Failure) { _ = try held.stat(fields: 0) } catch {
    if case .transport(.peerClosed) = error { closed = true }
  }
  #expect(closed)
  #expect(try read(l, "b", "peer") == "a first\n")
}

@Test func useAsNamesTheServiceInSvcAndFollowsItsRestarts() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\nrestart always\narg first\n"),
    ("b.m", "service b\nprogram tree\nexport\nuse a as display\narg /svc/display/status\n"),
  ])
  #expect(try read(l, "b", "svc") == "display\n")
  #expect(try read(l, "b", "peer") == "a first\n")
  var held = try l.open("a")
  var ctl = try held.open("ctl")
  _ = try? ctl.writeText("exit 3")
  #expect(waitFor(l, "a running restarts 1"))
  #expect(try read(l, "b", "peer") == "a first\n")
  #expect(launchError([("a.m", "service a\nprogram tree\nexport\n"), ("b.m", "service b\nprogram tree\nuse a as\n")])
    == "b.m:3: 'use' takes a service, and 'as NAME'")
  #expect(launchError([("a.m", "service a\nprogram tree\nexport\n"),
                       ("b.m", "service b\nprogram tree\nuse a\nuse a as a\n")]) == "b.m:4: a second /svc/a")
  #expect(launchError([("a.m", "service a\nprogram tree\nexport\n"),
                       ("b.m", "service b\nprogram tree\nuse a as launcher\n")]) == "b.m:3: bad name 'launcher'")
}

@Test func theLauncherDirectiveGrantsItsTreeAndKills() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\nrestart on-failure\n"),
    ("b.m", "service b\nprogram tree\nexport\nlauncher\narg /svc/launcher/status\n"),
  ])
  #expect(try read(l, "b", "svc") == "launcher\n")
  #expect(try read(l, "b", "peer") == "a running restarts 0\nb running restarts 0\n")
  // The launcher's ctl, as b reaches it: `kill` ends a as a crash would.
  var root = NodeIPC.NodeClient(channel: try l.controlChannel())
  var ctl = try root.open("ctl")
  try ctl.writeText("kill a")
  #expect(waitFor(l, "a running restarts 1"))
  var bad = false
  do throws(NodeIPC.NodeClient.Failure) { try ctl.writeText("kill nobody") } catch { bad = true }
  #expect(bad)
}

@Test func restartPoliciesAreFollowed() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("n.m", "service n\nprogram exiter\nrestart never\narg 3\n"),
    ("z.m", "service z\nprogram exiter\nrestart on-failure\narg 0\n"),
    ("f.m", "service f\nprogram exiter\nrestart on-failure\narg 4\n"),
  ])
  #expect(waitFor(l, "n exited 3 restarts 0"))
  #expect(waitFor(l, "z exited 0 restarts 0"))
  // A service that fails at once, again and again, is given up on.
  #expect(waitFor(l, "f failed (restarted 5 times in 30 s) restarts \(Launcher.maxRestarts)"))
}

@Test func programsFindEachOtherOnSrv() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("p.m", "service p\nprogram tree\nexport\nsrv\n"),
    ("q.m", "service q\nprogram tree\nexport\nsrv\narg /srv/editor/status\n"),
  ])
  var p = try l.open("p")
  var ctl = try p.open("ctl")
  try ctl.writeText("post editor")
  #expect(try read(l, "q", "peer") == "p\n")
  #expect(try read(l, "q", "ns") == "/env /srv\n")
}

/// `resource`, `programs` and `bootdata` (M3g) grant only what the
/// launcher was allowed: hosted it has none unless a test gives it a
/// stand-in.
@Test func hardwareGrantsNeedTheLaunchersOwn() throws {
  #expect(launchError([("d.m", "service d\nprogram tree\nresource mmio\nexport\n")])
    == "d.m:3: no 'mmio' resource to grant")
  #expect(launchError([("d.m", "service d\nprogram tree\nexport\nprograms\n")]) == "d.m:4: no bootfs to grant")
  #expect(launchError([("d.m", "service d\nprogram tree\nbootdata\n")]) == "d.m:3: no boot data to grant")
  let l = try launcher()
  defer { l.stop() }
  l.allow(resource: .mmio, try Counter.create())
  l.allow(bootfs: try VMO.create(size: 4096))
  l.allow(bootData: try VMO.create(size: 4096))
  try l.start([(path: "d.m", text: "service d\nprogram tree\nresource mmio\nprograms\nbootdata\nexport\n")])
  #expect(waitFor(l, "d running restarts 0"))
}

/// `early` services start before the rest, whatever the files' order.
@Test func earlyServicesStartFirst() throws {
  let manifests = try [("a.m", "service a\nprogram tree\nexport\n"), ("b.m", "service b\nprogram tree\nuse a\n"),
                       ("c.m", "service c\nprogram tree\nearly\n")].map { try Manifest(file: $0.0, text: $0.1) }
  #expect(try launchOrder(manifests, programs: ["tree"]).map { $0.service } == ["c", "a", "b"])
}

/// The UTC page (D48): every process is given it to read, and one whose
/// manifest says `clock` writable too; a launcher without one refuses
/// `clock`.
@Test func everyProcessReadsUTCAndClockWritesIt() throws {
  #expect(launchError([("t.m", "service t\nprogram tree\nclock\n")]) == "t.m:3: no UTC page to grant")
  let l = try launcher()
  defer { l.stop() }
  l.allow(utcPage: try VMO.create(size: 4096))
  try l.start([
    ("t.m", "service t\nprogram tree\nexport\nclock\n"),
    ("a.m", "service a\nprogram tree\nexport\n"),
  ])
  #expect(try read(l, "t", "utc") == "read write\n")
  #expect(try read(l, "a", "utc") == "read\n")
  // Without a page, nothing.
  let bare = try launcher()
  defer { bare.stop() }
  try bare.start([("a.m", "service a\nprogram tree\nexport\n")])
  #expect(try read(bare, "a", "utc") == "\n")
}

/// The environment (D81): each service's /env from its manifest's `env`
/// lines, a group of its own; `use env`'s /svc/env/new makes another, and
/// a group goes when its last channel closes; `env` is the launcher's.
@Test func everyServiceHasItsOwnEnvironment() throws {
  let l = try launcher()
  defer { l.stop() }
  try l.start([
    ("a.m", "service a\nprogram tree\nexport\nenv GREETING=hello\n"),
    ("b.m", "service b\nprogram tree\nexport\nuse env\n"),
  ])
  #expect(try read(l, "a", "env") == "hello\n")
  #expect(try read(l, "b", "env") == "none\n")  // its own group, not a's
  #expect(try read(l, "b", "newenv") == "one|two|\n")
  #expect(try read(l, "a", "newenv") == "no /svc/env\n")  // not granted
  // Each service's group, and the one newenv made has gone with its channels.
  let deadline = Clock.monotonic() + 2_000_000_000
  while l.env.count != 2 && Clock.monotonic() < deadline { sleep(until: Clock.monotonic() + 5_000_000) }
  #expect(l.env.count == 2)
  #expect(launchError([("e.m", "service env\nprogram tree\n")]) == "e.m:1: 'env' is the launcher's, not a service")
  #expect(launchError([("f.m", "service f\nprogram tree\nmount /e env\n")]) == "f.m:3: env is granted with `use env`")
}
