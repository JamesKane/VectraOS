// SPDX-License-Identifier: BSD-3-Clause

// Writes a library's generated members as Swift source. Every encode and
// decode follows the model's layouts, field by field, so the code is the
// wire format spelled out (docs/wire-format.md).

import IPCModel
import SwiftSyntax

struct Generator {
  let library: LibraryModel
  var types: Types { library.types }
  var access: String { library.isPublic ? "public " : "" }

  func declarations() -> [DeclSyntax] {
    var out: [String] = []
    for s in types.structs { out += [structEncoder(s), structDecoder(s)] }
    for p in library.protocols {
      out += p.methods.map { "static let \(traceName(p, $0)) = TraceName(\"\(p.name).\($0.name)\")" }
      out += p.methods.map { argumentsStruct(p, $0) }
      out += [client(p), handler(p), server(p), events(p)]
    }
    return out.map { DeclSyntax(stringLiteral: $0) }
  }

  // MARK: Names

  func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
  func traceName(_ p: ProtocolModel, _ m: Method) -> String { "_trace_\(p.name)_\(m.name)" }
  func argumentsName(_ p: ProtocolModel, _ m: Method) -> String { "_\(p.name)_\(m.name)_Arguments" }
  func errorType(_ m: Method) -> String { m.errorType ?? "Never" }
  /// "ticked" → "Ticked"
  func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
  /// "Node" → "node"
  func lowercasedFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

  /// A composed protocol's generated `suffix` type, as `p`'s code names it:
  /// "NodeIPC.Node" → "NodeIPC.NodeHandler"; "Attributes" → "AttributesHandler".
  func composed(_ name: String, _ suffix: String) -> String { name + suffix }
  /// The library enum a composed protocol is in, and its bare name.
  func split(_ name: String) -> (library: String, name: String) {
    let parts = name.split(separator: ".")
    return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (library.name, name)
  }
  func dispatchName(_ protocolName: String) -> String { "_dispatch_\(protocolName)" }

  /// The Swift type of a wire type, as generated code spells it.
  func swiftType(_ t: WireType) -> String { t.swiftName }

  // MARK: Encoding

  /// Statements that encode `value` (an expression, consumed if it isn't
  /// copyable) of type `t` at offset `at` from the body's start.
  func encode(_ t: WireType, _ value: String, at: String, _ depth: Int = 0) -> [String] {
    switch t {
    case .integer: return ["try e.store(\(value), at: \(at))"]
    case .bool: return ["try e.storeBool(\(value), at: \(at))"]
    case .string: return ["try e.storeString(\(value), at: \(at))"]
    case .bytes: return ["try e.storeByteArray(\(value), at: \(at))"]
    case .handle: return ["try e.storeHandle(\(value).release(), at: \(at))"]
    case .enumeration: return ["try e.store(\(value).rawValue, at: \(at))"]
    case .structure(let n): return ["try _encode_\(n)(\(value), &e, at: \(at))"]
    case .vector(let element):
      let items = "items\(depth)", base = "base\(depth)", i = "i\(depth)", x = "x\(depth)"
      return [
        "do {",
        "let \(items) = \(value)",
        "let \(base) = try e.storeVector(count: \(items).count, elementSize: \(types.size(element)), at: \(at))",
        "for (\(i), \(x)) in \(items).enumerated() {",
      ] + encode(element, x, at: "\(base) + \(i) * \(types.size(element))", depth + 1) + ["}", "}"]
    case .optional(let w):
      let x = "x\(depth)"
      // An absent value leaves its marker zero, as reserved.
      let present = w.hasOwnPresence
        ? encode(w, x, at: at, depth + 1)
        : ["let box\(depth) = try e.storeBox(size: \(types.size(w)), at: \(at))"]
          + encode(w, x, at: "box\(depth)", depth + 1)
      if types.isCopyable(w) {
        return ["if let \(x) = \(value) {"] + present + ["}"]
      }
      // `consume` takes a local, so the value moves into one first.
      return ["let o\(depth) = \(value)", "switch consume o\(depth) {", "case .some(let \(x)):"] + present
        + ["case .none: break", "}"]
    }
  }

