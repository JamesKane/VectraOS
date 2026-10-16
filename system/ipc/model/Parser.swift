// SPDX-License-Identifier: BSD-3-Clause

// Reads an @IPCLibrary enum into the model. The macro and idlc both use
// this, so they can't disagree about a library.

import SwiftParser
import SwiftSyntax

/// A library the model can't accept, and why.
public struct ModelError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// An enum declared with @IPCLibrary: its types and protocols.
public struct LibraryModel: Sendable {
  public var name: String
  public var id: String
  public var version: Int
  public var isPublic: Bool
  public var types = Types()
  public var errors: [ErrorEnumModel] = []
  public var protocols: [ProtocolModel] = []
  var protocolNames: [String] = []

  /// Reads `library`, whose @IPCLibrary attribute is `attribute`.
  public init(_ library: EnumDeclSyntax, attribute: AttributeSyntax) throws(ModelError) {
    name = library.name.text
    isPublic = library.modifiers.contains { $0.name.text == "public" }
    (id, version) = try Self.arguments(attribute)

    // Names first, so members can refer to types declared after them.
    var structNames: [String] = [], enumNames: [String] = []
    for member in library.memberBlock.members {
      if let s = member.decl.as(StructDeclSyntax.self) { structNames.append(s.name.text) }
      if let e = member.decl.as(EnumDeclSyntax.self), !Self.isErrorEnum(e) { enumNames.append(e.name.text) }
    }
    let resolver = Resolver(structs: structNames, enums: enumNames)

    var structDecls: [StructDeclSyntax] = []
    var protocolDecls: [ProtocolDeclSyntax] = []
    for member in library.memberBlock.members {
      if let s = member.decl.as(StructDeclSyntax.self) {
        structDecls.append(s)
      } else if let e = member.decl.as(EnumDeclSyntax.self) {
        if Self.isErrorEnum(e) {
          errors.append(try Self.errorEnum(e))
        } else {
          types.enums.append(try Self.fieldEnum(e))
        }
      } else if let p = member.decl.as(ProtocolDeclSyntax.self) {
        protocolDecls.append(p)
      } else {
        throw ModelError("an IPC library holds only structs, enums and protocols")
      }
    }
    for s in structDecls { types.structs.append(try Self.structure(s, resolver)) }
    try layOutStructs()
    try checkVectors()
    for s in types.structs {
      for f in s.fields {
        if types.hasHandles(f.type) && s.isCopyable {
          throw ModelError("struct '\(s.name)' carries handles in '\(f.name)', so it must be ~Copyable")
        }
      }
    }
    protocolNames = protocolDecls.map { $0.name.text }
    for p in protocolDecls { protocols.append(try protocolModel(p, resolver)) }
  }

  /// The @IPCLibrary attribute of an enum, if it has one.
  public static func attribute(of library: EnumDeclSyntax) -> AttributeSyntax? {
    for attribute in library.attributes {
      if let a = attribute.as(AttributeSyntax.self), a.attributeName.trimmedDescription == "IPCLibrary" {
        return a
      }
    }
    return nil
  }

  static func arguments(_ node: AttributeSyntax) throws(ModelError) -> (String, Int) {
    var id: String?
    var version: Int?
    for argument in node.arguments?.as(LabeledExprListSyntax.self) ?? [] {
      switch argument.label?.text {
      case "id":
        id = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
      case "version":
        version = argument.expression.as(IntegerLiteralExprSyntax.self).flatMap { Int($0.literal.text) }
      default: break
      }
    }
    guard let id, !id.isEmpty else { throw ModelError("@IPCLibrary needs id: a string literal") }
    guard let version, version >= 1 else { throw ModelError("@IPCLibrary needs version: an integer ≥ 1") }
    return (id, version)
  }

  // MARK: Types

  /// Turns written types into wire types.
  struct Resolver {
    var structs: [String]
    var enums: [String]

