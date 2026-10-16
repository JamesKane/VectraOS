// SPDX-License-Identifier: BSD-3-Clause

// The C header idlc writes for a library: its constants, error codes,
// structs and enums with their coders, and for each protocol the request
// encoders, reply and event decoders, and call wrappers, all over
// td_wire.h. It covers the client side; C servers come later.

import IPCModel

/// Writes a library's C header.
public func cHeader(_ l: LibraryModel, source: String) -> String {
  CHeader(library: l).text(source: source)
}

struct CHeader {
  let library: LibraryModel
  var types: Types { library.types }
  var prefix: String { snakeCase(library.name) }

  // MARK: Names and C types

  func typeName(_ name: String) -> String { "\(prefix)_\(snakeCase(name))" }

  func mangle(_ t: WireType) -> String {
    switch t {
    case .integer(let n, _): n.lowercased()
    case .bool: "bool"
    case .string: "str"
    case .bytes: "bytes"
    case .handle: "handle"
    case .enumeration(let n), .structure(let n): snakeCase(n)
    case .vector(let e): "vec_\(mangle(e))"
    case .optional(let w): "opt_\(mangle(w))"
    }
  }

  /// The C type that holds a value of `t`.
  func cType(_ t: WireType) -> String {
    switch t {
    case .integer(let n, _): cInteger(n)
    case .bool: "bool"
    case .string: "td_wire_str_t"
    case .bytes: "td_wire_bytes_t"
    case .handle, .optional(.handle): "uint32_t"
    case .enumeration(let n), .structure(let n): "\(typeName(n))_t"
    case .vector(let e): "\(prefix)_vec_\(mangle(e))_t"
    case .optional(let w): "const \(cType(w)) *"
    }
  }

  func cInteger(_ swiftType: String) -> String {
    switch swiftType {
    case "UInt8": "uint8_t"
    case "Int8": "int8_t"
    case "UInt16": "uint16_t"
    case "Int16": "int16_t"
    case "UInt32": "uint32_t"
    case "Int32": "int32_t"
    case "UInt64": "uint64_t"
    default: "int64_t"
    }
  }

  /// Whether decoding a `t` needs the arena (for vectors' elements and
  /// optional values).
  func needsArena(_ t: WireType) -> Bool {
    switch t {
    case .vector, .optional(.string), .optional(.bytes), .optional(.vector), .optional(.integer),
      .optional(.bool), .optional(.enumeration), .optional(.structure):
      true
    case .structure(let n): types.structure(n)?.fields.contains { needsArena($0.type) } ?? false
    default: false
    }
  }

  // MARK: Encoding

  /// C statements that encode the value `v` of type `t` at body offset `at`.
  func encode(_ t: WireType, _ v: String, at: String, _ d: Int = 0) -> [String] {
    switch t {
    case .integer(_, let size): return ["td_wire_store(m, \(at), (uint64_t)(\(v)), \(size));"]
    case .enumeration(let n): return ["td_wire_store(m, \(at), (uint64_t)(\(v)), \(types.enumeration(n)!.size));"]
    case .bool: return ["td_wire_store(m, \(at), (\(v)) ? 1 : 0, 1);"]
    case .string, .bytes:
      return ["if ((s = td_wire_store_bytes(m, \(at), (\(v)).data, (\(v)).len)) != CROI_OK) return s;"]
    case .handle, .optional(.handle): return ["if ((s = td_wire_store_handle(m, \(at), \(v))) != CROI_OK) return s;"]
    case .structure(let n): return ["if ((s = \(typeName(n))_encode(m, \(at), &(\(v)))) != CROI_OK) return s;"]
    case .vector(let e):
      let size = types.size(e)
      return [
        "{",
        "uint32_t b\(d);",
        "if ((s = td_wire_store_vector(m, \(at), (\(v)).count, \(size), &b\(d))) != CROI_OK) return s;",
        "for (uint32_t i\(d) = 0; i\(d) < (\(v)).count; i\(d)++) {",
      ] + encode(e, "(\(v)).items[i\(d)]", at: "b\(d) + i\(d) * \(size)", d + 1) + ["}", "}"]
    case .optional(let w) where w.hasOwnPresence:
      return ["if (\(v)) {"] + encode(w, "(*(\(v)))", at: at, d + 1) + ["}"]
    case .optional(let w):
      return [
        "if (\(v)) {",
        "uint32_t x\(d);",
        "if ((s = td_wire_store_box(m, \(at), \(types.size(w)), &x\(d))) != CROI_OK) return s;",
      ] + encode(w, "(*(\(v)))", at: "x\(d)", d + 1) + ["}"]
    }
  }