  func structEncoder(_ s: StructModel) -> String {
    let ownership = s.isCopyable ? "borrowing" : "consuming"
    // A consumed struct is taken apart field by field.
    let take = s.isCopyable ? [] : ["let v = v"]
    let body = s.fields.enumerated().flatMap { i, f in
      encode(f.type, "v.\(f.name)", at: "o + \(s.layout.fields[i].offset)")
    }
    return """
      @_lifetime(e: copy e)
      static func _encode_\(s.name)(_ v: \(ownership) \(s.name), _ e: inout Encoder, at o: Int) throws(WireError) {
      \((take + body).joined(separator: "\n"))
      }
      """
  }

  // MARK: Decoding

  /// Statements that decode a value of type `t` at offset `at` into a new
  /// constant `name`.
  func decode(_ t: WireType, into name: String, at: String, _ depth: Int = 0) -> [String] {
    switch t {
    case .integer(let type, _): return ["let \(name) = try d.load(\(type).self, at: \(at))"]
    case .bool: return ["let \(name) = try d.loadBool(at: \(at))"]
    case .string: return ["let \(name) = try d.loadString(at: \(at))"]
    case .bytes: return ["let \(name) = try d.loadByteArray(at: \(at))"]
    case .handle: return ["let \(name) = Handle(raw: try d.loadRequiredHandle(at: \(at)))"]
    case .enumeration(let n):
      let raw = types.enumeration(n)!.rawType
      return ["guard let \(name) = \(n)(rawValue: try d.load(\(raw).self, at: \(at))) else { throw .invalidValue }"]
    case .structure(let n): return ["let \(name) = try _decode_\(n)(&d, at: \(at))"]
    case .vector(let element):
      return ["guard let vec\(depth) = try d.loadVector(at: \(at), elementSize: \(types.size(element))) else { throw .badPresence }"]
        + vectorElements(element, into: name, depth)
    case .optional(let w):
      switch w {
      case .string: return ["let \(name) = try d.loadOptionalString(at: \(at))"]
      case .bytes: return ["let \(name) = try d.loadOptionalByteArray(at: \(at))"]
      case .handle:
        return ["let \(name): Handle? = if let raw = try d.loadHandle(at: \(at)) { Handle(raw: raw) } else { nil }"]
      case .vector(let element):
        return [
          "var \(name): \(swiftType(t)) = nil",
          "if let vec\(depth) = try d.loadVector(at: \(at), elementSize: \(types.size(element))) {",
        ] + vectorElements(element, into: "a\(depth)", depth) + ["\(name) = a\(depth)", "}"]
      default:
        return [
          "var \(name): \(swiftType(t)) = nil",
          "if let box\(depth) = try d.loadBox(at: \(at), size: \(types.size(w))) {",
        ] + decode(w, into: "x\(depth)", at: "box\(depth)", depth + 1) + ["\(name) = x\(depth)", "}"]
      }
    default:
      fatalError("unreachable")
    }
  }

  /// Decodes vector `vec<depth>`'s elements into a new array `name`.
  func vectorElements(_ element: WireType, into name: String, _ depth: Int) -> [String] {
    let i = "i\(depth)", x = "x\(depth)"
    return [
      "var \(name): [\(swiftType(element))] = []",
      "\(name).reserveCapacity(vec\(depth).count)",
      "for \(i) in 0..<vec\(depth).count {",
    ] + decode(element, into: x, at: "vec\(depth).base + \(i) * \(types.size(element))", depth + 1)
      + ["\(name).append(\(x))", "}"]
  }

  func paddingChecks(_ layout: Layout, base: String) -> [String] {
    layout.padding.map { "try d.checkPadding(at: \(base)\($0.offset), count: \($0.count))" }
  }

  func structDecoder(_ s: StructModel) -> String {
    let body = paddingChecks(s.layout, base: "o + ")
      + s.fields.enumerated().flatMap { i, f in decode(f.type, into: "f\(i)", at: "o + \(s.layout.fields[i].offset)") }
    let arguments = s.fields.enumerated().map { i, f in "\(f.name): f\(i)" }.joined(separator: ", ")
    return """
      @_lifetime(d: copy d)
      static func _decode_\(s.name)(_ d: inout Decoder, at o: Int) throws(WireError) -> \(s.name) {
      \(body.joined(separator: "\n"))
      return \(s.name)(\(arguments))
      }
      """
  }

