// SPDX-License-Identifier: BSD-3-Clause

// rc's command line, read as 9front's getflags reads rc's
// "srdiIlxebpvVc:1m:1": flag letters grouped after a -, -c and -m taking a
// value (the rest of their group, or the next argument), a letter given
// twice an error, and the first argument that doesn't start with - (or
// is - alone) ending them. What's left is a file and its arguments.
//
// The flags rc acts on: -c (a command), -e (a failing command outside a
// condition ends rc), -x (each simple command on fd 2), -v (each line on
// fd 2 as it's read), -s (a false status on fd 2), -i and -I (interactive
// or not, whatever stdin is), -l (a login rc: the profile first). The
// others are taken and set for `flag`: -r and -d (debugging 9front's
// interpreter, which this one isn't), -b, -p (no functions from the
// environment, which brings none yet), -V, and -m (rcmain: this rc has
// none).

public struct RcArguments: Sendable, Equatable {
  public var flags: Set<Character> = []
  /// -c's command.
  public var command: String?
  /// A script and its arguments, or nothing.
  public var rest: [String] = []

  public static let usage = "usage: rc [-srdiIlxebpvV] [-c command] [-m rcmain] [file [arg ...]]"

  /// Nil if they don't read (`usage` says how they should).
  public init?(_ args: [String]) {
    var i = 0
    while i < args.count, args[i].hasPrefix("-"), args[i].count > 1 {
      var group = Substring(args[i].dropFirst())
      i += 1
      while let c = group.first {
        group = group.dropFirst()
        guard "srdiIlxebpvVcm".contains(c), !flags.contains(c) else { return nil }
        flags.insert(c)
        guard c == "c" || c == "m" else { continue }
        let value: String
        if group.isEmpty {
          guard i < args.count else { return nil }
          value = args[i]
          i += 1
        } else {
          value = String(group)
          group = ""
        }
        if c == "c" { command = value }
      }
    }
    rest = Array(args[i...])
  }
}

extension Rc {
  /// Takes `arguments`' flags, $cflag and $rcname (rc's own name).
  public func take(_ arguments: RcArguments, name: String) {
    flags = arguments.flags
    variables["rcname"] = [name]
    if let c = arguments.command { variables["cflag"] = [c] }
  }
}