  // MARK: Decoding

  /// C statements that decode a `t` at body offset `at` into the lvalue `lv`.
  func decode(_ t: WireType, into lv: String, at: String, _ d: Int = 0) -> [String] {
    let protocolError = "return TD_ERR_PROTOCOL;"
    switch t {
    case .integer(let n, let size):
      return ["if (td_wire_load(r, \(at), \(size), &v) != CROI_OK) \(protocolError)",
              "\(lv) = (\(cInteger(n)))(uint\(size * 8)_t)v;"]
    case .enumeration(let n):
      let size = types.enumeration(n)!.size
      return ["if (td_wire_load(r, \(at), \(size), &v) != CROI_OK || !\(typeName(n))_known(v)) \(protocolError)",
              "\(lv) = (\(typeName(n))_t)(uint\(size * 8)_t)v;"]
    case .bool:
      return ["{ uint8_t b; if (td_wire_load_bool(r, \(at), &b) != CROI_OK) \(protocolError) \(lv) = b; }"]
    case .string:
      return ["if (td_wire_load_string(r, \(at), &(\(lv)).data, &(\(lv)).len) != CROI_OK) \(protocolError)"]
    case .bytes:
      return ["if (td_wire_load_bytes(r, \(at), &(\(lv)).data, &(\(lv)).len) != CROI_OK) \(protocolError)"]
    case .handle: return ["if (td_wire_load_handle(r, \(at), &(\(lv))) != CROI_OK) \(protocolError)"]
    case .optional(.handle): return ["if (td_wire_load_handle_opt(r, \(at), &(\(lv))) != CROI_OK) \(protocolError)"]
    case .structure(let n): return ["if ((s = \(typeName(n))_decode(r, \(at), a, &(\(lv)))) != CROI_OK) return s;"]
    case .vector(let e):
      let ce = cType(e), size = types.size(e)
      return [
        "{",
        "uint32_t n\(d), b\(d);",
        "if (td_wire_load_vector(r, \(at), \(size), &n\(d), &b\(d)) != 1) \(protocolError)",
        "\(ce) *e\(d) = (\(ce) *)td_wire_alloc(a, n\(d) * (uint32_t)sizeof(\(ce)), (uint32_t)_Alignof(\(ce)));",
        "if (n\(d) && !e\(d)) return CROI_ERR_BUFFER_TOO_SMALL;",
        "for (uint32_t i\(d) = 0; i\(d) < n\(d); i\(d)++) {",
      ] + decode(e, into: "e\(d)[i\(d)]", at: "b\(d) + i\(d) * \(size)", d + 1)
        + ["}", "(\(lv)).items = (const \(ce) *)e\(d);", "(\(lv)).count = n\(d);", "}"]
    case .optional(let w):
      let cw = cType(w)
      let presence = w.hasOwnPresence
        ? ["int p\(d) = td_wire_presence(r, \(at));"]
        : ["uint32_t x\(d)at;", "int p\(d) = td_wire_load_box(r, \(at), \(types.size(w)), &x\(d)at);"]
      return ["{"] + presence + [
        "if (p\(d) < 0) \(protocolError)",
        "\(lv) = NULL;",
        "if (p\(d)) {",
        "\(cw) *x\(d) = (\(cw) *)td_wire_alloc(a, (uint32_t)sizeof(\(cw)), (uint32_t)_Alignof(\(cw)));",
        "if (!x\(d)) return CROI_ERR_BUFFER_TOO_SMALL;",
      ] + decode(w, into: "(*x\(d))", at: w.hasOwnPresence ? at : "x\(d)at", d + 1) + ["\(lv) = x\(d);", "}", "}"]
    }
  }

  // MARK: Types

  func enumeration(_ e: EnumModel) -> String {
    let c = cInteger(e.rawType), name = typeName(e.name)
    let mask: UInt64 = e.size == 8 ? .max : (1 << (8 * UInt64(e.size))) - 1
    let defines = e.cases.map { "#define \(name.uppercased())_\(snakeCase($0.name).uppercased()) ((\(name)_t)\($0.value))" }
    let known = e.cases.map { "v == UINT64_C(\(UInt64(bitPattern: $0.value) & mask))" }.joined(separator: " || ")
    return """

      // enum \(e.name) (\(e.rawType)): receivers reject other values.
      typedef \(c) \(name)_t;
      \(defines.joined(separator: "\n"))
      static inline int \(name)_known(uint64_t v) { return \(known); }
      """
  }