  /// A closure body that decodes `layout` (a message body) and returns
  /// `result`, built from the decoded fields `f0`, `f1`...
  func bodyDecoder(_ layout: Layout, returning result: String) -> String {
    (paddingChecks(layout, base: "")
      + layout.fields.enumerated().flatMap { i, f in decode(f.type, into: "f\(i)", at: "\(f.offset)") }
      + ["return \(result)"]).joined(separator: "\n")
  }

  /// A closure body that encodes `layout`, the field at `i` from `value(i)`.
  func bodyEncoder(_ layout: Layout, _ value: (Int) -> String) -> String {
    layout.fields.enumerated().flatMap { i, f in encode(f.type, value(i), at: "\(f.offset)") }
      .joined(separator: "\n")
  }

  // MARK: Signatures

  /// A parameter's type in a signature: values that move are consumed.
  func parameterType(_ p: Parameter) -> String {
    types.isCopyable(p.type) ? p.swiftType : "consuming \(p.swiftType)"
  }

  func parameterList(_ m: Method) -> String {
    m.parameters.map { p in
      let label = p.label.map { $0 == p.name ? $0 : "\($0) \(p.name)" } ?? "_ \(p.name)"
      return "\(label): \(parameterType(p))"
    }.joined(separator: ", ")
  }

  func throwsClause(_ m: Method) -> String { m.errorType.map { " throws(\($0))" } ?? "" }
  func resultClause(_ m: Method) -> String { m.result.map { " -> \($0.swiftType)" } ?? "" }

  /// Statements that move values the encoder will consume into optionals
  /// it can take them from: a closure can't consume what it captures.
  func movable(_ items: [(name: String, swiftType: String, copyable: Bool)]) -> [String] {
    items.filter { !$0.copyable }.map { "var m_\($0.name): \($0.swiftType)? = \($0.name)" }
  }

  func valueExpression(_ name: String, copyable: Bool) -> String { copyable ? name : "m_\(name).take()!" }

  // MARK: Arguments

  /// A request's decoded arguments: a struct, since a tuple can't hold
  /// values that aren't copyable.
  func argumentsStruct(_ p: ProtocolModel, _ m: Method) -> String {
    let fields = m.parameters.enumerated().map { i, p in "var a\(i): \(p.swiftType)" }.joined(separator: "\n")
    return """
      struct \(argumentsName(p, m)): ~Copyable {
      \(fields)
      }
      """
  }

  /// The decoded fields of a request, as its arguments struct.
  func argumentsValue(_ p: ProtocolModel, _ m: Method) -> String {
    let fields = m.parameters.indices.map { "a\($0): f\($0)" }.joined(separator: ", ")
    return "\(argumentsName(p, m))(\(fields))"
  }

  // MARK: Client

  /// The protocols of this library `p` composes, directly or through
  /// others of it, each once; and those of other libraries it reaches.
  func composition(_ p: ProtocolModel) -> (local: [ProtocolModel], foreign: [String]) {
    var local: [ProtocolModel] = [], foreign: [String] = []
    func visit(_ p: ProtocolModel) {
      for c in p.composes {
        if c.contains(".") {
          if !foreign.contains(c) { foreign.append(c) }
        } else if let target = library.protocols.first(where: { $0.name == c }), !local.contains(where: { $0.name == c }) {
          local.append(target)
          visit(target)
        }
      }
    }
    visit(p)
    return (local, foreign)
  }

