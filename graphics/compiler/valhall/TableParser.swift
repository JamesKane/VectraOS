// SPDX-License-Identifier: BSD-3-Clause

// The instruction tables, from text. valhall 10.13 gives every instruction
// as a base word and a field table; Tables*.swift hold those, one line per
// row, in a small notation this file reads (the lines are the spec's
// tables, not a second description):
//
//   F name value=name ...            a family of named values
//   S name item ...                  a field set: item is `field`, `@set`
//                                    (include its fields), or `-field`
//   I MNEMONIC VARIANT CLASS UNIT ARCH BASE SET [stage=w|r|rw] [alias=M.V]
//
// A field is `name@hi:lo[+hi:lo]/kind[!rule][=default]`; `=*` marks a field
// the assembler always writes. Kinds: s S A (sources), r R (registers),
// e.FAMILY or e.{a=0,b=1}, b, u i (immediates), n m o (named operands),
// c c8 c1 (register counts).

/// A table that could not be read.
public enum TableError: Error, Equatable {
  case syntax(String)
}

/// The Valhall instruction table: families, instruction variants and aliases.
public struct ISATable: Sendable {
  public var families: [Family]
  public var defs: [InstructionDef]
  /// Definition indices by class code, for the decoder.
  var byClass: [[Int]]

  /// The table of valhall 11a to 13 for arch 10 to 13.
  public static let shared: ISATable = {
    do {
      return try ISATable.parse(allTableSources)
    } catch {
      fatalError("the Valhall instruction table does not parse")
    }
  }()

  /// Every definition of `mnemonic` (all variants and arches).
  public func defs(mnemonic: String) -> [Int] {
    var out: [Int] = []
    var i = 0
    while i < defs.count {
      if defs[i].mnemonic == mnemonic { out.append(i) }
      i += 1
    }
    return out
  }

  /// The definition of a mnemonic and variant available on `arch`, or nil.
  public func lookup(mnemonic: String, variant: String, arch: Int = 12) -> Int? {
    var i = 0
    while i < defs.count {
      let d = defs[i]
      if d.mnemonic == mnemonic && d.variant == variant && d.available(on: arch) { return i }
      i += 1
    }
    return nil
  }

  public func family(_ index: Int) -> Family { families[index] }

  // MARK: parsing

  private struct Set {
    var name: String
    var fields: [FieldDef]
  }

  static func parse(_ sources: [String]) throws(TableError) -> ISATable {
    var families: [Family] = []
    var familyNames: [String] = []
    var sets: [Set] = []
    var defs: [InstructionDef] = []
    for source in sources {
      for rawLine in source.split(separator: "\n") {
        let line = rawLine.split(separator: " ").map { String($0) }
        guard let head = line.first, !head.hasPrefix("#") else { continue }
        switch head {
        case "F":
          guard line.count >= 3 else { throw .syntax("family: " + String(rawLine)) }
          var f = Family(names: [], values: [])
          for item in line[2...] {
            guard let pair = splitPair(item), let v = UInt64(pair.1) else { throw .syntax("family item " + item) }
            f.names.append(pair.0)
            f.values.append(v)
          }
          familyNames.append(line[1])
          families.append(f)
        case "S":
          guard line.count >= 2 else { throw .syntax("set: " + String(rawLine)) }
          var fields: [FieldDef] = []
          for item in line[2...] {
            if item.hasPrefix("@") {
              let n = String(item.dropFirst())
              var found = false
              for s in sets where s.name == n {
                for f in s.fields { fields = merged(fields, f) }
                found = true
              }
              if !found { throw .syntax("no set " + n) }
            } else if item.hasPrefix("-") {
              let n = String(item.dropFirst())
              var kept: [FieldDef] = []
              for f in fields where f.name != n { kept.append(f) }
              if kept.count == fields.count { throw .syntax("removing absent field " + n) }
              fields = kept
            } else {
              let f = try parseField(item, &families, &familyNames)
              fields = merged(fields, f)
            }
          }
          sets.append(Set(name: line[1], fields: fields))
        case "I":
          guard line.count >= 8 else { throw .syntax("instruction: " + String(rawLine)) }
          try defs.append(parseInstruction(line, defs.count, sets, defs))
        default:
          throw .syntax("line: " + String(rawLine))
        }
      }
    }
    var byClass = [[Int]](repeating: [], count: 32)
    for d in defs { byClass[Int(d.cls.code)].append(d.id) }
    return ISATable(families: families, defs: defs, byClass: byClass)
  }

