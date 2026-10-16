// SPDX-License-Identifier: BSD-3-Clause

// The launcher (architecture §3): reads manifests, makes a job and a
// process per service, builds each process's namespace from what its
// manifest grants and nothing else, passes handles in, and restarts
// services by their manifests' policies.
//
// A process's start is its Startup (D65): its namespace as PA_NS_DIR
// handles named in the names table, its export's server end, the board,
// and what `resource`, `programs` and `bootdata` grant. An exporting
// service is ready when it answers on its export.
//
// A process's /svc is a tree the launcher serves for it, holding only the
// services it was granted. Each name there forwards to the service's
// current instance, so after a restart a client reconnects by opening the
// path again. Restarts happen on a supervisor thread, never the
// dispatcher's: a restart waits on the restarting service, which needs the
// dispatcher to answer for its /svc.

import IPC
import Node

public final class Launcher: @unchecked Sendable {
  /// The channel to a running service's tree, used one caller at a time,
  /// each call bounded by `readyTimeout` (a hung service can't hang the
  /// launcher).
  final class Export: @unchecked Sendable {
    let mutex = Lock()
    var client: NodeIPC.NodeClient

    init(_ channel: consuming Handle) {
      client = NodeIPC.NodeClient(channel: channel)
      client.connection.timeout = Launcher.readyTimeout
    }

    /// A new channel to the node `names` below the service's root.
    func open(_ names: [String]) throws(NodeIPC.NodeClient.Failure) -> Handle {
      mutex.lock()
      defer { mutex.unlock() }
      return try client.open(names.joined(separator: "/")).takeChannel()
    }
  }

  /// A service and its current instance.
  final class Service: @unchecked Sendable {
    let manifest: Manifest
    let index: Int
    var job: Handle
    var process: Handle?
    var export: Export?
    /// Its /svc tree, if it uses any service.
    var svc: NodeTree?
    /// The /svc trees of the services that use it, and its name there, to
    /// remount after a restart.
    var usedBy: [(svc: NodeTree, name: String)] = []
    var state = "not started"
    var instances = 0
    var restarts: [Int64] = []

    /// The current instance's return code, once it has ended.
    func returnCode() -> Int64? {
      guard let raw = process?.raw else { return nil }
      let p = Handle(raw: raw)  // borrowed: `process` still owns it
      let info = try? Process.info(p)
      _ = p.release()
      return info?.returnCode
    }

    init(_ manifest: Manifest, index: Int, job: consuming Handle) {
      self.manifest = manifest
      self.index = index
      self.job = job
    }
  }

  /// A restart storm ends here: this many in `restartWindow`, and the
  /// service is left down.
  public static let maxRestarts = 5
  public static let restartWindow: Int64 = 30_000_000_000
  /// How long an exporting service has to answer on its export.
  public static let readyTimeout: Int64 = 5_000_000_000

  /// What a manifest's `program` may name (no hashed collections in tier 0).
  let programs: [(name: String, entry: ProgramEntry)]
  let dispatcher: IPCDispatcher
  let job: Handle
  let supervisor: Handle
  /// The session's /srv.
  public let board: SrvBoard
  /// The launcher's own tree: `status`.
  public let tree: NodeTree
  var statusNode: TreeNode?
  /// What `launcher` grants: `status`, and `ctl` (`kill SERVICE`), on a
  /// dispatcher and thread of its own, made when first granted (a /svc
  /// tree forwards walks to it from the launcher's dispatcher, which can't
  /// wait on itself).
  var control: (dispatcher: IPCDispatcher, tree: NodeTree, nodes: [TreeNode], thread: UInt32)?
  let mutex = Lock()
  var services: [Service] = []
  var stopping = false
  /// What `resource`, `programs` and `bootdata` grant (natively, from
  /// userboot), as raw handles the launcher owns: `allow` them before
  /// `start`.
  var grantableResources: [(kind: ResourceKind, handle: UInt32)] = []
  var grantableBootfs: UInt32 = 0
  var grantableBootData: UInt32 = 0
  /// The UTC page (D48): every process is given it to read, a `clock`
  /// service writable.
  var utcPage: UInt32 = 0
  /// The launcher's two threads (raw handles; 0 if not started).
  var dispatcherThread: UInt32 = 0
  var supervisorThread: UInt32 = 0
  var running = false

