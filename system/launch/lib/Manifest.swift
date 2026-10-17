// SPDX-License-Identifier: BSD-3-Clause

// Launcher manifests (architecture §3, §5): line-based text in the style of
// Plan 9's namespace files. One directive a line; `#` starts a comment.
//
//     service fs              # first: the service's name
//     program fs              # what runs (natively bootfs's bin/NAME; hosted, a registered program)
//     arg --cache 64          # arguments, in order
//     env NAME=value          # a variable of its /env (D81)
//     export                  # it serves a Node tree others may use
//     use block               # granted at /svc/block
//     use radharc-1 as display   # granted at /svc/display
//     use env                 # /svc/env, the launcher's: its `new` makes an environment group
//     mount /data fs/data/me after create   # PATH SERVICE[/SUB] [before|after] [create]
//     srv                     # the session board, at /srv
//     restart on-failure      # never (the default), on-failure or always
//     early                   # started before every service not marked early
//     notegroup kbdfs         # its job under kbdfs's: in its note group (the console's shell)
//     resource mmio           # a kind of hardware: mmio, irq, ioport, smc or system
//     programs                # it starts programs from bootfs, in a job under its own
//     jobs                    # the launcher's job, holding every service and what each starts (proc's, D79)
//     bootdata                # firmware's boot data (croi's ZBI items: RSDP, framebuffer, memory)
//     debuglog                # the debuglog's ring and its doorbell, to read (D38; the console's)
//     libraries               # it loads shared objects (dlopen) from bootfs's lib/ (M5k)
//     bootfs                  # the boot image itself, read only (the bootfs service, which serves it)
//     launcher                # the launcher's tree at /svc/launcher: status, memory, and ctl (`kill SERVICE`)
//     clock                   # it sets UTC: the UTC page, writable (the time service, D48)
//
// Every process is given the UTC page to read (D48), if the launcher has
// one; `clock` gives it writable too.
// `resource`, `programs` and `bootdata` are what devmgr is given (M3g,
// M3h): the launcher's own ranged root resource of the kind, bootfs with a
// job, so that it can start driver hosts, and the boot data. A launcher
// that has none to give refuses them.
//
// Not lifted yet (V2): `seal`, per-client services and their `grant`,
// apps and scripting (D65).
//
// Its lines are directives (Directives, D86): anything wrong stops the
// launch with its file and line.
//
// Names and words are compared as bytes (`NodeIPC.same`): String's `==`
// and `split` need Unicode tables tier 0 lacks.

import Directives
import Node
import Sys

/// A manifest error, with where it is.
public struct LaunchError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }

  public static func == (a: LaunchError, b: LaunchError) -> Bool { NodeIPC.same(a.description, b.description) }
}

public enum RestartPolicy: Sendable {
  case never
  case onFailure
  case always
}