    func resolve(_ syntax: TypeSyntax, _ context: String) throws(ModelError) -> WireType {
      var t = syntax
      if let attributed = t.as(AttributedTypeSyntax.self) { t = attributed.baseType }
      if let optional = t.as(OptionalTypeSyntax.self) {
        let wrapped = try resolve(optional.wrappedType, context)
        if case .optional = wrapped { throw ModelError("\(context): an optional of an optional isn't supported") }
        return .optional(wrapped)
      }
      if let array = t.as(ArrayTypeSyntax.self) {
        let element = try resolve(array.element, context)
        if element == .integer("UInt8", size: 1) { return .bytes }
        return .vector(element)
      }
      let name = t.trimmedDescription
      if let builtin = WireType.builtin(name) { return builtin }
      if structs.contains(name) { return .structure(name) }
      if enums.contains(name) { return .enumeration(name) }
      throw ModelError("\(context): type '\(name)' is not supported (declare it in the library)")
    }
  }

  static func isErrorEnum(_ e: EnumDeclSyntax) -> Bool {
    e.inheritanceClause?.inheritedTypes.contains { $0.type.trimmedDescription == "IPCErrorCode" } ?? false
  }

  /// Case values as written, or the previous one plus 1 (from 0), as Swift
  /// assigns them.
  static func caseValues(_ e: EnumDeclSyntax) throws(ModelError) -> [(String, Int64)] {
    var cases: [(String, Int64)] = []
    var next: Int64 = 0
    for member in e.memberBlock.members {
      guard let decl = member.decl.as(EnumCaseDeclSyntax.self) else {
        throw ModelError("enum '\(e.name.text)' holds only cases")
      }
      for element in decl.elements {
        if element.parameterClause != nil {
          throw ModelError("enum '\(e.name.text)': case '\(element.name.text)' can't carry values")
        }
        var value = next
        if let raw = element.rawValue?.value {
          var text = raw.trimmedDescription.filter { $0 != "_" && $0 != " " }
          let negative = text.hasPrefix("-")
          if negative { text.removeFirst() }
          guard let magnitude = text.hasPrefix("0x") ? Int64(text.dropFirst(2), radix: 16) : Int64(text) else {
            throw ModelError("enum '\(e.name.text)': case '\(element.name.text)' needs an integer literal")
          }
          value = negative ? -magnitude : magnitude
        }
        cases.append((element.name.text, value))
        next = value &+ 1
      }
    }
    guard !cases.isEmpty else { throw ModelError("enum '\(e.name.text)' has no cases") }
    return cases
  }

  static func fieldEnum(_ e: EnumDeclSyntax) throws(ModelError) -> EnumModel {
    let inherited = e.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
    guard let raw = inherited.first(where: { WireType.builtin($0).map { if case .integer = $0 { true } else { false } } ?? false }),
      case .integer(_, let size) = WireType.builtin(raw)!
    else { throw ModelError("enum '\(e.name.text)' needs an integer raw type") }
    let cases = try caseValues(e)
    let signed = raw.hasPrefix("Int")
    let bits = Int64(size * 8)
    for (name, value) in cases {
      let fits = signed
        ? bits == 64 || (value >= -(1 << (bits - 1)) && value < 1 << (bits - 1))
        : value >= 0 && (bits == 64 || value < 1 << bits)
      if !fits { throw ModelError("enum '\(e.name.text)': case '\(name)' doesn't fit in \(raw)") }
    }
    return EnumModel(name: e.name.text, rawType: raw, size: size, cases: cases)
  }

  static func errorEnum(_ e: EnumDeclSyntax) throws(ModelError) -> ErrorEnumModel {
    guard e.inheritanceClause?.inheritedTypes.contains(where: { $0.type.trimmedDescription == "Int32" }) ?? false else {
      throw ModelError("error enum '\(e.name.text)' needs raw type Int32")
    }
    var cases: [(String, Int32)] = []
    for (name, value) in try caseValues(e) {
      guard value > 0, value <= Int64(Int32.max) else {
        throw ModelError("error enum '\(e.name.text)': case '\(name)' needs a positive code")
      }
      cases.append((name, Int32(value)))
    }
    return ErrorEnumModel(name: e.name.text, cases: cases)
  }