  func client(_ p: ProtocolModel) -> String {
    // Its own calls, and those of protocols of this library it composes:
    // the macro sees those, so their calls are flattened in.
    let (local, foreign) = composition(p)
    let calls = ([p] + local).flatMap { q in q.methods.filter { $0.kind != .event }.map { clientMethod(q, $0) } }
      .joined(separator: "\n\n")
    let nextEvent = p.methods.contains { $0.kind == .event } || !p.composes.isEmpty ? """

      /// The next event, waiting until `deadline` (monotonic nanoseconds).
      public mutating func nextEvent(deadline: Int64 = infiniteDeadline) throws(IPCError<Never>) -> \(p.name)Event {
        let (header, message) = try connection.nextEvent(deadline: deadline)
        return try \(p.name)Event.decode(header, message)
      }
      """ : ""
    // Another library's protocol: its calls go through a client of it that
    // borrows this one's connection: `dir.node { try $0.walk(["a"]) }`.
    let lenders = foreign.map { c in
      let name = split(c).name
      return """
        /// Lends the connection to a `\(name)` client for `body`.
        public mutating func \(lowercasedFirst(name))<R: ~Copyable, E: Error>(_ body: (inout \(c)Client) throws(E) -> R) throws(E) -> R {
          var view = \(c)Client(connection: connection)
          var result: R? = nil
          var failure: E? = nil
          do throws(E) { result = try body(&view) } catch { failure = error }
          self = \(p.name)Client(connection: view.takeConnection())
          switch consume result {
          case .some(let r): return r
          case .none: throw failure!
          }
        }
        """
    }.joined(separator: "\n\n")
    return """
      /// Calls `\(p.name)` over a channel. Generated by @IPCLibrary.
      \(access)struct \(p.name)Client: ~Copyable {
        public var connection: IPCClientConnection

        public init(channel: consuming Handle) {
          connection = IPCClientConnection(channel: channel)
        }

        /// A client on a connection another client had: the channel, as
        /// another protocol it speaks.
        public init(connection: consuming IPCClientConnection) {
          self.connection = connection
        }

        public consuming func takeConnection() -> IPCClientConnection { connection }

      \(calls)
      \(lenders)
      \(nextEvent)
      }
      """
  }

  func clientMethod(_ p: ProtocolModel, _ m: Method) -> String {
    let e = errorType(m)
    let moves = movable(m.parameters.map { ($0.name, $0.swiftType, types.isCopyable($0.type)) })
    let body = bodyEncoder(m.request) { i in
      valueExpression(m.parameters[i].name, copyable: types.isCopyable(m.parameters[i].type))
    }
    var lines = moves + [
      """
      let request = try IPCCodec.encode(
        MessageHeader(txid: 0, kind: .request, ordinal: \(hex(m.ordinal))), inlineSize: \(m.request.size), \(e).self
      ) { (e: inout Encoder) throws(WireError) in
      \(body)
      }
      """,
    ]
    if m.kind == .oneway {
      lines.append("try connection.send(request, \(e).self)")
    } else {
      let resultType = m.result?.swiftType ?? "Void"
      lines.append("let reply = try connection.call(request, \(e).self, trace: \(library.name).\(traceName(p, m)))")
      lines.append("""
        return try IPCCodec.decode(reply, inlineSize: \(m.reply.size), \(e).self) { (d: inout Decoder) throws(WireError) -> \(resultType) in
        \(bodyDecoder(m.reply, returning: m.result == nil ? "()" : "f0"))
        }
        """)
    }
    return """
      public mutating func \(m.name)(\(parameterList(m))) throws(IPCError<\(e)>)\(resultClause(m)) {
      \(lines.joined(separator: "\n"))
      }
      """
  }

  // MARK: Handler

  func handler(_ p: ProtocolModel) -> String {
    let requirements = p.methods.filter { $0.kind != .event }.map { m in
      "mutating func \(m.name)(\(parameterList(m)))\(throwsClause(m))\(resultClause(m))"
    }.joined(separator: "\n")
    return """
      /// What a `\(p.name)` server implements. Generated by @IPCLibrary.
      \(access)protocol \(p.name)Handler\(p.composes.isEmpty ? "" : ": " + p.composes.map { composed($0, "Handler") }.joined(separator: ", ")) {
      \(requirements)
      }
      """
  }

  // MARK: Server