/// Whether `s` is `literal`, as bytes.
func `is`(_ s: String, _ literal: StaticString) -> Bool {
  unsafe s.utf8.elementsEqual(UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
}

public struct Manifest: Sendable {
  /// A grant of a service's tree: `use` (at /svc/NAME, reconnected after a
  /// restart) or `mount` (anywhere, a direct channel).
  public struct Grant: Sendable {
    public var path: String
    public var service: String
    /// `use`: its name in /svc (the service's, or `as NAME`).
    public var name: String
    public var subpath: [String]
    public var placement: Namespace.Placement
    public var create: Bool
    /// `use`: through the process's /svc.
    public var viaSvc: Bool
    public var line: Int
  }

  public var file: String
  public var service = ""
  public var program = ""
  public var programLine = 0
  public var args: [String] = []
  public var environment: [String] = []
  public var exports = false
  public var grants: [Grant] = []
  public var srv = false
  public var restart = RestartPolicy.never
  /// `resource` lines: the kinds of hardware granted.
  public var resources: [(kind: ResourceKind, line: Int)] = []
  /// `programs`: its line, or 0.
  public var programsLine = 0
  /// `jobs`: its line, or 0.
  public var jobsLine = 0
  /// `libraries`: its line, or 0.
  public var librariesLine = 0
  /// `bootfs`: its line, or 0.
  public var bootfsLine = 0
  /// `bootdata`: its line, or 0.
  public var bootDataLine = 0
  /// `debuglog`: its line, or 0.
  public var debuglogLine = 0
  /// `launcher`: its line, or 0. The launcher's own tree at /svc/launcher,
  /// whose `ctl` ends a service as a crash would (tests of restarts).
  public var launcherLine = 0
  /// `clock`: its line, or 0.
  public var clockLine = 0
  /// `early`: started first (the console, for its budget).
  public var early = false
  /// `notegroup SERVICE`: its job made under that service's, so a note
  /// posted to that service's note group reaches it too (kbdfs's
  /// interrupt, the console's shell). Empty for its own.
  public var noteGroup = ""
  public var noteGroupLine = 0
  public var serviceLine = 0

  /// "file:line: message"
  func error(_ line: Int, _ message: String) -> LaunchError { LaunchError("\(file):\(line): \(message)") }

  /// The directives a manifest takes (manifest(6)).
  public static let directives: [StaticString] = [
    "service", "program", "arg", "env", "export", "use", "mount", "srv", "restart", "resource", "programs",
    "bootdata", "debuglog", "libraries", "bootfs", "launcher", "clock", "early", "jobs",
    "notegroup",
  ]

  public init(file: String, text: String) throws(LaunchError) {
    self.file = file
    let read: [Directive]
    do throws(DirectiveError) { read = try Directives.read(Array(text.utf8), file: file, known: Self.directives) } catch {
      throw LaunchError(error.description)
    }
    for d in read {
      let lineNumber = d.line, directive = d.name, rest = d.arguments
      if service.isEmpty && !`is`(directive, "service") { throw error(lineNumber, "'service' must come first") }
      func count(_ n: ClosedRange<Int>) throws(LaunchError) {
        guard n.contains(rest.count) else {
          let expected = n.lowerBound == n.upperBound ? "\(n.lowerBound)" : "\(n.lowerBound) to \(n.upperBound)"
          throw error(lineNumber, "'\(directive)' takes \(expected) argument\(n.upperBound == 1 ? "" : "s")")
        }
      }
      if `is`(directive, "service") {
        guard service.isEmpty else { throw error(lineNumber, "a second 'service'") }
        try count(1...1)
        guard NodeIPC.isValidName(rest[0]) else { throw error(lineNumber, "bad service name '\(rest[0])'") }
        service = rest[0]
        serviceLine = lineNumber
      } else if `is`(directive, "program") {
        try count(1...1)
        program = rest[0]
        programLine = lineNumber
      } else if `is`(directive, "arg") {
        args += rest
      } else if `is`(directive, "env") {
        try count(1...1)
        guard rest[0].utf8.contains(UInt8(ascii: "=")), rest[0].utf8.first != UInt8(ascii: "=") else {
          throw error(lineNumber, "env needs NAME=value")
        }
        environment.append(rest[0])
      } else if `is`(directive, "export") {
        try count(0...0)
        exports = true
      } else if `is`(directive, "use") {
        guard rest.count == 1 || (rest.count == 3 && `is`(rest[1], "as")) else {
          throw error(lineNumber, "'use' takes a service, and 'as NAME'")
        }
        guard NodeIPC.isValidName(rest[0]) else { throw error(lineNumber, "bad service name '\(rest[0])'") }
        let name = rest.count == 3 ? rest[2] : rest[0]
        guard NodeIPC.isValidName(name), !`is`(name, "launcher") else { throw error(lineNumber, "bad name '\(name)'") }
        guard !grants.contains(where: { $0.viaSvc && NodeIPC.same($0.name, name) }) else {
          throw error(lineNumber, "a second /svc/\(name)")
        }
        grants.append(Grant(path: "/svc/\(name)", service: rest[0], name: name, subpath: [], placement: .replace,
                            create: false, viaSvc: true, line: lineNumber))
      } else if `is`(directive, "mount") {
        try count(2...4)
        do throws(NamespaceError) { _ = try Namespace.clean(rest[0]) } catch {
          throw self.error(lineNumber, "bad path '\(rest[0])'")
        }
        let target = NodeIPC.names(rest[1])
        guard let name = target.first, target.allSatisfy(NodeIPC.isValidName) else {
          throw error(lineNumber, "bad service path '\(rest[1])'")
        }
        var grant = Grant(path: rest[0], service: name, name: name, subpath: Array(target.dropFirst()),
                          placement: .replace, create: false, viaSvc: false, line: lineNumber)
        for option in rest.dropFirst(2) {
          if `is`(option, "before") {
            grant.placement = .before
          } else if `is`(option, "after") {
            grant.placement = .after
          } else if `is`(option, "create") {
            grant.create = true
          } else {
            throw error(lineNumber, "unknown mount option '\(option)'")
          }
        }
        grants.append(grant)
      } else if `is`(directive, "srv") {
        try count(0...0)
        srv = true
      } else if `is`(directive, "restart") {
        try count(1...1)
        if `is`(rest[0], "never") {
          restart = .never
        } else if `is`(rest[0], "on-failure") {
          restart = .onFailure
        } else if `is`(rest[0], "always") {
          restart = .always
        } else {
          throw error(lineNumber, "'restart' takes never, on-failure or always")
        }
      } else if `is`(directive, "resource") {
        try count(1...1)
        guard let kind = ResourceKind(name: rest[0]), kind != .root else {
          throw error(lineNumber, "'resource' takes mmio, irq, ioport, smc or system")
        }
        guard !resources.contains(where: { $0.kind == kind }) else {
          throw error(lineNumber, "a second 'resource \(rest[0])'")
        }
        resources.append((kind, lineNumber))
      } else if `is`(directive, "programs") {
        try count(0...0)
        programsLine = lineNumber
      } else if `is`(directive, "jobs") {
        try count(0...0)
        jobsLine = lineNumber
      } else if `is`(directive, "bootdata") {
        try count(0...0)
        bootDataLine = lineNumber
      } else if `is`(directive, "debuglog") {
        try count(0...0)
        debuglogLine = lineNumber
      } else if `is`(directive, "libraries") {
        try count(0...0)
        librariesLine = lineNumber
      } else if `is`(directive, "bootfs") {
        try count(0...0)
        bootfsLine = lineNumber
      } else if `is`(directive, "launcher") {
        try count(0...0)
        launcherLine = lineNumber
      } else if `is`(directive, "clock") {
        try count(0...0)
        clockLine = lineNumber
      } else if `is`(directive, "early") {
        try count(0...0)
        early = true
      } else if `is`(directive, "notegroup") {
        try count(1...1)
        guard noteGroup.isEmpty else { throw error(lineNumber, "a second 'notegroup'") }
        guard NodeIPC.isValidName(rest[0]) else { throw error(lineNumber, "bad service name '\(rest[0])'") }
        noteGroup = rest[0]
        noteGroupLine = lineNumber
      }
    }
    guard !service.isEmpty else { throw LaunchError("\(file): no 'service'") }
    guard !program.isEmpty else { throw LaunchError("\(file): no 'program'") }
  }
}

/// Checks a set of manifests against each other and the programs there
/// are: every service named exists and exports, no name is taken twice,
/// nothing depends on itself. The order to start them in.
public func launchOrder(_ manifests: [Manifest], programs: [String]) throws(LaunchError) -> [Manifest] {
  func named(_ name: String) -> Manifest? { manifests.first { NodeIPC.same($0.service, name) } }
  for (i, m) in manifests.enumerated() {
    if let other = manifests[..<i].first(where: { NodeIPC.same($0.service, m.service) }) {
      throw m.error(m.serviceLine, "service '\(m.service)' is also defined at \(other.file):\(other.serviceLine)")
    }
    // env is the launcher's (D81): granted with `use env`, never a service.
    if NodeIPC.same(m.service, "env") { throw m.error(m.serviceLine, "'env' is the launcher's, not a service") }
    guard programs.contains(where: { NodeIPC.same($0, m.program) }) else {
      throw m.error(m.programLine, "no program '\(m.program)'")
    }
    for g in m.grants {
      if NodeIPC.same(g.service, "env") {
        guard g.viaSvc else { throw m.error(g.line, "env is granted with `use env`") }
        continue
      }
      guard let target = named(g.service) else { throw m.error(g.line, "no service '\(g.service)'") }
      guard target.exports else { throw m.error(g.line, "service '\(g.service)' exports nothing") }
    }
    if !m.noteGroup.isEmpty {
      guard named(m.noteGroup) != nil else { throw m.error(m.noteGroupLine, "no service '\(m.noteGroup)'") }
      guard !NodeIPC.same(m.noteGroup, m.service) else {
        throw m.error(m.noteGroupLine, "'notegroup' names the service itself")
      }
    }
  }
  var order: [Manifest] = []
  func visit(_ m: Manifest, _ path: [String]) throws(LaunchError) {
    if order.contains(where: { NodeIPC.same($0.service, m.service) }) { return }
    if let start = path.firstIndex(where: { NodeIPC.same($0, m.service) }) {
      let cycle = (path[start...] + [m.service]).joined(separator: " → ")
      throw m.error(m.serviceLine, "services depend on each other: \(cycle)")
    }
    for g in m.grants where !NodeIPC.same(g.service, m.service) && !NodeIPC.same(g.service, "env") {
      try visit(named(g.service)!, path + [m.service])
    }
    // Its note group's job is made first.
    if !m.noteGroup.isEmpty { try visit(named(m.noteGroup)!, path + [m.service]) }
    if m.grants.contains(where: { NodeIPC.same($0.service, m.service) }) {
      throw m.error(m.serviceLine, "services depend on each other: \(m.service) → \(m.service)")
    }
    order.append(m)
  }
  // Early services first, each after what it uses; then the rest.
  for m in manifests where m.early { try visit(m, []) }
  for m in manifests where !m.early { try visit(m, []) }
  return order
}
