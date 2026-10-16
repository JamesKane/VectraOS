// SPDX-License-Identifier: BSD-3-Clause

// The API baseline: each method's wire signature, and the shape of each
// struct and enum it uses, one line each, so a change shows in review as a
// diff. `compatibility` says whether a new
// version of a protocol still serves clients of the recorded one
// (architecture §4: a change that would break an older client fails the
// build).

import IPCModel

/// One method as the baseline records it.
public struct BaselineMethod: Equatable {
  public var name: String
  public var kind: String  // call, oneway, event
  public var since: Int
  public var parameters: [String]  // Swift types, in order
  public var result: String  // "-" for none
  public var error: String  // "-" for none
  /// The protocol that declares it, if it comes by composition.
  public var from: String?

  init(_ m: Method, from: String? = nil) {
    self.from = from
    name = m.name
    kind = switch m.kind {
    case .call: "call"
    case .oneway: "oneway"
    case .event: "event"
    }
    since = m.since
    parameters = m.parameters.map { $0.type.swiftName }
    result = m.result?.type.swiftName ?? "-"
    error = m.errorType ?? "-"
  }

  init?(line: String) {
    // method NAME KIND since N params (A,B) result R throws E [from ID]
    let f = line.split(separator: " ").map(String.init)
    guard f.count == 11 || (f.count == 13 && f[11] == "from"), f[0] == "method", f[3] == "since", f[5] == "params", f[7] == "result",
      f[9] == "throws", let since = Int(f[4]), f[6].hasPrefix("("), f[6].hasSuffix(")")
    else { return nil }
    name = f[1]
    kind = f[2]
    self.since = since
    let inner = f[6].dropFirst().dropLast()
    parameters = inner.isEmpty ? [] : inner.split(separator: ",").map(String.init)
    result = f[8]
    error = f[10]
    from = f.count == 13 ? f[12] : nil
  }

  var line: String {
    "method \(name) \(kind) since \(since) params (\(parameters.joined(separator: ","))) result \(result) throws \(error)"
      + (from.map { " from \($0)" } ?? "")
  }
}

/// A struct or enum as the baseline records it: what its values look like
/// on the wire, not its names.
///
///     struct Point (Int32,Int32)
///     enum Shape UInt8 (1,2,7)
public struct BaselineType: Equatable {
  public var name: String
  public var line: String

  init(_ s: StructModel) {
    name = s.name
    line = "struct \(s.name) (\(s.fields.map { $0.type.swiftName }.joined(separator: ",")))"
  }

  init(_ e: EnumModel) {
    name = e.name
    line = "enum \(e.name) \(e.rawType) (\(e.cases.map { String($0.value) }.joined(separator: ",")))"
  }

  init?(line: String) {
    let f = line.split(separator: " ")
    guard f.count >= 3, f[0] == "struct" || f[0] == "enum" else { return nil }
    name = String(f[1])
    self.line = line
  }
}

/// A protocol's recorded API.
public struct Baseline: Equatable {
  public var id: String
  public var version: Int
  public var types: [BaselineType]
  /// The ids of the protocols it composes, directly or not. Their types
  /// are in their own baselines.
  public var composes: [String] = []
  public var methods: [BaselineMethod]

  public init(_ p: ProtocolModel, _ library: LibraryModel, composed: [Interface.ComposedMethod] = []) {
    id = p.id
    version = p.version
    let used = p.used(library.types)
    types = used.structs.map(BaselineType.init) + used.enums.map(BaselineType.init)
    types.sort { $0.name < $1.name }
    composes = composed.map(\.origin.id).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }.sorted()
    methods = (p.methods.map { BaselineMethod($0) } + composed.map { BaselineMethod($0.method, from: $0.origin.id) })
      .sorted { $0.name < $1.name }
  }

  /// The baseline file's text.
  public var text: String {
    (["# API baseline for \(id), written by idlc. Commit it; idlc checks changes against it.",
      "protocol \(id) version \(version)"] + types.map(\.line) + composes.map { "compose \($0)" } + methods.map(\.line))
      .joined(separator: "\n") + "\n"
  }

  public init?(text: String) {
    var id: String?
    var version: Int?
    var methods: [BaselineMethod] = []
    var types: [BaselineType] = []
    var composes: [String] = []
    for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("#") {
      let f = line.split(separator: " ")
      if f.first == "protocol", f.count == 4, f[2] == "version" {
        id = String(f[1])
        version = Int(f[3])
      } else if f.first == "compose", f.count == 2 {
        composes.append(String(f[1]))
      } else if let t = BaselineType(line: line) {
        types.append(t)
      } else if let m = BaselineMethod(line: line) {
        methods.append(m)
      } else {
        return nil
      }
    }
    guard let id, let version else { return nil }
    self.id = id
    self.version = version
    self.types = types
    self.composes = composes
    self.methods = methods
  }
}

/// Why `new` would break a client built against `old`; empty if it wouldn't.
public func compatibility(old: Baseline, new: Baseline) -> [String] {
  var problems: [String] = []
  if new.id != old.id { problems.append("the protocol id changed from \(old.id) to \(new.id)") }
  if new.version < old.version {
    problems.append("the version went down from \(old.version) to \(new.version)")
  }
  // A type's values must keep their shape: a client would misread them.
  for t in old.types {
    if let now = new.types.first(where: { $0.name == t.name }), now != t {
      problems.append("type '\(t.name)' changed: was `\(t.line)`, now `\(now.line)`")
    }
  }
  let current = Dictionary(uniqueKeysWithValues: new.methods.map { ($0.name, $0) })
  for m in old.methods {
    guard let now = current[m.name] else {
      problems.append("'\(m.name)' was removed")
      continue
    }
    if now != m { problems.append("'\(m.name)' changed: was `\(m.line)`, now `\(now.line)`") }
  }
  for c in old.composes where !new.composes.contains(c) {
    problems.append("it no longer composes \(c)")
  }
  // A composed protocol's methods follow that protocol's versions.
  let known = Set(old.methods.map(\.name))
  let added = new.methods.filter { !known.contains($0.name) && $0.from == nil }
  for m in added where m.since <= old.version {
    problems.append("'\(m.name)' is new, so it needs @since(\(old.version + 1)) or later")
  }
  if !added.isEmpty && new.version == old.version {
    problems.append("methods were added, so the version must go up from \(old.version)")
  }
  return problems
}