  func server(_ p: ProtocolModel) -> String {
    let cases = p.methods.filter { $0.kind != .event }.map { serverCase(p, $0) }.joined(separator: "\n")
    // Requests for composed protocols' methods go to their dispatchers.
    let delegations = p.composes.map { c in
      let (lib, name) = split(c)
      return "if try \(lib).\(dispatchName(name))(header, message, &impl, &connection) { return true }"
    }.joined(separator: "\n")
    return """
      /// Serves one request for `\(p.name)` (or a protocol it composes): false
      /// if the ordinal isn't one of theirs. For servers of protocols that
      /// compose it. Generated by @IPCLibrary.
      \(access)static func \(dispatchName(p.name))<Impl: \(p.name)Handler>(
        _ header: MessageHeader, _ message: IPCMessage, _ impl: inout Impl, _ connection: inout IPCServerConnection
      ) throws(IPCError<Never>) -> Bool {
        switch header.ordinal {
      \(cases)
        default:
      \(delegations)
          return false
        }
        return true
      }

      /// Sends `\(p.name)`'s events on any server's connection: its own
      /// server's, or that of a protocol composing it. Generated by @IPCLibrary.
      \(access)enum \(p.name)EventSender {
      \(p.methods.filter { $0.kind == .event }.map(eventSender).joined(separator: "\n\n"))
      }

      /// Serves `\(p.name)` on a channel, calling a handler. Generated by @IPCLibrary.
      \(access)struct \(p.name)Server<Impl: \(p.name)Handler>: ~Copyable, IPCServing {
        public var connection: IPCServerConnection
        public var impl: Impl

        public init(channel: consuming Handle, impl: Impl) {
          connection = IPCServerConnection(channel: channel)
          self.impl = impl
        }

        /// Serves requests until the client closes its end.
        public mutating func serve() throws(IPCError<Never>) {
          while try handleNext() {}
        }

        /// Serves one request, waiting until `deadline` for it (`timedOut`
        /// if none came); false once the client has closed its end.
        public mutating func handleNext(deadline: Int64 = infiniteDeadline) throws(IPCError<Never>) -> Bool {
          guard let (header, message) = try connection.nextRequest(deadline: deadline) else { return false }
          if try !\(library.name).\(dispatchName(p.name))(header, message, &impl, &connection) {
            try connection.unknownMethod(header, message)
          }
          return true
        }

      \(p.methods.filter { $0.kind == .event }.map { forwardingSender(p, $0) }.joined(separator: "\n\n"))
      }
      """
  }

  func serverCase(_ p: ProtocolModel, _ m: Method) -> String {
    let trace = "\(library.name).\(traceName(p, m))"
    let arguments = m.parameters.enumerated().map { i, p in
      p.label.map { "\($0): args.a\(i)" } ?? "args.a\(i)"
    }.joined(separator: ", ")
    let invoke = "\(m.errorType == nil ? "" : "try ")impl.\(m.name)(\(arguments))"
    var body = """
          try connection.expect(header, twoWay: \(m.kind == .call), message)
          connection.received(header, trace: \(trace))
          let args = try IPCCodec.decode(message, inlineSize: \(m.request.size), Never.self) { (d: inout Decoder) throws(WireError) -> \(library.name).\(argumentsName(p, m)) in
      \(bodyDecoder(m.request, returning: "\(library.name).\(argumentsValue(p, m))"))
          }
      """
    if m.kind == .oneway {
      body += "\n\(invoke)"
    } else {
      let copyable = m.result.map { types.isCopyable($0.type) } ?? true
      let moves = m.result.map { movable([("r", $0.swiftType, copyable)]) } ?? []
      let store = bodyEncoder(m.reply) { _ in valueExpression("r", copyable: copyable) }
      let send = (moves + ["""
        let replyMessage = try IPCCodec.encode(
          MessageHeader(txid: header.txid, kind: .reply, ordinal: header.ordinal), inlineSize: \(m.reply.size), Never.self
        ) { (e: inout Encoder) throws(WireError) in
        \(store)
        }
        try connection.reply(replyMessage, to: header, trace: \(trace))
        """]).joined(separator: "\n")
      if let errorType = m.errorType {
        // The handler's error is caught alone: an error reply, then on to
        // the next request.
        let declare = m.result.map { "let r: \($0.swiftType)" } ?? ""
        let assign = m.result == nil ? invoke : "r = \(invoke)"
        body += """

          \(declare)
          do throws(\(errorType)) {
            \(assign)
          } catch {
            try connection.replyError(to: header, code: error.code)
            return true
          }
          \(send)
          """
      } else {
        let produce = m.result == nil ? invoke : "let r = \(invoke)"
        body += "\n\(produce)\n\(send)"
      }
    }
    return """
          case \(hex(m.ordinal)):  // \(m.name)
      \(body)
      """
  }