  /// Vector types, inner ones first.
  func vectorTypes() -> [WireType] {
    var found: [WireType] = []
    func visit(_ t: WireType) {
      switch t {
      case .vector(let e):
        visit(e)
        if !found.contains(t) { found.append(t) }
      case .optional(let w): visit(w)
      default: break
      }
    }
    for s in types.structs { s.fields.forEach { visit($0.type) } }
    for p in library.protocols { for m in p.methods { m.types.forEach(visit) } }
    return found
  }

  /// Structs, each after those it holds inline.
  func structOrder() -> [StructModel] {
    var out: [StructModel] = []
    func visit(_ s: StructModel) {
      guard !out.contains(where: { $0.name == s.name }) else { return }
      for f in s.fields { if case .structure(let n) = f.type, let inner = types.structure(n) { visit(inner) } }
      out.append(s)
    }
    types.structs.forEach(visit)
    return out
  }

  func structDefinition(_ s: StructModel) -> String {
    let fields = s.fields.map { "  \(cType($0.type)) \(snakeCase($0.name));" }.joined(separator: "\n")
    return """

      struct \(typeName(s.name)) {
      \(fields)
      };
      """
  }

  func structCoders(_ s: StructModel) -> String {
    let name = typeName(s.name)
    let encodes = s.fields.enumerated().flatMap { i, f in
      encode(f.type, "in->\(snakeCase(f.name))", at: "o + \(s.layout.fields[i].offset)")
    }
    let checks = s.layout.padding.map {
      "if (td_wire_check_padding(r, o + \($0.offset), \($0.count)) != CROI_OK) return TD_ERR_PROTOCOL;"
    }
    let decodes = s.fields.enumerated().flatMap { i, f in
      decode(f.type, into: "out->\(snakeCase(f.name))", at: "o + \(s.layout.fields[i].offset)")
    }
    return """

      static inline int32_t \(name)_encode(td_wire_msg_t *m, uint32_t o, const \(name)_t *in) {
        int32_t s = CROI_OK;
        (void)s;
        \(encodes.joined(separator: "\n  "))
        return CROI_OK;
      }

      static inline int32_t \(name)_decode(td_wire_reader_t *r, uint32_t o, td_wire_arena_t *a, \(name)_t *out) {
        int32_t s = CROI_OK;
        uint64_t v;
        (void)s;
        (void)v;
        (void)a;
        \((checks + decodes).joined(separator: "\n  "))
        return CROI_OK;
      }
      """
  }

  // MARK: Methods

  /// The generated code's own names, which a parameter's C name avoids with
  /// a trailing underscore.
  static let reserved: Set<String> = [
    "m", "s", "v", "r", "rd", "a", "o", "in", "out", "txid", "channel", "buf", "error_code", "arena", "result",
  ]

  func cParameter(_ name: String) -> String {
    let temporary = name.count >= 2 && "bienxp".contains(name.first!) && name.dropFirst().allSatisfy(\.isNumber)
    return Self.reserved.contains(name) || temporary ? name + "_" : name
  }

  /// A parameter's C declarations, and the expression for its value.
  func input(_ swiftName: String, _ t: WireType) -> (decls: [String], value: String) {
    let name = cParameter(swiftName)
    return switch t {
    case .string: (["const char *\(name)", "uint32_t \(name)_len"], "((td_wire_str_t){ \(name), \(name)_len })")
    case .bytes: (["const uint8_t *\(name)", "uint32_t \(name)_len"], "((td_wire_bytes_t){ \(name), \(name)_len })")
    case .structure: (["const \(cType(t)) *\(name)"], "(*\(name))")
    default: (["\(cType(t)) \(name)"], name)
    }
  }

  /// An output's C declarations, and its decoding at `at`.
  func output(_ name: String, _ t: WireType, at: String) -> (decls: [String], decode: [String]) {
    switch t {
    case .string:
      (["const char **\(name)", "uint32_t *\(name)_len"],
       ["if (td_wire_load_string(r, \(at), \(name), \(name)_len) != CROI_OK) return TD_ERR_PROTOCOL;"])
    case .bytes:
      (["const uint8_t **\(name)", "uint32_t *\(name)_len"],
       ["if (td_wire_load_bytes(r, \(at), \(name), \(name)_len) != CROI_OK) return TD_ERR_PROTOCOL;"])
    default: (["\(cType(t)) *\(name)"], decode(t, into: "(*\(name))", at: at))
    }
  }

