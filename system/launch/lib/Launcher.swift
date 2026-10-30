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

import Directives
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
    /// remount after a restart; for a per-client service, the client and
    /// its grants, to open its tree again.
    var usedBy: [(svc: NodeTree, name: String, client: String, grants: [String])] = []
    /// Its mounts' forwarders, made at its first start: a node for each
    /// `mount` of a service, which its namespace reconnects through
    /// (PA_NS_RECONNECT) when that service restarts.
    var forwarders: NodeTree?
    /// The forwarders of the mounts of it, and the directory each opens,
    /// to point at the new instance after a restart.
    var mountedBy: [(tree: NodeTree, name: String, subpath: [String])] = []
    /// Its instance runs a pushed build.
    var pushed = false
    /// `restart` was asked for: the next end restarts it, whatever its
    /// policy, and isn't counted against it.
    var restartAsked = false
    /// `start` was asked for (an app, D114): the supervisor starts it.
    var startAsked = false
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
  /// The VMO the programs' entries borrow, held for as long as they are.
  let image: Handle?
  /// A pushed build of a program, looked for before bootfs's (push and
  /// run: the launcher's own `/dev/bin`, in a cpu image). Called on the
  /// thread that starts the service, never the dispatcher's.
  public var pushed: (@Sendable (String) -> ProgramEntry?)?
  /// Called with a service's name once it has answered on its export.
  public var readied: (@Sendable (String) -> Void)?
  /// A line for the log: a service that exited, and what was done.
  public var log: (@Sendable (String) -> Void)?
  let dispatcher: IPCDispatcher
  let job: Handle
  let supervisor: Handle
  /// The session's /srv.
  public let board: SrvBoard
  /// The launcher's own tree: `status`.
  public let tree: NodeTree
  /// The environment groups (D81): each service's /env, and /svc/env.
  public let env: EnvGroups
  var statusNode: TreeNode?
  /// What `launcher` grants: `status`, and `ctl` (`kill` and `restart SERVICE`), on a
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
  /// The system resource's tracing range, which `tracing` grants (D102).
  var grantableTracing: UInt32 = 0
  /// Its INFO range, which `info` grants (D114).
  var grantableInfo: UInt32 = 0
  /// Its VMEX range, which `reload` grants (D122): only in images that
  /// push, the development ones.
  var grantableReload: UInt32 = 0
  /// The debuglog's ring and doorbell, which `debuglog` grants (D38).
  var grantableDebuglog: (ring: UInt32, counter: UInt32) = (0, 0)
  /// The UTC page (D48): every process is given it to read, a `clock`
  /// service writable.
  var utcPage: UInt32 = 0
  /// What an instance of the named service is given beyond its manifest's
  /// grants, added to its Startup afresh for each instance: devmgr's for a
  /// driver host, its device's handles and the mounts its class needs
  /// (a keyboard's /dev/kbin, D83). Set before `start`.
  public var extraStartup: ((String, Startup) -> Void)?
  /// The launcher's two threads (raw handles; 0 if not started).
  var dispatcherThread: UInt32 = 0
  var supervisorThread: UInt32 = 0
  var running = false

  /// `image`, if given, is the VMO the programs' entries borrow (bootfs),
  /// held while the launcher lives, so a service restarts from it however
  /// long after.
  public init(programs: [(name: String, entry: ProgramEntry)], image: consuming Handle? = nil,
              rootJob: borrowing Handle) throws(Status) {
    self.programs = programs
    self.image = image
    dispatcher = try IPCDispatcher()
    job = try Job.create(parent: rootJob)
    supervisor = try Port.create()
    board = SrvBoard(dispatcher: dispatcher)
    env = try EnvGroups()
    tree = NodeTree(dispatcher: dispatcher)
    // A strong capture (Embedded Swift has no unowned): stop() removes the
    // leaf, which ends the cycle.
    statusNode = tree.text("status", read: { [self] in status })
  }

  deinit {
    for r in grantableResources { close(raw: r.handle) }
    if grantableBootfs != 0 { close(raw: grantableBootfs) }
    if grantableBootData != 0 { close(raw: grantableBootData) }
    if grantableTracing != 0 { close(raw: grantableTracing) }
    if grantableDebuglog.ring != 0 { close(raw: [grantableDebuglog.ring, grantableDebuglog.counter]) }
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

  /// The system resource's tracing range, which manifests may grant with
  /// `tracing` (proc(4)'s /proc/trace).
  public func allow(tracing: consuming Handle) {
    let raw = tracing.release()
    locked { grantableTracing = raw }
  }

  /// The system resource's INFO range, which manifests may grant with
  /// `info` (proc(4)'s /proc/cpu).
  public func allow(info: consuming Handle) {
    let raw = info.release()
    locked { grantableInfo = raw }
  }

  /// The system resource's VMEX range, which manifests may grant with
  /// `reload` (hot reload, D122).
  public func allow(reload: consuming Handle) {
    let raw = reload.release()
    locked { grantableReload = raw }
  }

  /// The debuglog's ring and its doorbell, which manifests may grant with
  /// `debuglog` (D38): reading it is holding them.
  public func allow(debuglog ring: consuming Handle, counter: consuming Handle) {
    let r = ring.release(), c = counter.release()
    locked { grantableDebuglog = (r, c) }
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
      services.map {
        "\($0.manifest.service) \($0.state) restarts \($0.instances > 0 ? $0.instances - 1 : 0)\($0.pushed ? " pushed" : "")\n"
      }
        .joined()
    }
  }

  /// One line an app (D114): its service, its name, whether it runs, and
  /// its kind (`SERVICE<TAB>NAME<TAB>running|stopped<TAB>app|preferences`).
  public var apps: String {
    locked {
      services.compactMap { s -> String? in
        guard let name = s.manifest.app else { return nil }
        return "\(s.manifest.service)\t\(name)\t\(s.process == nil ? "stopped" : "running")\t"
          + (s.manifest.preferences ? "preferences" : "app") + "\n"
      }
      .joined()
    }
  }

  /// What each service holds of memory (TASK_STATS, in bytes) with what it
  /// started (its job's tree: devmgr's driver hosts, the plumber's
  /// programs), a line each, `NAME processes N private P shared S scaled
  /// X`, then the launcher's own as `launcher`. The services' resident
  /// memory is the sum of their private and scaled-shared bytes (V2's
  /// exit: services.rss), so a page they share, such as bootfs's, counts
  /// once among them. Where the stats can't be read (hosted), none.
  public var memory: String {
    var lines = locked { () -> [String] in
      // A service in another's note group is counted once, as itself.
      let own = services.compactMap { s -> UInt64? in s.manifest.noteGroup.isEmpty ? nil : try? s.job.info().koid }
      return services.compactMap { s -> String? in
        let (processes, stats) = Self.memory(of: s.job, skipping: own)
        return processes > 0 ? Self.memoryLine(s.manifest.service, processes, stats) : nil
      }
    }
    if let me = try? Process.current(), let stats = try? Process.stats(me) {
      lines.append(Self.memoryLine("launcher", 1, stats))
    }
    return lines.joined()
  }

  /// The memory of `job`'s processes and of its child jobs' but those
  /// `skipping` names, summed; how many processes said.
  static func memory(of job: borrowing Handle, skipping: [UInt64] = []) -> (processes: Int, stats: TaskStats) {
    var sum = TaskStats(mapped: 0, privateBytes: 0, shared: 0, scaledShared: 0)
    var processes = 0
    func add(_ s: TaskStats) {
      sum.mapped += s.mapped
      sum.privateBytes += s.privateBytes
      sum.shared += s.shared
      sum.scaledShared += s.scaledShared
    }
    for koid in (try? Job.processes(job)) ?? [] {
      guard let p = try? job.child(koid), let s = try? Process.stats(p) else { continue }
      add(s)
      processes += 1
    }
    for koid in (try? Job.children(job)) ?? [] where !skipping.contains(koid) {
      guard let child = try? job.child(koid) else { continue }
      let (n, s) = memory(of: child, skipping: skipping)
      add(s)
      processes += n
    }
    return (processes, sum)
  }

  static func memoryLine(_ name: String, _ processes: Int, _ s: TaskStats) -> String {
    "\(name) processes \(processes) private \(s.privateBytes) shared \(s.shared) scaled \(s.scaledShared)\n"
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
      if m.debuglogLine != 0 && locked({ grantableDebuglog.ring }) == 0 {
        throw m.error(m.debuglogLine, "no debuglog to grant")
      }
      if m.clockLine != 0 && locked({ utcPage }) == 0 { throw m.error(m.clockLine, "no UTC page to grant") }
      if m.tracingLine != 0 && locked({ grantableTracing }) == 0 {
        throw m.error(m.tracingLine, "no tracing resource to grant")
      }
      if m.infoLine != 0 && locked({ grantableInfo }) == 0 { throw m.error(m.infoLine, "no info resource to grant") }
      if m.reloadLine != 0 && locked({ grantableReload }) == 0 {
        throw m.error(m.reloadLine, "no VMEX resource to grant (only images that push have one)")
      }
    }
    startThreads()
    for m in order {
      let service: Service
      do throws(Status) {
        // Under its note group's job (`notegroup`, started first), or the
        // launcher's.
        let group = locked { services.first { !m.noteGroup.isEmpty && NodeIPC.same($0.manifest.service, m.noteGroup) } }
        let made = if let group { try Job.create(parent: group.job) } else { try Job.create(parent: job) }
        service = Service(m, index: services.count, job: made)
        // Named after its service (not every kernel can).
        try? service.job.setName(m.service)
      } catch {
        throw LaunchError("\(m.file): can't make a job: \(error.rawValue)")
      }
      locked { services.append(service) }
      if m.grants.contains(where: { $0.viaSvc }) || m.launcherLine != 0 { try buildSvc(service) }
      // An app waits to be asked for.
      if m.app != nil {
        locked { service.state = "stopped" }
        continue
      }
      try launch(service)
    }
  }

  func startThreads() {
    guard !running else { return }
    running = true
    try? env.start()
    dispatcherThread = (try? Thread.spawn { [self] in try? dispatcher.run() })?.release() ?? 0
    supervisorThread = (try? Thread.spawn { [self] in supervise() })?.release() ?? 0
  }

  /// The service a manifest names.
  func service(_ name: String) -> Service? { locked { services.first { NodeIPC.same($0.manifest.service, name) } } }

  /// A per-client service's tree for `client`: its `clients` node serves
  /// it on a new channel, given `client`'s grants. nil if refused.
  static func clientTree(_ export: Export, client: String, grants: [String]) -> Handle? {
    guard let ch = try? export.open(["clients"]), let ends = try? Channel.create() else { return nil }
    var clients = LaunchIPC.ClientsClient(channel: ch)
    guard (try? clients.open(client: client, grants: grants, node: ends.b)) != nil else { return nil }
    return ends.a
  }

  /// A service's /svc tree: a forwarding node for each service it uses.
  func buildSvc(_ s: Service) throws(LaunchError) {
    let svc = NodeTree(dispatcher: dispatcher)
    for g in s.manifest.grants where g.viaSvc && !NodeIPC.same(g.service, "env") {
      guard let target = service(g.service), let export = locked({ target.export }) else {
        if g.optional {
          print("launcher: \(s.manifest.service): /svc/\(g.name) left out, no service '\(g.service)' running")
          continue
        }
        throw s.manifest.error(g.line, "service '\(g.service)' isn't running")
      }
      let grants = s.manifest.grantLines.filter { NodeIPC.same($0.service, g.service) }.map { $0.words }
      if target.manifest.perClient {
        guard let tree = Self.clientTree(export, client: s.manifest.service, grants: grants) else {
          if g.optional {
            print("launcher: \(s.manifest.service): /svc/\(g.name) left out, '\(g.service)' refused its tree")
            continue
          }
          throw s.manifest.error(g.line, "service '\(g.service)' refused this service's tree")
        }
        svc.mount(g.name, tree, removeWhenGone: false)
      } else {
        do throws(NodeIPC.NodeClient.Failure) {
          svc.mount(g.name, try export.open([]), removeWhenGone: false)
        } catch {
          throw s.manifest.error(g.line, "service '\(g.service)' doesn't answer")
        }
      }
      locked { target.usedBy.append((svc, g.name, s.manifest.service, grants)) }
    }
    // `use env`: the launcher's own (its `new`), not a service.
    for g in s.manifest.grants where g.viaSvc && NodeIPC.same(g.service, "env") {
      do throws(Status) {
        let ends = try Channel.create()
        try env.tree.serve(ends.b)
        svc.mount(g.name, ends.a, removeWhenGone: false)
      } catch {
        throw s.manifest.error(g.line, "can't serve /svc/\(g.name): \(error.rawValue)")
      }
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
    func sys<R: ~Copyable>(_ what: String, _ body: () throws(Status) -> R) throws(LaunchError) -> R {
      do throws(Status) { return try body() } catch { throw failed("\(what): \(error.rawValue)") }
    }
    // Its name first, as argv[0].
    // Its environment is its /env (D81), made from its manifest's `env`
    // lines; the Startup carries none.
    let startup = Startup(args: [m.service] + m.args)
    startup.mount(try sys("its /env") { () throws(Status) in try env.channel(EnvGroups.variables(m.environment)) }, at: "/env")
    var export: Export?
    if m.exports {
      let ends = try sys("its export") { () throws(Status) in try Channel.create() }
      startup.add(ends.b, info: HandleType.info(HandleType.export))
      export = Export(ends.a)
    }
    try mounts(for: s, into: startup)
    try granted(s, into: startup)
    extraStartup?(m.service, startup)
    let process = try sys("process_create") { () throws(Status) in try Process.create(job: s.job, name: m.service) }
    // A pushed build first, then bootfs's.
    let entry: ProgramEntry
    var fromPush = false
    if let p = pushed?(m.program) {
      entry = p
      fromPush = true
    } else if let program = programs.first(where: { NodeIPC.same($0.name, m.program) }) {
      entry = program.entry
    } else {
      throw failed("no program '\(m.program)'")
    }
    locked { s.pushed = fromPush }
    _ = try sys("process_start") { () throws(Status) in try Process.start(process, entry: entry, startup) }
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
    let users = locked { () -> [(svc: NodeTree, name: String, client: String, grants: [String])] in
      if !isReady, s.instances == instance && s.process != nil { s.state = "failed" }
      return s.usedBy
    }
    guard isReady else {
      throw LaunchError("\(m.file):\(m.serviceLine): service '\(m.service)' didn't answer on its export")
    }
    readied?(m.service)
    if let export {
      // Those using it reach the new instance from now on.
      for (svc, name, client, grants) in users {
        if m.perClient {
          if let tree = Self.clientTree(export, client: client, grants: grants) { svc.mount(name, tree, removeWhenGone: false) }
        } else if let channel = try? export.open([]) {
          svc.mount(name, channel, removeWhenGone: false)
        }
      }
      // And the namespaces that mount it reconnect to it.
      for (tree, name, subpath) in locked({ s.mountedBy }) {
        if let channel = try? export.open(subpath) { tree.mount(name, channel, removeWhenGone: false) }
      }
    }
    // Running once all of them reach it: a client that waits for `running`
    // in status finds its mounts on the new instance, not the one gone.
    locked { if s.instances == instance && s.process != nil { s.state = "running" } }
  }

  /// The handles `resource`, `bootdata`, `debuglog`, `programs`, `libraries` and
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
    if m.debuglogLine != 0 {
      let d = locked { grantableDebuglog }
      startup.add(raw: try duplicate(d.ring, m.debuglogLine), info: HandleType.info(HandleType.vmoDebuglog))
      startup.add(raw: try duplicate(d.counter, m.debuglogLine), info: HandleType.info(HandleType.debuglogCounter))
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
    // `jobs`: the launcher's own job, every service's and what each starts
    // under it (proc's, D79), as argument 1 of PA_JOB_DEFAULT.
    if m.jobsLine != 0 {
      startup.add(raw: try duplicate(job.raw, m.jobsLine), info: HandleType.info(HandleType.jobDefault, 1))
    }
    // `tracing`: the system resource's tracing range, as argument 1 of
    // PA_SYSTEM_RESOURCE (the whole range is argument 0).
    if m.tracingLine != 0 {
      startup.add(raw: try duplicate(locked({ grantableTracing }), m.tracingLine),
                  info: HandleType.info(HandleType.resource(.system), 1))
    }
    // `info`: the INFO range, as argument 2.
    if m.infoLine != 0 {
      startup.add(raw: try duplicate(locked({ grantableInfo }), m.infoLine),
                  info: HandleType.info(HandleType.resource(.system), 2))
    }
    // `reload`: the VMEX range, as argument 3.
    if m.reloadLine != 0 {
      startup.add(raw: try duplicate(locked({ grantableReload }), m.reloadLine),
                  info: HandleType.info(HandleType.resource(.system), 3))
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
    let forwarders = locked { () -> NodeTree in
      if let tree = s.forwarders { return tree }
      let tree = NodeTree(dispatcher: dispatcher)
      s.forwarders = tree
      return tree
    }
    for (i, g) in m.grants.enumerated() where !g.viaSvc {
      guard let target = service(g.service), let export = locked({ target.export }) else {
        throw m.error(g.line, "service '\(g.service)' isn't running")
      }
      let what = "can't open '\(([g.service] + g.subpath).joined(separator: "/"))'"
      guard g.subpath.count <= NodeIPC.maxWalk else { throw m.error(g.line, what) }
      // Its forwarder, made once and pointed at each new instance.
      let name = "\(i)"
      // Why an open failed (timed out, not found...) goes in the error.
      if forwarders.node(name) == nil {
        let channel: Handle
        do throws(NodeIPC.NodeClient.Failure) {
          channel = try export.open(g.subpath)
        } catch {
          if g.optional {
            print("launcher: \(m.service): \(g.path) left out, \(what): \(NamespaceError(error).text)")
            continue
          }
          throw m.error(g.line, what + ": " + NamespaceError(error).text)
        }
        forwarders.mount(name, channel, removeWhenGone: false)
        locked { target.mountedBy.append((forwarders, name, g.subpath)) }
      }
      guard let node = forwarders.node(name), let ends = try? Channel.create(),
        (try? forwarders.serve(ends.b, at: node)) != nil
      else {
        throw m.error(g.line, what)
      }
      let channel: Handle
      do throws(NodeIPC.NodeClient.Failure) {
        channel = try export.open(g.subpath)
      } catch {
        throw m.error(g.line, what + ": " + NamespaceError(error).text)
      }
      startup.mount(channel, at: g.path, g.placement, create: g.create, reconnect: ends.a)
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
    // Those whose restart failed, perhaps for a service they use that was
    // down too (cpu, whose net ended with it, its end seen first): each
    // tried again whenever another starts, until it does.
    var waiting: [Service] = []
    func retry() {
      var i = 0
      while i < waiting.count {
        let s = waiting[i]
        do throws(LaunchError) {
          try launch(s)
          waiting.remove(at: i)
          log?("\(s.manifest.service) restarted")
          i = 0  // what it serves may be what another waited for
        } catch {
          i += 1
        }
      }
    }
    while let packet = try? Port.wait(supervisor), packet.key != 0 {
      let s = locked { services[Int(packet.key) - 1] }
      // An app asked for: started, not an end. Asked stays set until it
      // has, so another `start` meanwhile queues nothing.
      if locked({ s.startAsked }) {
        do throws(LaunchError) {
          try launch(s)
          log?("\(s.manifest.service) started")
          retry()
        } catch {
          log?("\(s.manifest.service) didn't start: \(error.description)")
        }
        locked { s.startAsked = false }
        continue
      }
      let code = locked { s.returnCode() } ?? -1
      let restart = locked { () -> Bool in
        s.process = nil
        s.state = "exited \(code)"
        guard !stopping else { return false }
        if s.restartAsked {
          s.restartAsked = false
          return true
        }
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
      let name = s.manifest.service
      if !restart {
        log?("\(name) exited \(code)")
        continue
      }
      log?("\(name) exited \(code), restarted")
      do throws(LaunchError) {
        try launch(s)
        waiting.removeAll { $0 === s }
        retry()
      } catch {
        log?("\(name) didn't restart: \(error.description); tried again when another starts")
        if !waiting.contains(where: { $0 === s }) { waiting.append(s) }
      }
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
        tree.text("memory", read: { [self] in memory }),
        tree.text("apps", read: { [self] in apps }),
        tree.text("ctl", read: { "" }, write: { [self] text throws(NodeError) in
          // A command a line (echo's newline ends one).
          for line in Directives.lines(Array(text.utf8)) {
            let words = Directives.words(line)
            if words.isEmpty { continue }
            guard words.count == 2 else { throw .invalid }
            if `is`(words[0], "kill") {
              do throws(LaunchError) { try kill(words[1]) } catch { throw .notFound }
            } else if `is`(words[0], "restart") {
              do throws(LaunchError) { try restart(words[1]) } catch { throw .notFound }
            } else if `is`(words[0], "start") {
              do throws(LaunchError) { try start(words[1]) } catch { throw .notFound }
            } else {
              throw .invalid
            }
          }
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

  /// Starts app `service` if it isn't running (D114), on the supervisor's
  /// thread as a restart is; one already running is left as it is.
  public func start(_ service: String) throws(LaunchError) {
    let index = try locked { () throws(LaunchError) -> Int? in
      guard let s = services.first(where: { NodeIPC.same($0.manifest.service, service) && $0.manifest.app != nil }) else {
        throw LaunchError("no app '\(service)'")
      }
      guard s.process == nil, !s.startAsked else { return nil }
      s.startAsked = true
      return s.index
    }
    if let index { try? Port.queue(supervisor, Packet(key: UInt64(index + 1))) }
  }

  /// Starts a service again whatever its restart policy says, from a
  /// pushed build if there is one: a running one is killed first; one
  /// that has ended, or failed, starts now. Not counted against it.
  public func restart(_ service: String) throws(LaunchError) {
    let raw = try locked { () throws(LaunchError) -> UInt32? in
      guard let s = services.first(where: { NodeIPC.same($0.manifest.service, service) }) else {
        throw LaunchError("no service '\(service)'")
      }
      s.restartAsked = true
      return s.process?.raw
    }
    guard let s = self.service(service) else { return }
    if let raw {
      let p = Handle(raw: raw)  // borrowed: `process` still owns it
      _ = try? Sys.kill(p)
      _ = p.release()
    } else {
      // Not running: the supervisor starts it, as it would after an end.
      try? Port.queue(supervisor, Packet(key: UInt64(s.index + 1)))
    }
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
