// SPDX-License-Identifier: BSD-3-Clause

// The shadow-model fuzzer (filesystem.md §9, after gefs's fuzz.c): random
// operations go to the file system and to an in-memory model of POSIX
// semantics. Every result and error must agree; after every step the whole
// tree and every file's bytes are compared; and now and then the machine
// "crashes": the device is mounted exactly as it is, unsynced data and all,
// and must equal the model as of the last sync, with open-but-unlinked
// files gone.

import Taisce
import Testing

struct ModelNode: Equatable {
  var type: NodeType
  var data: [UInt8] = []
  var children: [[UInt8]: UInt64] = [:]
  var parent: UInt64
  var links: UInt32
  var target: [UInt8] = []
  var attributes: [[UInt8]: AttributeValue] = [:]
}

struct Model: Equatable {
  var nodes: [UInt64: ModelNode] = [FileSystem<MemoryDevice>.root: ModelNode(type: .directory, parent: 1, links: 2)]
  var open: [UInt64: Int] = [:]
  /// Whether user:tag has an index (declared partway through a run).
  var tagIndex = false

  func dirs() -> [UInt64] { nodes.filter { $0.value.type == .directory }.map(\.key).sorted() }
  func files() -> [UInt64] { nodes.filter { $0.value.type == .file }.map(\.key).sorted() }
  /// Every (dir, name) pair.
  func names() -> [(UInt64, [UInt8])] {
    nodes.flatMap { d in d.value.children.keys.map { (d.key, $0) } }.sorted {
      $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.lexicographicallyPrecedes($1.1)
    }
  }

  mutating func dropLink(_ ino: UInt64) {
    guard var n = nodes[ino] else { return }
    n.links = n.type == .directory ? 0 : n.links - 1
    nodes[ino] = n
    if n.links == 0 && open[ino] == nil { nodes[ino] = nil }
  }

  /// What a crash and remount leave: no handles, so unlinked files go.
  func afterCrash() -> Model {
    var m = self
    m.open = [:]
    m.nodes = m.nodes.filter { $0.value.links > 0 }
    return m
  }
}

struct Fuzzer: ~Copyable {
  var rng: SplitMix
  var fs: FileSystem<MemoryDevice>
  var model = Model()
  var synced = Model()
  var now: UInt64 = 10
  var steps = 0
  var crashes = 0
  /// The last operations, to print with the first failure.
  var recent: [String] = []
  var reported = false

  init(seed: UInt64) throws {
    rng = SplitMix(state: seed)
    fs = try FileSystem.format(MemoryDevice(blocks: 16_384), label: [], uuid: Array(1...16), now: 1)
  }