  func encoder(_ p: ProtocolModel, _ m: Method) -> String {
    let inputs = m.parameters.map { input($0.name, $0.type) }
    let parameters = (["td_wire_msg_t *m", "uint32_t txid"] + inputs.flatMap(\.decls)).joined(separator: ", ")
    var body = ["int32_t s = td_wire_begin(m, txid, TD_WIRE_REQUEST, 0, \(ordinalName(p, m)), \(m.request.size));",
                "if (s != CROI_OK) return s;"]
    // Stores go in field order: out-of-line data follows it.
    for (i, f) in m.request.fields.enumerated() { body += encode(f.type, inputs[i].value, at: "\(f.offset)") }
    body.append("return CROI_OK;")
    let doc = m.kind == .call
      ? "// \(m.name): encodes the request. txid is the caller's, nonzero with bit 31\n// clear, for a client that writes and reads the channel itself; a call\n// (below) leaves it 0 for channel_call to set."
      : "// \(m.name) (one-way): encodes the request. txid must be 0."
    return """

      \(doc)
      static inline int32_t \(functionName(p, m))_encode(\(parameters)) {
        \(body.joined(separator: "\n  "))
      }
      """
  }

  /// A decoder of `layout`, whose fields go to `names`.
  func decoder(_ name: String, _ layout: Layout, names: [String], doc: String) -> String {
    let outputs = zip(layout.fields, names).map { f, n in output(n, f.type, at: "\(f.offset)") }
    let arena = layout.fields.contains { needsArena($0.type) }
    let parameters = (["const td_wire_msg_t *m"] + (arena ? ["td_wire_arena_t *a"] : []) + outputs.flatMap(\.decls))
      .joined(separator: ", ")
    var body = ["td_wire_reader_t rd, *r = &rd;", "int32_t s = CROI_OK;", "uint64_t v;", "(void)s;", "(void)v;"]
    if !arena { body += ["td_wire_arena_t *a = NULL;", "(void)a;"] }
    body.append("if (td_wire_read_begin(r, m, \(layout.size)) != CROI_OK) return TD_ERR_PROTOCOL;")
    body += layout.padding.map {
      "if (td_wire_check_padding(r, \($0.offset), \($0.count)) != CROI_OK) return TD_ERR_PROTOCOL;"
    }
    body += outputs.flatMap(\.decode)
    body.append("return td_wire_read_end(r);")
    return """

      \(doc)
      static inline int32_t \(name)(\(parameters)) {
        \(body.joined(separator: "\n  "))
      }
      """
  }

  func callWrapper(_ p: ProtocolModel, _ m: Method) -> String {
    let name = functionName(p, m)
    let inputs = m.parameters.map { input($0.name, $0.type) }
    let outputs = m.reply.fields.map { output("result", $0.type, at: "\($0.offset)") }
    let arena = m.reply.fields.contains { needsArena($0.type) }
    let parameters = (["uint32_t channel", "td_wire_msg_t *buf", "int32_t *error_code"]
      + inputs.flatMap(\.decls) + (arena ? ["td_wire_arena_t *arena"] : []) + outputs.flatMap(\.decls))
      .joined(separator: ", ")
    let names = { (decls: [String]) in decls.map { String($0.split(separator: " ").last!.drop { $0 == "*" }) } }
    let encodeArgs = (["buf", "0"] + inputs.flatMap { names($0.decls) }).joined(separator: ", ")
    let decodeArgs = (["buf"] + (arena ? ["arena"] : []) + outputs.flatMap { names($0.decls) }).joined(separator: ", ")
    return """

      // \(m.name): calls the method (channel_call) and waits for its reply.
      // buf holds the request, then the reply. Returns TD_ERR_REMOTE with *error_code set if
      // the method failed.
      static inline int32_t \(name)(\(parameters)) {
        int32_t s = \(name)_encode(\(encodeArgs));
        if (s != CROI_OK) return s;
        if ((s = td_wire_call(channel, buf, buf, error_code)) != CROI_OK) return s;
        return \(name)_decode_reply(\(decodeArgs));
      }
      """
  }

