// SPDX-License-Identifier: BSD-3-Clause

// Finds the @IPCLibrary enums in Swift source files, so idlc can describe
// them in C and Markdown.

import IPCModel
import SwiftParser
import SwiftSyntax

/// Everything idlc reads from a set of files.
public struct Interface {
  public var libraries: [LibraryModel] = []
  /// Libraries read only so others can compose their protocols (`--with`).
  public var references: [LibraryModel] = []

  /// Every library's protocols, with the library each belongs to.
  public var protocols: [(library: LibraryModel, protocol: ProtocolModel)] {
    libraries.flatMap { l in l.protocols.map { (l, $0) } }
  }

  /// A method a protocol has by composing another: where it's declared.
  public struct ComposedMethod {
    public var method: Method
    public var origin: ProtocolModel
    public var library: LibraryModel
  }

  /// The protocols `p` composes, directly or through others, each once.
  public func composed(_ p: ProtocolModel, in library: LibraryModel) throws(IDLError)
    -> [(library: LibraryModel, protocol: ProtocolModel)]
  {
    var out: [(library: LibraryModel, protocol: ProtocolModel)] = []
    func visit(_ p: ProtocolModel, _ library: LibraryModel, _ path: [String]) throws(IDLError) {
      for name in p.composes {
        let parts = name.split(separator: ".").map(String.init)
        let (enumName, protocolName) = parts.count == 2 ? (parts[0], parts[1]) : (library.name, name)
        guard let l = (libraries + references).first(where: { $0.name == enumName }),
          let target = l.protocols.first(where: { $0.name == protocolName })
        else {
          throw IDLError(description: "\(p.id) composes \(name), which no file given declares (pass its file with --with)")
        }
        guard !path.contains(target.id) else { throw IDLError(description: "\(target.id) composes itself") }
        if !out.contains(where: { $0.protocol.id == target.id }) {
          out.append((l, target))
          try visit(target, l, path + [target.id])
        }
      }
    }
    try visit(p, library, [p.id])
    return out
  }

  /// The methods `p` has by composition, checked against its own for
  /// clashing names and ordinals.
  public func composedMethods(_ p: ProtocolModel, in library: LibraryModel) throws(IDLError) -> [ComposedMethod] {
    var out: [ComposedMethod] = []
    var seen = p.methods.map { (name: $0.name, ordinal: $0.ordinal, from: p.id) }
    for (l, c) in try composed(p, in: library) {
      for m in c.methods {
        if let clash = seen.first(where: { $0.name == m.name || $0.ordinal == m.ordinal }) {
          throw IDLError(description: "\(p.id): '\(m.name)' of \(c.id) clashes with '\(clash.name)' of \(clash.from)")
        }
        seen.append((m.name, m.ordinal, c.id))
        out.append(ComposedMethod(method: m, origin: c, library: l))
      }
    }
    return out
  }
}

/// A library idlc couldn't read, with where it is.
public struct IDLError: Error, CustomStringConvertible {
  public let description: String
}

/// Reads every @IPCLibrary enum in `sources` (path, contents), and in
/// `references`, whose libraries are only there to be composed.
public func scan(_ sources: [(path: String, text: String)], references: [(path: String, text: String)] = [])
  throws(IDLError) -> Interface
{
  var interface = Interface()
  if !references.isEmpty { interface.references = try scan(references).libraries }
  for (path, text) in sources {
    let file = Parser.parse(source: text)
    for statement in file.statements {
      guard let e = statement.item.as(EnumDeclSyntax.self), let attribute = LibraryModel.attribute(of: e) else {
        continue
      }
      do {
        interface.libraries.append(try LibraryModel(e, attribute: attribute))
      } catch {
        throw IDLError(description: "\(path): library \(e.name.text): \(error)")
      }
    }
  }
  return interface
}