  static func structure(_ s: StructDeclSyntax, _ resolver: Resolver) throws(ModelError) -> StructModel {
    let name = s.name.text
    let copyable = !(s.inheritanceClause?.inheritedTypes.contains { $0.type.trimmedDescription == "~Copyable" } ?? false)
    var fields: [(String, String, WireType)] = []
    var initializers: [InitializerDeclSyntax] = []
    for member in s.memberBlock.members {
      if let i = member.decl.as(InitializerDeclSyntax.self) {
        initializers.append(i)
        continue
      }
      guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
      if v.modifiers.contains(where: { $0.name.text == "static" }) { continue }
      for binding in v.bindings {
        // Computed properties aren't on the wire; observed ones are stored.
        if let block = binding.accessorBlock {
          let observers = block.accessors.as(AccessorDeclListSyntax.self)?.allSatisfy {
            ["willSet", "didSet"].contains($0.accessorSpecifier.text)
          } ?? false
          if !observers { continue }
        }
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self), let type = binding.typeAnnotation?.type
        else { throw ModelError("struct '\(name)': every stored property needs a written type") }
        let field = pattern.identifier.text
        fields.append((field, type.trimmedDescription, try resolver.resolve(type, "'\(name).\(field)'")))
      }
    }
    guard !fields.isEmpty else { throw ModelError("struct '\(name)' has no stored properties") }
    // Decoding calls the memberwise initializer. One may be written out (to
    // make it public, for other modules), with the fields' labels in order;
    // others go in an extension.
    for i in initializers {
      let labels = i.signature.parameterClause.parameters.map { $0.firstName.text }
      guard labels == fields.map(\.0) else {
        throw ModelError("struct '\(name)': decoding uses the memberwise initializer, so declare others in an extension")
      }
    }
    return StructModel(name: name, isCopyable: copyable, fields: fields)
  }

  /// Lays out every struct, those it holds inline first.
  mutating func layOutStructs() throws(ModelError) {
    var done: [String] = []
    func layOut(_ name: String, _ path: [String]) throws(ModelError) {
      guard !done.contains(name) else { return }
      guard !path.contains(name) else { throw ModelError("struct '\(name)' contains itself") }
      let i = types.structs.firstIndex { $0.name == name }!
      for f in types.structs[i].fields {
        if case .structure(let inner) = f.type { try layOut(inner, path + [name]) }
      }
      let s = types.structs[i]
      types.structs[i].alignment = s.fields.map { types.alignment($0.type) }.max() ?? 1
      types.structs[i].layout = Layout(s.fields.map { ($0.name, $0.type) }, types: types,
                                       rounding: types.structs[i].alignment)
      done.append(name)
    }
    for s in types.structs { try layOut(s.name, []) }
  }

  /// Vectors hold copyable elements: Swift arrays can't hold others.
  func checkVectors() throws(ModelError) {
    func check(_ t: WireType, _ context: String) throws(ModelError) {
      switch t {
      case .vector(let e):
        if !types.isCopyable(e) { throw ModelError("\(context): a vector's elements can't carry handles") }
        try check(e, context)
      case .optional(let w): try check(w, context)
      default: break
      }
    }
    for s in types.structs {
      for f in s.fields { try check(f.type, "'\(s.name).\(f.name)'") }
    }
  }

  // MARK: Protocols

  func protocolModel(_ p: ProtocolDeclSyntax, _ resolver: Resolver) throws(ModelError) -> ProtocolModel {
    let protocolID = "\(id).\(p.name.text)"
    var methods: [Method] = []
    for member in p.memberBlock.members {
      guard let function = member.decl.as(FunctionDeclSyntax.self) else {
        throw ModelError("protocol '\(p.name.text)' holds only methods")
      }
      methods.append(try method(function, protocolID: protocolID, resolver))
    }
    var seen: [(UInt64, String)] = []
    for m in methods {
      if let other = seen.first(where: { $0.0 == m.ordinal }) {
        throw ModelError("methods '\(other.1)' and '\(m.name)' have the same ordinal; rename one")
      }
      seen.append((m.ordinal, m.name))
    }
    // `protocol Directory: NodeIPC.Node, Attributes` composes those.
    var composes: [String] = []
    for inherited in p.inheritanceClause?.inheritedTypes ?? [] {
      let name = inherited.type.trimmedDescription
      let parts = name.split(separator: ".", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } })
      else { throw ModelError("protocol '\(p.name.text)' composes '\(name)': name a protocol, as Name or Library.Name") }
      if parts.count == 1 && !protocolNames.contains(name) {
        throw ModelError("protocol '\(p.name.text)' composes '\(name)', which the library doesn't declare")
      }
      if composes.contains(name) || name == p.name.text {
        throw ModelError("protocol '\(p.name.text)' composes '\(name)' twice, or itself")
      }
      composes.append(name)
    }
    var model = ProtocolModel(name: p.name.text, id: protocolID, version: version, methods: methods)
    model.composes = composes
    return model
  }

  func method(_ f: FunctionDeclSyntax, protocolID: String, _ resolver: Resolver) throws(ModelError) -> Method {
    let name = f.name.text
    var kind = MethodKind.call
    var since = 1
    for attribute in f.attributes {
      guard let a = attribute.as(AttributeSyntax.self) else { continue }
      switch a.attributeName.trimmedDescription {
      case "oneway": kind = .oneway
      case "event": kind = .event
      case "since":
        guard let n = a.arguments?.as(LabeledExprListSyntax.self)?.first?.expression
          .as(IntegerLiteralExprSyntax.self).flatMap({ Int($0.literal.text) }), n >= 1, n <= version
        else { throw ModelError("'\(name)': @since needs a version from 1 to \(version)") }
        since = n
      default: break
      }
    }

    var parameters: [Parameter] = []
    for p in f.signature.parameterClause.parameters {
      var typeSyntax = p.type
      if let attributed = typeSyntax.as(AttributedTypeSyntax.self) { typeSyntax = attributed.baseType }
      let internalName = (p.secondName ?? p.firstName).text
      let type = try resolver.resolve(typeSyntax, "'\(name)': parameter '\(internalName)'")
      let label = p.firstName.text == "_" ? nil : p.firstName.text
      parameters.append(Parameter(label: label, name: internalName, swiftType: typeSyntax.trimmedDescription,
                                  type: type))
    }

    var result: (String, WireType)?
    if let r = f.signature.returnClause?.type, r.trimmedDescription != "Void", r.trimmedDescription != "()" {
      result = (r.trimmedDescription, try resolver.resolve(r, "'\(name)': the result"))
    }

    var errorType: String?
    if let effects = f.signature.effectSpecifiers {
      if effects.asyncSpecifier != nil { throw ModelError("'\(name)': IPC methods are not async") }
      if let clause = effects.throwsClause {
        guard let t = clause.type?.trimmedDescription else {
          throw ModelError("'\(name)': a throwing method declares its error type: throws(E)")
        }
        if t != "Never" {
          guard errors.contains(where: { $0.name == t }) else {
            throw ModelError("'\(name)': error type '\(t)' isn't an error enum of the library")
          }
          errorType = t
        }
      }
    }

    switch kind {
    case .call: break
    case .oneway, .event:
      if result != nil || errorType != nil {
        throw ModelError("'\(name)': a one-way method or event has no result and doesn't throw")
      }
      if kind == .event, parameters.contains(where: { types.hasHandles($0.type) }) {
        throw ModelError("'\(name)': events can't carry handles yet")
      }
    }

    var m = Method(
      name: name, kind: kind, since: since, parameters: parameters, result: result,
      errorType: errorType, ordinal: ordinal(protocolID: protocolID, method: name))
    m.request = Layout(parameters.map { ("a_\($0.name)", $0.type) }, types: types)
    m.reply = Layout(result.map { [("r", $0.1)] } ?? [], types: types)
    return m
  }
}