  mutating func name() -> [UInt8] {
    let letters = Array("abcdefgh".utf8)
    return (0..<(1 + rng.below(2))).map { _ in letters[rng.below(letters.count)] }
  }
  mutating func pick(_ xs: [UInt64]) -> UInt64? { xs.isEmpty ? nil : xs[rng.below(xs.count)] }
  mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }

  /// The model's error for an operation that names `name` in `dir`.
  func entryError(_ dir: UInt64) -> TaisceError? {
    guard let d = model.nodes[dir] else { return .notFound }
    return d.type == .directory ? nil : .notDirectory
  }

  /// Runs `op` on the file system and expects `expected` (nil: success).
  mutating func expect(_ expected: TaisceError?, _ what: String, _ op: (inout FileSystem<MemoryDevice>) throws -> Void)
  {
    recent.append("\(steps): \(what)")
    if recent.count > 25 { recent.removeFirst() }
    do {
      try op(&fs)
      #expect(expected == nil, "step \(steps): \(what) succeeded, the model says \(String(describing: expected))")
    } catch let e as TaisceError {
      #expect(expected == e, "step \(steps): \(what) failed with \(e), the model says \(String(describing: expected))")
    } catch {
      Issue.record("step \(steps): \(what): \(error)")
    }
  }

  mutating func step() throws {
    steps += 1
    now += 1
    let t = now
    switch rng.below(100) {
    case 0..<14:  // create a file or directory, sometimes in a file
      let dir = rng.below(10) == 0 ? (pick(model.files()) ?? 1) : pick(model.dirs())!
      let nm = name(), type: NodeType = rng.below(3) == 0 ? .directory : .file
      var err = entryError(dir)
      if err == nil, model.nodes[dir]!.children[nm] != nil { err = .exists }
      var made: UInt64 = 0
      expect(err, "create \(dir)/\(nm)") { made = try $0.create(dir, nm, type, mode: 0o644, now: t) }
      if err == nil {
        model.nodes[made] = ModelNode(type: type, parent: dir, links: type == .directory ? 2 : 1)
        model.nodes[dir]!.children[nm] = made
        if type == .directory { model.nodes[dir]!.links += 1 }
      }
    case 14..<17:  // a symlink
      let dir = pick(model.dirs())!, nm = name(), target = bytes(1 + rng.below(40))
      let err: TaisceError? = model.nodes[dir]!.children[nm] != nil ? .exists : nil
      var made: UInt64 = 0
      expect(err, "symlink \(dir)/\(nm)") { made = try $0.symlink(dir, nm, target: target, now: t) }
      if err == nil {
        model.nodes[made] = ModelNode(type: .symlink, parent: dir, links: 1, target: target)
        model.nodes[dir]!.children[nm] = made
      }
    case 17..<40:  // write, sometimes far past the end
      guard let f = pick(model.files()) else { return }
      let size = model.nodes[f]!.data.count
      let offset = rng.below(4) == 0 ? rng.below(300_000) : rng.below(size + 5000)
      let data = bytes(1 + rng.below(rng.below(4) == 0 ? 40_000 : 3000))
      expect(nil, "write \(f) at \(offset)") { try $0.write(f, offset: UInt64(offset), data, now: t) }
      var d = model.nodes[f]!.data
      if d.count < offset + data.count { d += [UInt8](repeating: 0, count: offset + data.count - d.count) }
      d.replaceSubrange(offset..<(offset + data.count), with: data)
      model.nodes[f]!.data = d
    case 40..<46:  // truncate
      guard let f = pick(model.files()) else { return }
      let size = rng.below(model.nodes[f]!.data.count + 9000)
      expect(nil, "truncate \(f) to \(size)") { try $0.truncate(f, size: UInt64(size), now: t) }
      var d = model.nodes[f]!.data
      if size < d.count { d.removeLast(d.count - size) } else { d += [UInt8](repeating: 0, count: size - d.count) }
      model.nodes[f]!.data = d
    case 46..<54:  // unlink or rmdir an existing name, or a missing one
      let names = model.names()
      let (dir, nm) = names.isEmpty || rng.below(6) == 0 ? (pick(model.dirs())!, name()) : names[rng.below(names.count)]
      let ino = model.nodes[dir]!.children[nm]
      if rng.below(2) == 0 {
        let err: TaisceError? = ino == nil ? .notFound : model.nodes[ino!]!.type == .directory ? .isDirectory : nil
        expect(err, "unlink \(dir)/\(nm)") { try $0.unlink(dir, nm, now: t) }
        if err == nil {
          model.nodes[dir]!.children[nm] = nil
          model.dropLink(ino!)
        }
      } else {
        var err: TaisceError? = ino == nil ? .notFound : nil
        if err == nil, model.nodes[ino!]!.type != .directory { err = .notDirectory }
        if err == nil, !model.nodes[ino!]!.children.isEmpty { err = .notEmpty }
        expect(err, "rmdir \(dir)/\(nm)") { try $0.rmdir(dir, nm, now: t) }
        if err == nil {
          model.nodes[dir]!.children[nm] = nil
          model.nodes[dir]!.links -= 1
          model.dropLink(ino!)
        }
      }
    case 54..<66:  // rename
      let names = model.names()
      guard !names.isEmpty else { return }
      let (from, fromName) = names[rng.below(names.count)]
      let to = rng.below(12) == 0 ? (pick(model.files()) ?? 1) : pick(model.dirs())!
      let toName = rng.below(3) == 0 ? fromName : name()
      try rename(from, fromName, to, toName, t)
    case 66..<70:  // a hard link
      guard let f = pick(model.files() + model.nodes.filter { $0.value.type == .symlink }.map(\.key)) else { return }
      let dir = rng.below(10) == 0 ? (pick(model.dirs().count > 1 ? model.dirs() : [1])!) : pick(model.dirs())!
      let nm = name()
      let err: TaisceError? = model.nodes[dir]!.children[nm] != nil ? .exists : nil
      expect(err, "link \(f) as \(dir)/\(nm)") { try $0.link(f, dir, nm, now: t) }
      if err == nil {
        model.nodes[dir]!.children[nm] = f
        model.nodes[f]!.links += 1
      }
    case 70..<76:  // open or close
      if let f = pick(model.files()), rng.below(2) == 0 {
        recent.append("\(steps): open \(f)")
        fs.opened(f)
        model.open[f, default: 0] += 1
      } else if let f = pick(model.open.keys.sorted()) {
        recent.append("\(steps): close \(f)")
        try fs.closed(f)
        model.open[f]! -= 1
        if model.open[f] == 0 {
          model.open[f] = nil
          if model.nodes[f]!.links == 0 { model.nodes[f] = nil }
        }
      }
    case 76..<77:  // errors on the wrong kind of node
      if let d = pick(model.dirs()) {
        expect(.isDirectory, "write a directory") { try $0.write(d, offset: 0, [1], now: t) }
      }
    case 77..<87:  // an attribute, set or removed, sometimes too big to stay inline
      guard let ino = pick(model.nodes.keys.sorted()) else { return }
      let names = ["user:tag", "user:n", "Audio:Artist", "sys:type"].map { Array($0.utf8) }
      let nm = names[rng.below(names.count)]
      if rng.below(4) == 0 {
        expect(nil, "remove \(ino) attribute") { _ = try $0.removeAttribute(ino, nm, now: t) }
        model.nodes[ino]!.attributes[nm] = nil
      } else {
        let tags = ["Rock", "rock", "ROCK", "Jazz", "jazz", "Folk"]
        let v: AttributeValue = switch rng.below(4) {
        case 0: .int64(Int64(rng.below(5)) - 2)
        case 1: .bytes(bytes(rng.below(8) == 0 ? 3000 + rng.below(6000) : rng.below(40)))
        default: .string(Array(tags[rng.below(tags.count)].utf8))
        }
        expect(nil, "set \(ino) attribute") { try $0.setAttribute(ino, nm, v, now: t) }
        model.nodes[ino]!.attributes[nm] = v
      }
    case 87..<91:
      recent.append("\(steps): sync")
      try fs.sync()
      synced = model
    case 91..<95:  // as durable as a sync, through the intent log
      recent.append("\(steps): fsync")
      try fs.fsync()
      synced = model
    default:  // crash, after the last sync
      try crash()
    }
    // Partway through, index user:tag, then fill it in a little each step.
    if steps >= 300 && !model.tagIndex {
      try fs.declareIndex(Array("user:tag".utf8), .string, collation: .caseFolded)
      model.tagIndex = true
    }
    if model.tagIndex { try fs.backfill(budget: 3) }
  }

  mutating func rename(_ from: UInt64, _ fromName: [UInt8], _ to: UInt64, _ toName: [UInt8], _ t: UInt64) throws {
    let src = model.nodes[from]!.children[fromName]!
    let srcNode = model.nodes[src]!
    var err: TaisceError? = model.nodes[to]!.type == .directory ? nil : .notDirectory
    var noop = err == nil && from == to && fromName == toName
    if err == nil, !noop, srcNode.type == .directory {
      var d = to
      while true {
        if d == src {
          err = .invalid
          break
        }
        let p = model.nodes[d]!.parent
        if p == d { break }
        d = p
      }
    }
    let target = model.nodes[to]!.children[toName]
    if err == nil, !noop, let target {
      if target == src {
        noop = true
      } else if srcNode.type == .directory {
        if model.nodes[target]!.type != .directory { err = .notDirectory }
        else if !model.nodes[target]!.children.isEmpty { err = .notEmpty }
      } else if model.nodes[target]!.type == .directory {
        err = .isDirectory
      }
    }
    expect(err, "rename \(from)/\(fromName) to \(to)/\(toName)") { try $0.rename(from, fromName, to, toName, now: t) }
    guard err == nil, !noop else { return }
    if let target {
      model.nodes[to]!.children[toName] = nil
      if model.nodes[target]!.type == .directory { model.nodes[to]!.links -= 1 }
      model.dropLink(target)
    }
    model.nodes[from]!.children[fromName] = nil
    model.nodes[to]!.children[toName] = src
    if srcNode.type == .directory && from != to {
      model.nodes[src]!.parent = to
      model.nodes[from]!.links -= 1
      model.nodes[to]!.links += 1
    }
  }

  /// Loses everything in memory and mounts the device exactly as it is. It
  /// holds file data written since the last sync, in blocks no committed
  /// metadata points at, and the mount must not see any of it.
  mutating func crash() throws {
    recent.append("\(steps): crash")
    crashes += 1
    fs = try FileSystem.mount(fs.engine.store.volume.device)
    model = synced.afterCrash()
    synced = model
    try fs.check()
  }

  /// The whole tree and every byte, the file system's against the model's.
  mutating func compare() throws {
    for (ino, m) in model.nodes {
      let n = try fs.stat(ino)
      #expect(n.type == m.type && n.links == m.links, "step \(steps): node \(ino) is \(n.type)/\(n.links), model \(m.type)/\(m.links)")
      switch m.type {
      case .directory:
        let listed = try fs.list(ino)
        let got = Dictionary(listed.map { ($0.entry.name, $0.entry.ino) }, uniquingKeysWith: { a, _ in a })
        #expect(got == m.children && listed.count == m.children.count, "step \(steps): directory \(ino) differs")
        if ino != 1 { #expect(n.parent == m.parent, "step \(steps): \(ino)'s parent") }
      case .file:
        #expect(n.size == UInt64(m.data.count), "step \(steps): file \(ino) is \(n.size) bytes, model \(m.data.count)")
        let got = try fs.read(ino, offset: 0, count: m.data.count + 10)
        if got != m.data && !reported {
          reported = true
          let at = (0..<min(got.count, m.data.count)).first { got[$0] != m.data[$0] } ?? min(got.count, m.data.count)
          Issue.record("step \(steps): file \(ino)'s bytes differ from byte \(at) (size \(m.data.count)); recent:\n\(recent.joined(separator: "\n"))")
          for r in recent { print("RECENT \(r)") }
        }
      case .symlink:
        #expect(try fs.readlink(ino) == m.target)
      }
      let names = try fs.attributes(ino).map(\.name)
      #expect(Set(names) == Set(m.attributes.keys) && names.count == m.attributes.count, "step \(steps): \(ino)'s attribute names")
      for (name, value) in m.attributes {
        #expect(try fs.attribute(ino, name) == value, "step \(steps): \(ino)'s \(String(decoding: name, as: UTF8.self))")
      }
    }
    // The tag index, once ready, answers as the model does (ASCII tags: lowercase is their folding).
    if model.tagIndex, fs.indices.contains(where: { $0.name == Array("user:tag".utf8) && !$0.building }) {
      for tag in ["rock", "JAZZ", "folk"] {
        let want = model.nodes.filter {
          if case .string(let s)? = $0.value.attributes[Array("user:tag".utf8)] {
            String(decoding: s, as: UTF8.self).lowercased() == tag.lowercased()
          } else { false }
        }.map(\.key).sorted()
        let got = try fs.indexLookup(Array("user:tag".utf8), equal: .string(Array(tag.utf8))).sorted()
        #expect(got == want, "step \(steps): user:tag ~= \(tag)")
      }
    }
  }
}

@Test(arguments: [UInt64(101), 102, 103])
func theFileSystemMatchesAShadowModel(seed: UInt64) throws {
  var f = try Fuzzer(seed: seed)
  for i in 0..<1500 {
    try f.step()
    try f.compare()
    if i % 50 == 0 { try f.fs.check() }
  }
  try f.fs.check()
  #expect(f.crashes > 5, "too few crashes to mean much")
  #expect(f.model.nodes.count > 10, "the tree stayed small: \(f.model.nodes.count)")
  #expect(f.model.nodes.values.contains { !$0.attributes.isEmpty }, "no attributes survived")
}