  public init(programs: [(name: String, entry: ProgramEntry)], rootJob: borrowing Handle) throws(Status) {
    self.programs = programs
    dispatcher = try IPCDispatcher()
    job = try Job.create(parent: rootJob)
    supervisor = try Port.create()
    board = SrvBoard(dispatcher: dispatcher)
    tree = NodeTree(dispatcher: dispatcher)
    // A strong capture (Embedded Swift has no unowned): stop() removes the
    // leaf, which ends the cycle.
    statusNode = tree.text("status", read: { [self] in status })
  }

  deinit {
    for r in grantableResources { close(raw: r.handle) }
    if grantableBootfs != 0 { close(raw: grantableBootfs) }
    if grantableBootData != 0 { close(raw: grantableBootData) }
    if utcPage != 0 { close(raw: utcPage) }
  }

  /// A resource that manifests may grant with `resource KIND`.
  public func allow(resource kind: ResourceKind, _ handle: consuming Handle) {
    let raw = handle.release()
    locked { grantableResources.append((kind, raw)) }
  }

  /// The bootfs that manifests may grant with `programs`.
  public func allow(bootfs: consuming Handle) {
    let raw = bootfs.release()
    locked { grantableBootfs = raw }
  }

  /// The boot data that manifests may grant with `bootdata`.
  public func allow(bootData: consuming Handle) {
    let raw = bootData.release()
    locked { grantableBootData = raw }
  }

  /// The UTC page (D48), which every process is given to read and one whose
  /// manifest says `clock`, to write.
  public func allow(utcPage: consuming Handle) {
    let raw = utcPage.release()
    locked { self.utcPage = raw }
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    mutex.lock()
    defer { mutex.unlock() }
    return try body()
  }

  /// One line a service: its name, state and restart count.
  public var status: String {
    locked {
      services.map { "\($0.manifest.service) \($0.state) restarts \($0.instances > 0 ? $0.instances - 1 : 0)\n" }
        .joined()
    }
  }

  // MARK: Starting

  /// Reads the manifests and starts every service, each after those it
  /// uses are ready. Any error stops the launch, with its file and line.
  public func start(_ files: [(path: String, text: String)]) throws(LaunchError) {
    var manifests: [Manifest] = []
    for f in files { manifests.append(try Manifest(file: f.path, text: f.text)) }
    let order = try launchOrder(manifests, programs: programs.map { $0.name })
    for m in manifests {
      for r in m.resources where !locked({ grantableResources.contains { $0.kind == r.kind } }) {
        throw m.error(r.line, "no '\(r.kind.name)' resource to grant")
      }
      if m.programsLine != 0 && locked({ grantableBootfs }) == 0 { throw m.error(m.programsLine, "no bootfs to grant") }
      if m.librariesLine != 0 && locked({ grantableBootfs }) == 0 { throw m.error(m.librariesLine, "no bootfs to grant") }
      if m.bootfsLine != 0 && locked({ grantableBootfs }) == 0 { throw m.error(m.bootfsLine, "no bootfs to grant") }
      if m.bootDataLine != 0 && locked({ grantableBootData }) == 0 {
        throw m.error(m.bootDataLine, "no boot data to grant")
      }
      if m.clockLine != 0 && locked({ utcPage }) == 0 { throw m.error(m.clockLine, "no UTC page to grant") }
    }
    startThreads()
    for m in order {
      let service: Service
      do throws(Status) {
        service = Service(m, index: services.count, job: try Job.create(parent: job))
        // Named after its service (not every kernel can).
        try? service.job.setName(m.service)
      } catch {
        throw LaunchError("\(m.file): can't make a job: \(error.rawValue)")
      }
      locked { services.append(service) }
      if m.grants.contains(where: { $0.viaSvc }) || m.launcherLine != 0 { try buildSvc(service) }
      try launch(service)
    }
  }

  func startThreads() {
    guard !running else { return }
    running = true
    dispatcherThread = (try? Thread.spawn { [self] in try? dispatcher.run() })?.release() ?? 0
    supervisorThread = (try? Thread.spawn { [self] in supervise() })?.release() ?? 0
  }

  /// The service a manifest names.
  func service(_ name: String) -> Service? { locked { services.first { NodeIPC.same($0.manifest.service, name) } } }

