// SPDX-License-Identifier: BSD-3-Clause

// A process's namespace (architecture §4): paths to Node channels. There is
// no global root: `/svc/<name>` holds the services a process was granted,
// `/data` its own directory, `/vol/<name>` the volumes it may see, `/srv`
// its session's board. Following Plan 9, a path can hold a union of
// channels, each mounted before, after or replacing what is there, one
// marked for creating in. Unions are resolved here, in the client.

import IPC

public enum NamespaceError: Error, Equatable, Sendable {
  /// A path that isn't absolute or holds a bad name.
  case badPath
  /// Nothing is mounted where the path leads.
  case notFound
  /// The namespace is sealed: it can't attach a new channel.
  case sealed
  /// A union holds at most `Namespace.maxUnion` channels.
  case unionFull
  /// No member of the union may be created in.
  case cantCreate
  /// The service answered with an error.
  case node(NodeIPC.NodeError)
  /// The channel failed.
  case transport(Status)
  /// The service broke the protocol.
  case wire(WireError)

  /// A Node client's failure, as a namespace says it.
  public init(_ e: NodeIPC.NodeClient.Failure) {
    switch e {
    case .remote(.notFound): self = .notFound
    case .remote(let n): self = .node(n)
    case .transport(let s): self = .transport(s)
    case .wire(let w): self = .wire(w)
    }
  }

  /// What went wrong, for a log line (Embedded Swift prints no enum).
  public var text: String {
    switch self {
    case .badPath: "bad path"
    case .notFound: "not found"
    case .sealed: "namespace sealed"
    case .unionFull: "union full"
    case .cantCreate: "can't create"
    case .node(let n): "node error \(n.rawValue)"
    case .transport(let s): s == .timedOut ? "timed out" : "transport status \(s.rawValue)"
    case .wire: "protocol error"
    }
  }
}

public final class Namespace: @unchecked Sendable {
  public enum Placement: Sendable {
    /// The new channel alone.
    case replace
    /// Looked in first.
    case before
    /// Looked in last.
    case after
  }

  /// One channel of a union: calls on it go one at a time.
  final class Member: @unchecked Sendable {
    let mutex = Lock()
    var client: NodeIPC.NodeClient
    let create: Bool
    /// The launcher's forwarder for a service's mount: a batch that walks
    /// nowhere and opens gives a channel to the service's current
    /// instance; one with no operations, another forwarder.
    var reconnect: NodeIPC.NodeClient?
    let reconnects: Bool
    /// Its files open as fids on its channel (node(5)'s, Plan 9's): the
    /// next fid's number, never reused, and whether its server keeps
    /// fids (until it says it doesn't).
    var nextFid: UInt32 = 1
    var keepsFids = true
    /// The fids closed and not yet let go: sent with its next fid request.
    let clunkLock = Lock()
    var clunks: [UInt32] = []

    init(_ client: consuming NodeIPC.NodeClient, create: Bool, reconnect: consuming NodeIPC.NodeClient? = nil) {
      self.client = client
      self.create = create
      reconnects = reconnect != nil
      self.reconnect = reconnect
    }

    /// `body` on the member's channel; if that channel has closed (its
    /// service ended) and the member can reconnect, once more on a new
    /// one to the service's current instance.
    func use<R: ~Copyable>(_ body: (inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) -> R)
      throws(NodeIPC.NodeClient.Failure) -> R
    {
      mutex.lock()
      defer { mutex.unlock() }
      do throws(NodeIPC.NodeClient.Failure) {
        return try body(&client)
      } catch {
        guard case .transport = error, reconnectLocked() else { throw error }
        return try body(&client)
      }
    }

    /// A new channel to the service's current instance, through the
    /// forwarder (under the lock).
    func reconnectLocked() -> Bool {
      guard reconnects else { return false }
      do throws(NodeIPC.NodeClient.Failure) {
        client = try NodeIPC.NodeClient(try reconnect!.run([.walk(names: [])], open: true))
        return true
      } catch {
        return false
      }
    }

    /// Another forwarder, for a child's member, if this one has one.
    func forwarder() throws(NodeIPC.NodeClient.Failure) -> Handle? {
      guard reconnects else { return nil }
      mutex.lock()
      defer { mutex.unlock() }
      return try NodeIPC.NodeClient(try reconnect!.run([], open: true)).takeChannel()
    }