  func eventSender(_ m: Method) -> String {
    let body = bodyEncoder(m.request) { i in m.parameters[i].name }
    let parameters = parameterList(m)
    return """
      /// Sends the `\(m.name)` event on `connection`.
      public static func send\(capitalized(m.name))(\(parameters)\(parameters.isEmpty ? "" : ", ")on connection: borrowing IPCServerConnection) throws(IPCError<Never>) {
        let event = try IPCCodec.encode(
          MessageHeader(txid: 0, kind: .event, ordinal: \(hex(m.ordinal))), inlineSize: \(m.request.size), Never.self
        ) { (e: inout Encoder) throws(WireError) in
      \(body)
        }
        try connection.send(event)
      }
      """
  }

  /// The server's own sender, which the sender enum's does the work of.
  func forwardingSender(_ p: ProtocolModel, _ m: Method) -> String {
    let arguments = m.parameters.map { p in (p.label.map { "\($0): " } ?? "") + p.name }
    return """
      /// Sends the `\(m.name)` event.
      public func send\(capitalized(m.name))(\(parameterList(m))) throws(IPCError<Never>) {
        try \(p.name)EventSender.send\(capitalized(m.name))(\((arguments + ["on: connection"]).joined(separator: ", ")))
      }
      """
  }

  // MARK: Events

  func events(_ p: ProtocolModel) -> String {
    let events = p.methods.filter { $0.kind == .event }
    let cases = events.map { m in
      let associated = m.parameters.map { p in p.label.map { "\($0): \(p.swiftType)" } ?? p.swiftType }
        .joined(separator: ", ")
      return "case \(m.name)" + (associated.isEmpty ? "" : "(\(associated))")
    }.joined(separator: "\n")
    let decodeCases = events.map { m in
      let args = m.parameters.enumerated().map { i, p in p.label.map { "\($0): args.a\(i)" } ?? "args.a\(i)" }
        .joined(separator: ", ")
      return """
          case \(hex(m.ordinal)):
            let args = try IPCCodec.decode(message, inlineSize: \(m.request.size), Never.self) { (d: inout Decoder) throws(WireError) -> \(library.name).\(argumentsName(p, m)) in
        \(bodyDecoder(m.request, returning: "\(library.name).\(argumentsValue(p, m))"))
            }
            return .\(m.name)\(m.parameters.isEmpty ? "" : "(\(args))")
        """
    }.joined(separator: "\n")
    // A composed protocol's events arrive wrapped: `.node(.changed(...))`.
    let composedCases = p.composes.map { c in "case \(lowercasedFirst(split(c).name))(\(c)Event)" }
      .joined(separator: "\n")
    let composedDecodes = p.composes.map { c in
      "if let e = try \(c)Event._decodeIfKnown(header, message) { return .\(lowercasedFirst(split(c).name))(e) }"
    }.joined(separator: "\n")
    return """
      /// The events of `\(p.name)`. Generated by @IPCLibrary.
      \(access)enum \(p.name)Event {
      \(cases)
      \(composedCases)

        static func decode(_ header: MessageHeader, _ message: IPCMessage) throws(IPCError<Never>) -> \(p.name)Event {
      \(events.isEmpty && p.composes.isEmpty ? "" : "guard let event = try _decodeIfKnown(header, message) else {")
            message.closeHandles()
            throw .wire(.unexpectedMessage)
      \(events.isEmpty && p.composes.isEmpty ? "" : "}\nreturn event")
        }

        /// The event, or nil if its ordinal isn't one of `\(p.name)`'s (the
        /// message is untouched then).
        public static func _decodeIfKnown(_ header: MessageHeader, _ message: IPCMessage) throws(IPCError<Never>) -> \(p.name)Event? {
          switch header.ordinal {
      \(decodeCases)
          default:
      \(composedDecodes)
            return nil
          }
        }
      }
      """
  }
}