  /// A service's /svc tree: a forwarding node for each service it uses.
  func buildSvc(_ s: Service) throws(LaunchError) {
    let svc = NodeTree(dispatcher: dispatcher)
    for g in s.manifest.grants where g.viaSvc {
      guard let target = service(g.service), let export = locked({ target.export }) else {
        throw s.manifest.error(g.line, "service '\(g.service)' isn't running")
      }
      do throws(NodeIPC.NodeClient.Failure) {
        svc.mount(g.name, try export.open([]), removeWhenGone: false)
      } catch {
        throw s.manifest.error(g.line, "service '\(g.service)' doesn't answer")
      }
      locked { target.usedBy.append((svc, g.name)) }
    }
    if s.manifest.launcherLine != 0 {
      do throws(Status) {
        svc.mount("launcher", try controlChannel(), removeWhenGone: false)
      } catch {
        throw s.manifest.error(s.manifest.launcherLine, "can't serve the launcher's tree: \(error.rawValue)")
      }
    }
    locked { s.svc = svc }
  }

  /// Starts an instance of `s`, and waits for it to answer on its export if
  /// it exports.
  func launch(_ s: Service) throws(LaunchError) {
    let m = s.manifest
    let failed = { (what: String) -> LaunchError in
      self.locked { s.state = "failed" }
      return LaunchError("\(m.file):\(m.serviceLine): can't start '\(m.service)': \(what)")
    }
    func sys<R: ~Copyable>(_ body: () throws(Status) -> R) throws(LaunchError) -> R {
      do throws(Status) { return try body() } catch { throw failed("\(error.rawValue)") }
    }
    // Its name first, as argv[0].
    let startup = Startup(args: [m.service] + m.args, environment: m.environment)
    var export: Export?
    if m.exports {
      let ends = try sys { () throws(Status) in try Channel.create() }
      startup.add(ends.b, info: HandleType.info(HandleType.export))
      export = Export(ends.a)
    }
    try mounts(for: s, into: startup)
    try granted(s, into: startup)
    let process = try sys { () throws(Status) in try Process.create(job: s.job, name: m.service) }
    guard let program = programs.first(where: { NodeIPC.same($0.name, m.program) }) else {
      throw failed("no program '\(m.program)'")
    }
    _ = try sys { () throws(Status) in try Process.start(process, entry: program.entry, startup) }
    // The instance is recorded before its end can be seen: one that ends
    // at once is the supervisor's to mark, not ours to call running.
    let raw = process.raw
    mutex.lock()
    s.instances += 1
    s.state = "starting"
    s.process = .some(process)
    s.export = export
    let instance = s.instances
    mutex.unlock()
    let borrowed = Handle(raw: raw)  // `s.process` owns it
    let bound = statusOf { () throws(Status) in
      try borrowed.bind(port: supervisor, key: UInt64(s.index + 1), signals: Signals.terminated)
    }
    _ = borrowed.release()
    guard bound == nil else { throw failed("\(bound!.rawValue)") }
    // Ready when it answers: the first open of its root (D65).
    var isReady = true
    if let export {
      do throws(NodeIPC.NodeClient.Failure) { _ = try export.open([]) } catch { isReady = false }
    }
    let users = locked { () -> [(svc: NodeTree, name: String)] in
      if s.instances == instance && s.process != nil { s.state = isReady ? "running" : "failed" }
      return s.usedBy
    }
    guard isReady else {
      throw LaunchError("\(m.file):\(m.serviceLine): service '\(m.service)' didn't answer on its export")
    }
    // Those using it reach the new instance from now on.
    guard let export else { return }
    for (svc, name) in users {
      if let channel = try? export.open([]) { svc.mount(name, channel, removeWhenGone: false) }
    }
  }