    /// A new client at `names` below this member's node (none: a clone).
    func open(_ names: [String]) throws(NodeIPC.NodeClient.Failure) -> NodeIPC.NodeClient {
      try use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        try c.open(names.joined(separator: "/"))
      }
    }

    /// The fids closed since its last fid request.
    func takeClunks() -> [UInt32] {
      clunkLock.withLock {
        defer { clunks = [] }
        return clunks
      }
    }

    /// A fid closed: let go with the next request that can carry it.
    func clunk(_ fid: UInt32) { clunkLock.withLock { clunks.append(fid) } }

    /// The node at `names` open as a new fid, with its stat and first
    /// bytes; nil if the member's server keeps no fids.
    func openFid(_ names: [String], stat fields: UInt32, ahead: UInt32) throws(NodeIPC.NodeClient.Failure)
      -> (fid: UInt32, stat: NodeIPC.Stat, ahead: [UInt8]?)?
    {
      try use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        guard keepsFids else { return nil }
        let fid = nextFid
        nextFid &+= 1
        do throws(NodeIPC.NodeClient.Failure) {
          let (s, bytes) = try c.open(names: names, stat: fields, fid: fid, ahead: ahead,
                                      clunk: takeClunks())
          return (fid, s, bytes)
        } catch .remote(.unsupported) {
          keepsFids = false
          return nil
        }
      }
    }

    /// The same, with the node's stat from the same batch.
    func open(_ names: [String], stat fields: UInt32, ahead: UInt32) throws(NodeIPC.NodeClient.Failure)
      -> NodeIPC.NodeClient.Opened
    {
      try use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        try c.open(names: names, stat: fields, ahead: ahead)
      }
    }
  }

  /// A node open as a fid on its member's channel (`openFile`): its
  /// batches go on that channel, one at a time with the member's other
  /// calls, and its close (its deinit) goes with the member's next fid
  /// request. If the member's channel is made again (its service
  /// restarted), the fid fails as a closed channel does.
  public final class Fid: @unchecked Sendable {
    let member: Member
    let number: UInt32

    init(_ member: Member, _ number: UInt32) {
      self.member = member
      self.number = number
    }

    deinit { member.clunk(number) }

    /// Runs `ops` from the fid's node; with `open`, a channel to where
    /// they end (the fid made a channel, for a ring or another protocol).
    public func run(_ ops: [NodeIPC.Op], open: Bool = false) throws(NodeIPC.NodeClient.Failure)
      -> NodeIPC.NodeClient.Done
    {
      let number = self.number
      return try member.use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
        try c.run(fid: number, ops, open: open, clunk: member.takeClunks())
      }
    }
  }

  /// What `openFile` opened: a fid, or (`client`) a channel of its own.
  public struct OpenedFile: ~Copyable {
    public var client: NodeIPC.NodeClient?
    public let fid: Fid?
    public let stat: NodeIPC.Stat
    public let ahead: [UInt8]?

    /// Its channel, if it has one (outside this module, a field can't be
    /// taken alone).
    public consuming func takeClient() -> NodeIPC.NodeClient? { client }
  }

  /// A client of `channel`, if there is one.
  static func client(_ channel: consuming Handle?) -> NodeIPC.NodeClient? {
    switch consume channel {
    case .some(let c): NodeIPC.NodeClient(channel: c)
    case .none: nil
    }
  }

  /// Whether two paths have the same names, as bytes.
  func samePath(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { NodeIPC.same($0, $1) }
  }

  struct Mount {
    var path: [String]
    var members: [Member]
  }

  /// The most channels one union holds.
  public static let maxUnion = 8

  let mutex = Lock()
  var mounts: [Mount] = []
  public private(set) var sealed: Bool
  /// The libraries opened for programs started from here (D124): each
  /// VMO kept and lent again (a duplicate), so a shell starting command
  /// after command opens each library once, not an IPC each a start.
  /// bootfs's /lib doesn't change.
  let librariesLock = Lock()
  var opened: [(name: [UInt8], vmo: UInt32, size: UInt64)] = []

  public init(sealed: Bool = false) {
    self.sealed = sealed
  }

  deinit {
    for l in opened { _ = Handle(raw: l.vmo) }
  }

  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    mutex.lock()
    defer { mutex.unlock() }
    return try body()
  }

  /// A path's names, cleaned as Plan 9 does: "." dropped, ".." taking off
  /// the name before it (and nothing at the root).
  public static func clean(_ path: String) throws(NamespaceError) -> [String] {
    guard path.utf8.first == 0x2F else { throw .badPath }
    var names: [String] = []
    for part in NodeIPC.names(path) {
      let name = part
      if NodeIPC.same(name, ".") { continue }
      if NodeIPC.same(name, "..") {
        _ = names.popLast()
        continue
      }
      guard NodeIPC.isValidName(name) else { throw .badPath }
      names.append(name)
    }
    return names
  }

  /// Plan 9's cleanname: `path` with no `.`, doubled or trailing slash,
  /// and each `..` taking back the name before it (at the root, nothing;
  /// leading a relative path, kept). An empty relative path is `.`.
  public static func cleanname(_ path: String) -> String {
    let rooted = path.utf8.first == 0x2F
    var out: [Substring] = []
    for part in path.split(separator: "/") {
      if part == "." { continue }
      if part == ".." {
        if let last = out.last, last != ".." { out.removeLast() } else if !rooted { out.append(part) }
        continue
      }
      out.append(part)
    }
    let joined = out.joined(separator: "/")
    return rooted ? "/" + joined : (joined.isEmpty ? "." : joined)
  }

  // MARK: Changing it

  /// Seals the namespace: from now on it can't attach a channel received
  /// from elsewhere (`mount`), though it can still rearrange what it holds
  /// (`bind`). Children inherit the seal. Plan 9's RFNOMNT.
  public func seal() { locked { sealed = true } }

  /// Attaches `channel` (a Node channel) at `path`. `create` marks it as
  /// where new files go in a union. `reconnect`, the launcher's forwarder
  /// for a service's mount, gives a new channel once `channel` closes.
  public func mount(_ channel: consuming Handle, at path: String, _ placement: Placement = .replace,
                    create: Bool = false, reconnect: consuming Handle? = nil) throws(NamespaceError) {
    let names = try Self.clean(path)
    let forwarder = Self.client(reconnect)
    let member = Member(NodeIPC.NodeClient(channel: channel), create: create, reconnect: forwarder)
    try locked { () throws(NamespaceError) in
      guard !sealed else { throw .sealed }
      try add(member, at: names, placement)
    }
  }

  /// Binds what `source` names now at `path` too: Plan 9's bind. Allowed in
  /// a sealed namespace, since it attaches nothing new.
  public func bind(_ source: String, at path: String, _ placement: Placement = .replace,
                   create: Bool = false) throws(NamespaceError) {
    let names = try Self.clean(path)
    let member = Member(try open(source), create: create)
    try locked { () throws(NamespaceError) in try add(member, at: names, placement) }
  }

  /// Under the lock.
  func add(_ member: Member, at names: [String], _ placement: Placement) throws(NamespaceError) {
    guard let i = mounts.firstIndex(where: { samePath($0.path, names) }) else {
      mounts.append(Mount(path: names, members: [member]))
      return
    }
    switch placement {
    case .replace: mounts[i].members = [member]
    case .before, .after:
      guard mounts[i].members.count < Self.maxUnion else { throw .unionFull }
      if placement == .before { mounts[i].members.insert(member, at: 0) } else { mounts[i].members.append(member) }
    }
  }

  /// Takes away everything mounted at `path`.
  public func unmount(_ path: String) throws(NamespaceError) {
    let names = try Self.clean(path)
    try locked { () throws(NamespaceError) in
      guard let i = mounts.firstIndex(where: { samePath($0.path, names) }) else { throw .notFound }
      mounts.remove(at: i)
    }
  }

  /// The paths something is mounted at, sorted by their bytes.
  public var mountPoints: [String] {
    locked {
      mounts.map { "/" + $0.path.joined(separator: "/") }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
  }

  /// A namespace for a child: the same mounts, each a new channel to the
  /// same node (and a forwarder of its own, where one reconnects), sealed
  /// if this one is.
  public func clone() throws(NamespaceError) -> Namespace {
    let copy = Namespace(sealed: locked { sealed })
    for m in locked({ mounts }) {
      var members: [Member] = []
      for member in m.members {
        do throws(NodeIPC.NodeClient.Failure) {
          let forwarder = Self.client(try member.forwarder())
          members.append(Member(try member.open([]), create: member.create, reconnect: forwarder))
        } catch {
          throw NamespaceError(error)
        }
      }
      copy.mounts.append(Mount(path: m.path, members: members))
    }
    return copy
  }

  // MARK: Using it

  /// The mount `names` lead into (the longest mounted prefix) and the rest.
  func resolve(_ names: [String]) -> (members: [Member], rest: [String])? {
    locked {
      var best = -1
      for i in mounts.indices where mounts[i].path.count <= names.count
        && (best < 0 || mounts[i].path.count > mounts[best].path.count) && Self.leads(mounts[i].path, names)
      {
        best = i
      }
      guard best >= 0 else { return nil }
      return (mounts[best].members, Array(names.dropFirst(mounts[best].path.count)))
    }
  }

  /// Whether `names` start with `prefix`.
  static func leads(_ prefix: [String], _ names: [String]) -> Bool {
    for i in prefix.indices where !NodeIPC.same(prefix[i], names[i]) { return false }
    return true
  }

  /// Where `path` leads: the mount it falls in (its path, as "/a/b") and
  /// the names below it. Two paths in the same mount share its tree, so a
  /// rename between them is one call on the mount's directory.
  public func locate(_ path: String) throws(NamespaceError) -> (mount: String, rest: [String]) {
    let names = try Self.clean(path)
    return try locked { () throws(NamespaceError) -> (mount: String, rest: [String]) in
      var best: Mount?
      for m in mounts where m.path.count <= names.count && samePath(Array(names.prefix(m.path.count)), m.path) {
        if best == nil || m.path.count > best!.path.count { best = m }
      }
      guard let best else { throw .notFound }
      return ("/" + best.path.joined(separator: "/"), Array(names.dropFirst(best.path.count)))
    }
  }

  /// A channel to the service node at `path`, which speaks its typed
  /// protocol (`/svc/block/device`).
  public func connect(_ path: String) throws(NamespaceError) -> Handle {
    try open(path).takeChannel()
  }

  /// A channel to the node at `path`: from the first member of its union
  /// that has it.
  public func open(_ path: String) throws(NamespaceError) -> NodeIPC.NodeClient {
    let names = try Self.clean(path)
    guard let (members, rest) = resolve(names) else { throw .notFound }
    var failure = NamespaceError.notFound
    for member in members {
      do throws(NodeIPC.NodeClient.Failure) {
        return try member.open(rest)
      } catch {
        failure = NamespaceError(error)
        // A miss tries the next member; anything else is the answer.
        if failure != .notFound { throw failure }
      }
    }
    throw failure
  }

  /// `open`, with the node's stat (`fields`) from the same batch, and
  /// with `ahead`, up to that many of its first bytes from a server that
  /// gives them.
  public func open(_ path: String, stat fields: UInt32, ahead: UInt32 = 0) throws(NamespaceError)
    -> NodeIPC.NodeClient.Opened
  {
    let names = try Self.clean(path)
    guard let (members, rest) = resolve(names) else { throw .notFound }
    var failure = NamespaceError.notFound
    for member in members {
      do throws(NodeIPC.NodeClient.Failure) {
        return try member.open(rest, stat: fields, ahead: ahead)
      } catch {
        failure = NamespaceError(error)
        if failure != .notFound { throw failure }
      }
    }
    throw failure
  }

  /// `open(_:stat:ahead:)`, and with `fid`, the node kept as a fid on its
  /// member's channel where that member's server keeps fids: an open and
  /// a close cost the server no channel.
  public func openFile(_ path: String, stat fields: UInt32, ahead: UInt32 = 0, fid: Bool) throws(NamespaceError)
    -> OpenedFile
  {
    try openFile(names: try Self.clean(path), stat: fields, ahead: ahead, fid: fid)
  }

  /// `openFile` of a path already cleaned into its names (`clean`).
  public func openFile(names: [String], stat fields: UInt32, ahead: UInt32 = 0, fid: Bool) throws(NamespaceError)
    -> OpenedFile
  {
    guard let (members, rest) = resolve(names) else { throw .notFound }
    var failure = NamespaceError.notFound
    for member in members {
      do throws(NodeIPC.NodeClient.Failure) {
        if fid, let f = try member.openFid(rest, stat: fields, ahead: ahead) {
          return OpenedFile(client: nil, fid: Fid(member, f.fid), stat: f.stat, ahead: f.ahead)
        }
        let opened = try member.open(rest, stat: fields, ahead: ahead)
        let (stat, bytes) = (opened.stat, opened.ahead)
        return OpenedFile(client: opened.takeClient(), fid: nil, stat: stat, ahead: bytes)
      } catch {
        failure = NamespaceError(error)
        if failure != .notFound { throw failure }
      }
    }
    throw failure
  }

  /// The text of the file at `path` (a status, a list); nil if it can't
  /// be opened or read.
  public func readText(_ path: String) -> String? {
    guard var f = try? open(path) else { return nil }
    return try? f.readText()
  }

  /// Writes `text` at offset 0 of the file at `path` (a `ctl` leaf: one
  /// command); whether it was taken.
  public func writeText(_ path: String, _ text: String) -> Bool {
    guard var f = try? open(path) else { return false }
    return (try? f.writeText(text)) != nil
  }

  /// The file at `path` as memory (Node's `memory`): to read or map, and
  /// with `executable`, to run (a program in /bin).
  public func memory(_ path: String, executable: Bool) throws(NamespaceError) -> NodeIPC.Memory {
    var client = try open(path)
    do throws(NodeIPC.NodeClient.Failure) {
      return try client.memory(executable: executable)
    } catch {
      throw NamespaceError(error)
    }
  }

  /// Where a program started from this namespace finds its libraries
  /// (D124, ProgramEntry's `libraries`): `/lib/NAME` as memory that may run.
  public var libraries: @Sendable (String) -> (vmo: UInt32, size: UInt64)? {
    { [self] name in self.library(name) }
  }

  /// `/lib/NAME`'s VMO, a duplicate of the one kept, and its size.
  func library(_ name: String) -> (vmo: UInt32, size: UInt64)? {
    let key = Array(name.utf8)
    librariesLock.lock()
    defer { librariesLock.unlock() }
    var kept: (vmo: UInt32, size: UInt64)?
    for l in opened where l.name == key { kept = (l.vmo, l.size) }
    if kept == nil {
      guard let m = try? memory("/lib/" + name, executable: true) else { return nil }
      let size = m.size
      kept = (m.vmo.release(), size)
      opened.append((key, kept!.vmo, size))
    }
    guard let (vmo, size) = kept else { return nil }
    let original = Handle(raw: vmo)
    let lent = Result { () throws(Status) in try original.duplicate().release() }
    _ = original.release()  // kept
    guard case .success(let raw) = lent else { return nil }
    return (raw, size)
  }

  /// Changes the node at `path` (Node's `wstat`, Plan 9's): renames it in
  /// its directory, sets its time, or cuts or grows a file.
  public func wstat(_ path: String, _ change: NodeIPC.Wstat) throws(NamespaceError) {
    var client = try open(path)
    do throws(NodeIPC.NodeClient.Failure) {
      try client.wstat(change)
    } catch {
      throw NamespaceError(error)
    }
  }

  /// Variable `name` of this namespace's /env (D81): its elements, each
  /// stored followed by a NUL as Plan 9's rc stores them; nil if there is
  /// none (or no /env).
  public func environment(_ name: String) -> [String]? {
    guard NodeIPC.isValidName(name), var c = try? open("/env/" + name), let bytes = try? c.readAll() else {
      return nil
    }
    var elements: [String] = [], current: [UInt8] = []
    for b in bytes {
      if b == 0 {
        elements.append(String(decoding: current, as: UTF8.self))
        current = []
      } else {
        current.append(b)
      }
    }
    if !current.isEmpty { elements.append(String(decoding: current, as: UTF8.self)) }
    return elements
  }

  /// Variable `name` as Plan 9's getenv(2) gives it: its elements joined
  /// by blanks.
  public func getenv(_ name: String) -> String? { environment(name)?.joined(separator: " ") }

  /// Sets /env's `name` (D81) to `bytes`, its whole contents: made if need
  /// be, cut first if not.
  public func setEnvironment(_ name: String, _ bytes: [UInt8]) throws(NamespaceError) {
    guard NodeIPC.isValidName(name) else { throw .badPath }
    var file: NodeIPC.NodeClient
    var made = false
    if let old = try? open("/env/" + name) {
      file = old
    } else {
      var root = try open("/env")
      do throws(NodeIPC.NodeClient.Failure) { file = try root.create(name, kind: .file) } catch { throw NamespaceError(error) }
      made = true
    }
    do throws(NodeIPC.NodeClient.Failure) {
      if !made { try file.wstat(NodeIPC.Wstat(size: 0)) }
      var at = 0
      while at < bytes.count {
        let n = Swift.min(bytes.count - at, NodeIPC.maxIO)
        _ = try file.write(offset: UInt64(at), Array(bytes[at..<at + n]))
        at += n
      }
    } catch {
      throw NamespaceError(error)
    }
  }

  /// The entries at `path`: the union's members' listings merged, the
  /// first member's entry winning a name, then mount points below it.
  public func list(_ path: String, fields: UInt32 = NodeIPC.Fields.all) throws(NamespaceError) -> [NodeIPC.Stat] {
    let names = try Self.clean(path)
    var entries: [NodeIPC.Stat] = []
    var found = false
    if let (members, rest) = resolve(names) {
      for member in members {
        do throws(NodeIPC.NodeClient.Failure) {
          // A walk and a page of the listing in one batch.
          let page = try member.use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
            try c.list(rest.joined(separator: "/"), fields: fields)
          }
          found = true
          Self.merge(&entries, page)
        } catch {
          let e = NamespaceError(error)
          if e != .notFound { throw e }
        }
      }
    }
    // Mount points below the path show as directories, once a name.
    let below = locked {
      var below: [NodeIPC.Stat] = []
      for m in mounts where m.path.count > names.count && samePath(Array(m.path.prefix(names.count)), names) {
        let name = m.path[names.count]
        if below.contains(where: { NodeIPC.same($0.name, name) }) { continue }
        below.append(NodeIPC.Stat(qid: NodeIPC.Qid(path: 0, version: 0, kind: .directory), name: name, size: 0,
                                  modified: 0, attributes: []))
      }
      return below
    }
    if !below.isEmpty {
      found = true
      Self.merge(&entries, below)
    }
    guard found || names.isEmpty else { throw .notFound }
    return entries
  }

  /// Adds the entries of `more` (unique names) whose names `entries`
  /// lacks. The first listing goes in whole; later ones are looked up in
  /// the names so far, sorted, so merging big directories isn't
  /// quadratic.
  static func merge(_ entries: inout [NodeIPC.Stat], _ more: [NodeIPC.Stat]) {
    guard !entries.isEmpty else {
      entries = more
      return
    }
    let seen = entries.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    for e in more {
      let name = Array(e.name.utf8)
      var lo = 0, hi = seen.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if seen[mid].lexicographicallyPrecedes(name) { lo = mid + 1 } else { hi = mid }
      }
      if lo < seen.count && seen[lo] == name { continue }
      entries.append(e)
    }
  }

  /// Creates a node at `path` and opens it: at a union's mount point, in
  /// its member marked for creating; deeper, where the parent is.
  public func create(_ path: String, kind: NodeIPC.NodeKind) throws(NamespaceError) -> NodeIPC.NodeClient {
    let names = try Self.clean(path)
    guard let name = names.last else { throw .badPath }
    let parent = Array(names.dropLast())
    guard let (members, rest) = resolve(parent) else { throw .notFound }
    // At the mount point, in the member marked for creating; deeper, in the
    // first member whose walk to the parent succeeds. A walk and the create
    // are one batch.
    let candidates = rest.isEmpty ? members.filter { $0.create } : members
    guard !candidates.isEmpty else { throw .cantCreate }
    let at = rest.joined(separator: "/")
    var failure = NamespaceError.notFound
    for member in candidates {
      do throws(NodeIPC.NodeClient.Failure) {
        return try member.use { (c: inout NodeIPC.NodeClient) throws(NodeIPC.NodeClient.Failure) in
          try c.create(name, kind: kind, in: at)
        }
      } catch {
        failure = NamespaceError(error)
        if failure != .notFound { throw failure }
      }
    }
    throw failure
  }
}