  func onewayWrapper(_ p: ProtocolModel, _ m: Method) -> String {
    let name = functionName(p, m)
    let inputs = m.parameters.map { input($0.name, $0.type) }
    let parameters = (["uint32_t channel", "td_wire_msg_t *buf"] + inputs.flatMap(\.decls)).joined(separator: ", ")
    let names = inputs.flatMap { $0.decls.map { String($0.split(separator: " ").last!.drop { $0 == "*" }) } }
    let encodeArgs = (["buf", "0"] + names).joined(separator: ", ")
    return """

      // \(m.name): sends the one-way request.
      static inline int32_t \(name)(\(parameters)) {
        int32_t s = \(name)_encode(\(encodeArgs));
        if (s != CROI_OK) return s;
        return (int32_t)croi_channel_write(channel, 0, buf->bytes, buf->byte_count, buf->handles, buf->handle_count);
      }
      """
  }

  func functionName(_ p: ProtocolModel, _ m: Method) -> String { "\(snakeCase(p.name))_\(snakeCase(m.name))" }
  func ordinalName(_ p: ProtocolModel, _ m: Method) -> String {
    "\(snakeCase(p.name).uppercased())_\(snakeCase(m.name).uppercased())_ORDINAL"
  }

  // MARK: The header

  func text(source: String) -> String {
    let guardName = "\(prefix.uppercased())_IDL_H"
    var out: [String] = []
    func emit(_ s: String) { out.append(s) }

    emit("""
      // SPDX-License-Identifier: BSD-3-Clause
      //
      // Generated by idlc from \(source). Do not edit.
      //
      // Library \(library.id), version \(library.version): the client side in C.
      // Strings are pointer plus length (UTF-8, not NUL-terminated); optional
      // values are pointers, NULL when absent (TD_WIRE_NO_HANDLE for handles).
      // What a reply returns points into the message buffer the call was
      // given, and into the arena for vectors' elements and optional values.

      #ifndef \(guardName)
      #define \(guardName)

      #include <stdbool.h>
      #include <stdint.h>
      #include <td_wire.h>

      #ifdef __cplusplus
      extern "C" {
      #endif
      """)

    for p in library.protocols {
      let upper = snakeCase(p.name).uppercased()
      emit("\n#define \(upper)_PROTOCOL_ID \"\(p.id)\"\n#define \(upper)_VERSION \(p.version)")
      for m in p.methods { emit("#define \(ordinalName(p, m)) UINT64_C(\(hex(m.ordinal)))") }
      if !p.composes.isEmpty {
        emit("// \(p.name) composes \(p.composes.joined(separator: ", ")): their functions work on its channels too.")
      }
    }

    for e in library.errors {
      emit("\n// \(e.name): codes in error replies (td_wire_call returns TD_ERR_REMOTE).")
      for c in e.cases { emit("#define \(snakeCase(e.name).uppercased())_\(snakeCase(c.name).uppercased()) \(c.code)") }
    }

    for e in types.enums { emit(enumeration(e)) }
    if !types.structs.isEmpty {
      emit("")
      for s in types.structs { emit("typedef struct \(typeName(s.name)) \(typeName(s.name))_t;") }
    }
    for v in vectorTypes() {
      guard case .vector(let e) = v else { continue }
      emit("""

        typedef struct \(prefix)_vec_\(mangle(e)) {
          const \(cType(e)) *items;
          uint32_t count;
        } \(cType(v));
        """)
    }
    for s in structOrder() { emit(structDefinition(s)) }
    if !types.structs.isEmpty {
      emit("")
      for s in types.structs {
        let n = typeName(s.name)
        emit("static inline int32_t \(n)_encode(td_wire_msg_t *m, uint32_t o, const \(n)_t *in);")
        emit("static inline int32_t \(n)_decode(td_wire_reader_t *r, uint32_t o, td_wire_arena_t *a, \(n)_t *out);")
      }
    }
    for s in types.structs { emit(structCoders(s)) }

    for p in library.protocols {
      for m in p.methods {
        let name = functionName(p, m)
        switch m.kind {
        case .call:
          emit(encoder(p, m))
          emit(decoder("\(name)_decode_reply", m.reply, names: ["result"], doc: "// \(m.name): decodes the reply."))
          emit(callWrapper(p, m))
        case .oneway:
          emit(encoder(p, m))
          emit(onewayWrapper(p, m))
        case .event:
          emit(decoder("\(name)_decode", m.request, names: m.parameters.map { cParameter($0.name) },
                       doc: "// \(m.name) (event): decodes it."))
        }
      }
    }

    emit("""

      #ifdef __cplusplus
      }
      #endif

      #endif
      """)
    return out.joined(separator: "\n") + "\n"
  }
}