  /// The handles `resource`, `bootdata`, `programs`, `libraries` and
  /// `clock` grant an instance of `s`: duplicates of the launcher's, a new
  /// job under the service's, and the UTC page every process reads.
  func granted(_ s: Service, into startup: Startup) throws(LaunchError) {
    let m = s.manifest
    func duplicate(_ raw: UInt32, _ line: Int, _ rights: Rights = .sameRights) throws(LaunchError) -> UInt32 {
      let borrowed = Handle(raw: raw)  // the launcher still owns it
      let copy = try? borrowed.duplicate(rights).release()
      _ = borrowed.release()
      guard let copy else { throw m.error(line, "can't grant it") }
      return copy
    }
    for r in m.resources {
      let raw = locked { grantableResources.first { $0.kind == r.kind }!.handle }
      startup.add(raw: try duplicate(raw, r.line), info: HandleType.info(HandleType.resource(r.kind)))
    }
    if m.bootDataLine != 0 {
      startup.add(raw: try duplicate(locked({ grantableBootData }), m.bootDataLine),
                  info: HandleType.info(HandleType.vmoBootData))
    }
    // `programs`: bootfs and a job; `libraries`: bootfs, for dlopen's lib/;
    // `bootfs`: bootfs, to serve (once, whichever gave it).
    if m.programsLine != 0 || m.librariesLine != 0 || m.bootfsLine != 0 {
      startup.add(raw: try duplicate(locked({ grantableBootfs }), max(m.programsLine, m.librariesLine, m.bootfsLine)),
                  info: HandleType.info(HandleType.vmoBootfs))
    }
    if m.programsLine != 0 {
      do throws(Status) {
        startup.add(try Job.create(parent: s.job), info: HandleType.info(HandleType.jobDefault))
      } catch {
        throw m.error(m.programsLine, "can't make a job: \(error.rawValue)")
      }
    }
    // The UTC page: to read, and with `clock`, to write.
    let utc = locked { utcPage }
    if utc != 0 {
      startup.add(raw: try duplicate(utc, max(m.clockLine, m.serviceLine), [.read, .map, .transfer, .duplicate]),
                  info: HandleType.info(HandleType.vmoUTC, 0))
      if m.clockLine != 0 {
        startup.add(raw: try duplicate(utc, m.clockLine), info: HandleType.info(HandleType.vmoUTC, 1))
      }
    }
  }

  /// The namespace a manifest grants, in order: /svc (the services it uses),
  /// each mount, /srv (and the board to post to it).
  func mounts(for s: Service, into startup: Startup) throws(LaunchError) {
    let m = s.manifest
    if let svc = locked({ s.svc }) {
      do throws(Status) {
        let ends = try Channel.create()
        try svc.serve(ends.b)
        startup.mount(ends.a, at: "/svc")
      } catch {
        throw m.error(m.serviceLine, "can't serve /svc: \(error.rawValue)")
      }
    }
    for g in m.grants where !g.viaSvc {
      guard let target = service(g.service), let export = locked({ target.export }) else {
        throw m.error(g.line, "service '\(g.service)' isn't running")
      }
      do throws(NodeIPC.NodeClient.Failure) {
        guard g.subpath.count <= NodeIPC.maxWalk else { throw .remote(.tooManyNames) }
        startup.mount(try export.open(g.subpath), at: g.path, g.placement, create: g.create)
      } catch {
        throw m.error(g.line, "can't open '\(([g.service] + g.subpath).joined(separator: "/"))'")
      }
    }
    if m.srv {
      do throws(Status) {
        let node = try Channel.create()
        try board.serveNode(node.b)
        startup.mount(node.a, at: "/srv")
        let posting = try Channel.create()
        try board.serveBoard(posting.b)
        startup.add(posting.a, info: HandleType.info(HandleType.srvBoard))
      } catch {
        throw m.error(m.serviceLine, "can't serve /srv: \(error.rawValue)")
      }
    }
  }

  // MARK: Supervising

  /// Waits for services to exit and restarts them as their manifests say.
  func supervise() {
    while let packet = try? Port.wait(supervisor), packet.key != 0 {
      let s = locked { services[Int(packet.key) - 1] }
      let code = locked { s.returnCode() } ?? -1
      let restart = locked { () -> Bool in
        s.process = nil
        s.state = "exited \(code)"
        guard !stopping else { return false }
        switch s.manifest.restart {
        case .never: return false
        case .onFailure: if code == 0 { return false }
        case .always: break
        }
        let now = Clock.monotonic()
        s.restarts = s.restarts.filter { now - $0 < Self.restartWindow } + [now]
        if s.restarts.count > Self.maxRestarts {
          s.state = "failed (restarted \(Self.maxRestarts) times in \(Self.restartWindow / 1_000_000_000) s)"
          return false
        }
        return true
      }
      if restart { try? launch(s) }
    }
  }

  // MARK: Using it