  private static func merged(_ fields: [FieldDef], _ f: FieldDef) -> [FieldDef] {
    var out = fields
    var i = 0
    while i < out.count {
      if out[i].name == f.name {
        out[i] = f
        return out
      }
      i += 1
    }
    out.append(f)
    return out
  }

  /// `a=b` as two strings, splitting at the first `=` outside braces.
  private static func splitPair(_ s: String) -> (String, String)? {
    var depth = 0
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if c == "{" { depth += 1 }
      if c == "}" { depth -= 1 }
      if c == "=" && depth == 0 { return (String(s[s.startIndex..<i]), String(s[s.index(after: i)...])) }
      i = s.index(after: i)
    }
    return nil
  }

  private static func parseRanges(_ s: String) throws(TableError) -> [BitRange] {
    var out: [BitRange] = []
    for part in s.split(separator: "+") {
      let ends = part.split(separator: ":")
      guard let hi = UInt8(ends[0]) else { throw .syntax("range " + s) }
      let lo = ends.count > 1 ? UInt8(ends[1]) : hi
      guard let lo, lo <= hi, hi < 64 else { throw .syntax("range " + s) }
      out.append(BitRange(hi: hi, lo: lo))
    }
    return out
  }

  private static func role(of name: String) -> FieldRole {
    func index(_ prefix: String) -> Int? {
      guard name.hasPrefix(prefix), name.count == prefix.count + 1, let d = name.last?.wholeNumberValue else {
        return nil
      }
      return d
    }
    if let i = index("src") { return .source(i) }
    if let i = index("neg") { return .negate(i) }
    if let i = index("abs") { return .absolute(i) }
    if let i = index("not") { return .complement(i) }
    if let i = index("wd") { return .lane(i) }
    switch name {
    case "dst": return .destination
    case "dw": return .destinationWidth
    case "sr": return .stagingRegister
    case "sw": return .stagingWriteRegister
    case "sc": return .stagingCount
    case "swc": return .stagingWriteCount
    case "slot": return .slot
    default: return .other
    }
  }

  private static func rule(named s: String) throws(TableError) -> DerivedRule {
    switch s {
    case "const": return .constant
    case "fmul": return .fmulNeg2
    case "f2h": return .f2hNeg1
    case "ldcount": return .loadCount
    case "fmtcount": return .formatCount
    case "var32": return .varBuf32Count
    case "var16": return .varBuf16Count
    case "atomcount": return .atomCount
    case "speccount": return .specialCount
    case "blendcount": return .blendCount
    case "texsingle": return .texSingleRead
    case "texfetch": return .texFetchRead
    case "texgather": return .texGatherRead
    case "texgrad": return .texGradientRead
    case "texwrite": return .texWrite
    case "texdual": return .texDualWrite
    case "vtdual": return .varTexDualWrite
    default: throw .syntax("rule " + s)
    }
  }

  private static func parseField(_ item: String, _ families: inout [Family], _ names: inout [String]) throws(TableError)
    -> FieldDef
  {
    guard let at = item.firstIndex(of: "@"), let slash = item.firstIndex(of: "/") else {
      throw .syntax("field " + item)
    }
    let name = String(item[item.startIndex..<at])
    let ranges = try parseRanges(String(item[item.index(after: at)..<slash]))
    var spec = String(item[item.index(after: slash)...])
    var defaultText = ""
    if let pair = splitPair(spec) {
      spec = pair.0
      defaultText = pair.1
    }
    var ruleName = ""
    if let bang = spec.firstIndex(of: "!") {
      ruleName = String(spec[spec.index(after: bang)...])
      spec = String(spec[spec.startIndex..<bang])
    }
    var f = FieldDef(
      name: name, ranges: ranges, kind: .named, family: -1, defaultValue: 0, required: false, rule: .none,
      role: role(of: name))
    if !ruleName.isEmpty { f.rule = try rule(named: ruleName) }
    if spec.hasPrefix("e.") {
      f.kind = .enumeration
      let body = String(spec.dropFirst(2))
      if body.hasPrefix("{") {
        var fam = Family(names: [], values: [])
        for it in body.dropFirst().dropLast().split(separator: ",") {
          guard let p = splitPair(String(it)), let v = UInt64(p.1) else { throw .syntax("enum " + item) }
          fam.names.append(p.0)
          fam.values.append(v)
        }
        f.family = families.count
        families.append(fam)
        names.append("")
      } else {
        var found = -1
        var i = 0
        while i < names.count {
          if names[i] == body { found = i }
          i += 1
        }
        if found < 0 { throw .syntax("no family " + body + " in " + item) }
        f.family = found
      }
    } else {
      switch spec {
      case "s": f.kind = .src32
      case "S": f.kind = .src64
      case "A": f.kind = .addr64
      case "r": f.kind = .register
      case "R": f.kind = .registerPair
      case "b": f.kind = .flag
      case "u": f.kind = .immediate
      case "i": f.kind = .signedImmediate
      case "n": f.kind = .named
      case "m": f.kind = .namedSigned
      case "o": f.kind = .optional
      case "k": f.kind = .distance8
      case "c": f.kind = .count
      case "c8": f.kind = .count8
      case "c1": f.kind = .countMinusOne
      default: throw .syntax("kind " + spec + " in " + item)
      }
    }
    if (f.kind == .count8 || f.kind == .countMinusOne) && defaultText.isEmpty { f.defaultValue = 1 }
    if defaultText == "*" {
      f.required = true
      if f.family >= 0, families[f.family].name(of: 0) == nil { f.defaultValue = families[f.family].values[0] }
    } else if !defaultText.isEmpty {
      if let v = UInt64(defaultText) {
        f.defaultValue = v
      } else if f.family >= 0, let v = families[f.family].value(named: defaultText) {
        f.defaultValue = v
      } else if let v = Int64(defaultText) {
        f.defaultValue = UInt64(bitPattern: v)
      } else {
        throw .syntax("default " + defaultText + " in " + item)
      }
    }
    return f
  }

  private static func parseInstruction(_ line: [String], _ id: Int, _ sets: [Set], _ defs: [InstructionDef])
    throws(TableError) -> InstructionDef
  {
    // I MNEMONIC VARIANT CLASS UNIT ARCH BASE SET [k=v]...
    let variant = line[2] == "-" ? "" : line[2]
    var classCode: UInt8 = 255
    var c: UInt8 = 0
    while c < 32 {
      if ISAClass(code: c).name == line[3] { classCode = c }
      c += 1
    }
    if classCode == 255 { throw .syntax("class " + line[3]) }
    var unit = Unit.cvt
    switch line[4] {
    case "fma": unit = .fma
    case "cvt": unit = .cvt
    case "sfu": unit = .sfu
    case "msg": unit = .msg
    default: throw .syntax("unit " + line[4])
    }
    let arch = line[5].split(separator: "-")
    guard let lo = Int(arch[0]), let hi = Int(arch[arch.count - 1]) else { throw .syntax("arch " + line[5]) }
    guard line[6].count == 16, let base = UInt64(line[6], radix: 16) else { throw .syntax("base " + line[6]) }
    var fields: [FieldDef] = []
    var found = false
    for s in sets where s.name == line[7] {
      fields = s.fields
      found = true
    }
    if !found { throw .syntax("no set " + line[7]) }
    var staging = StagingDirection.none
    var aliasOf = -1
    for extra in line[8...] {
      guard let p = splitPair(extra) else { throw .syntax("attribute " + extra) }
      switch p.0 {
      case "stage":
        switch p.1 {
        case "w": staging = .write
        case "r": staging = .read
        case "rw": staging = .readWrite
        default: throw .syntax("stage " + p.1)
        }
      case "alias":
        let parts = p.1.split(separator: ".", omittingEmptySubsequences: false)
        let m = String(parts[0])
        let v = parts.count > 1 ? String(parts[1]) : ""
        for d in defs where d.mnemonic == m && d.variant == v && d.archLo <= lo && d.archHi >= lo {
          aliasOf = d.id
        }
        if aliasOf < 0 { throw .syntax("alias target " + p.1) }
      default: throw .syntax("attribute " + extra)
      }
    }
    var free: UInt64 = 0
    for f in fields { free |= f.mask }
    return InstructionDef(
      id: id, mnemonic: line[1], variant: variant, cls: ISAClass(code: classCode), unit: unit, archLo: lo, archHi: hi,
      base: base, fields: fields, staging: staging, aliasOf: aliasOf, freeMask: free)
  }
}