  /// A new channel to the tree `launcher` grants, made the first time.
  public func controlChannel() throws(Status) -> Handle {
    let made = locked { () -> NodeTree? in control?.tree }
    let tree: NodeTree
    if let made {
      tree = made
    } else {
      let dispatcher = try IPCDispatcher()
      tree = NodeTree(dispatcher: dispatcher)
      // Strong captures (no unowned in tier 0): stop() removes the leaves.
      let nodes = [
        tree.text("status", read: { [self] in status }),
        tree.text("ctl", read: { "" }, write: { [self] text throws(NodeError) in
          let words = words(Array(text.utf8))
          guard words.count == 2, `is`(words[0], "kill") else { throw .invalid }
          do throws(LaunchError) { try kill(words[1]) } catch { throw .notFound }
        }),
      ]
      let thread = try Thread.spawn { try? dispatcher.run() }.release()
      locked { control = (dispatcher, tree, nodes, thread) }
    }
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return ends.a
  }

  /// A new channel to a running service's tree: for tests, which stand
  /// outside every namespace.
  public func open(_ service: String) throws(LaunchError) -> NodeIPC.NodeClient {
    NodeIPC.NodeClient(channel: try channel(to: service))
  }

  /// A channel to a running service's tree, to mount elsewhere.
  public func channel(to service: String) throws(LaunchError) -> Handle {
    guard let s = self.service(service), let export = locked({ s.export }) else {
      throw LaunchError("no running service '\(service)'")
    }
    do throws(NodeIPC.NodeClient.Failure) {
      return try export.open([])
    } catch {
      throw LaunchError("service '\(service)' doesn't answer")
    }
  }

  /// Waits until `service`'s current instance ends, and gives its return
  /// code: for a boot that runs a client to its end (the native launcher's
  /// `launcher.until=`).
  public func waitForExit(_ service: String) throws(LaunchError) -> Int64 {
    let found = locked { () -> (Service, UInt32, Int)? in
      guard let s = services.first(where: { NodeIPC.same($0.manifest.service, service) }), let raw = s.process?.raw
      else { return nil }
      let borrowed = Handle(raw: raw)  // `process` still owns it
      let copy = try? borrowed.duplicate()
      _ = borrowed.release()
      guard let copy else { return nil }
      return (s, copy.release(), s.instances)
    }
    guard let (s, raw, instance) = found else { throw LaunchError("no running service '\(service)'") }
    let p = Handle(raw: raw)
    let code: Int64
    do throws(Status) {
      _ = try p.wait(for: Signals.terminated)
      code = try Process.info(p).returnCode
    } catch {
      throw LaunchError("can't wait for '\(service)': \(error.rawValue)")
    }
    // Until the supervisor has seen it too (it has dropped the instance, or
    // started the next), so `status` says it ended.
    let deadline = Clock.monotonic() + 1_000_000_000
    while locked({ s.process != nil && s.instances == instance }), Clock.monotonic() < deadline {
      sleep(until: Clock.monotonic() + 1_000_000)
    }
    return code
  }

  /// Kills a running service's process, as a crash would end it: its
  /// manifest's restart policy decides what happens next.
  public func kill(_ service: String) throws(LaunchError) {
    let killed = locked { () -> Bool in
      guard let s = services.first(where: { NodeIPC.same($0.manifest.service, service) }), let raw = s.process?.raw
      else { return false }
      let p = Handle(raw: raw)  // borrowed: `process` still owns it
      let ok = (try? Sys.kill(p)) != nil
      _ = p.release()
      return ok
    }
    if !killed { throw LaunchError("no running service '\(service)'") }
  }

  /// Ends every service and the launcher's threads.
  public func stop() {
    locked { stopping = true }
    if let statusNode { tree.remove(statusNode) }
    statusNode = nil
    if let c = locked({ control }) {
      for n in c.nodes { c.tree.remove(n) }
      c.dispatcher.stop()
      try? Thread.join(Handle(raw: c.thread))
      c.dispatcher.removeAll()
      locked { control = nil }
    }
    try? Sys.kill(job)
    guard running else { return }
    try? Port.queue(supervisor, Packet(key: 0))
    if supervisorThread != 0 { try? Thread.join(Handle(raw: supervisorThread)) }
    dispatcher.stop()
    if dispatcherThread != 0 { try? Thread.join(Handle(raw: dispatcherThread)) }
    supervisorThread = 0
    dispatcherThread = 0
    dispatcher.removeAll()
    running = false
  }
}

/// The status `body` throws, or nil.
func statusOf(_ body: () throws(Status) -> Void) -> Status? {
  do throws(Status) {
    try body()
    return nil
  } catch {
    return error
  }
}
