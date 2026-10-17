// SPDX-License-Identifier: BSD-3-Clause

@testable import Manual
import Testing

@Test func cFunctionsFromAHeader() {
  let header = """
    #pragma once
    /* int hidden(void); */
    typedef struct td_file FILE;
    typedef int (*cmp)(const void *, const void *);
    int printf(const char *__restrict format, ...);   // a comment (with parens)
    FILE *fopen(const char *path,
                const char *mode);
    __attribute__((__noreturn__)) void exit(int status);
    void __td_private(void);
    struct s { int (*f)(void); };
    static inline int inlined(int x) { return x; }
    #ifdef __cplusplus
    extern "C" {
    #endif
    int last(void);
    #ifdef __cplusplus
    }
    #endif
    """
  #expect(Requirements.cFunctions(header) == ["printf", "fopen", "exit", "last"])
}

@Test func publicSwiftNames() {
  let source = """
    public struct Handle: ~Copyable {
      public let raw: UInt32
      var hidden = 0
      public init(raw: UInt32) { self.raw = raw }
      public func close() {}
      public struct Info { public var koid: UInt64 }
    }
    struct Internal { public func no() {} }
    public func sleep(_ ns: UInt64) {}
    extension Handle { public func wait() {} }
    public extension Handle { func bind() {} }
    public enum Clock { case monotonic; public static var now: UInt64 { 0 } }
    """
  #expect(Requirements.publicNames(source) == [
    "Handle", "Handle.raw", "Handle.init", "Handle.close", "Handle.Info", "Handle.Info.koid", "sleep", "Handle.wait",
    "Handle.bind", "Clock", "Clock.now",
  ])
}

@Test func syscallsAndDirectives() {
  #expect(Requirements.syscalls("  CROI_SYS_NULL = 0,\n  CROI_SYS_HANDLE_CLOSE = 10,  // (handles)\n#define X 1\n")
          == ["null", "handle_close"])
  #expect(Requirements.directives("""
    struct M {
      public static let directives: [StaticString] = ["service", "program", "early"]
      let other = ["x"]
    }
    """) == ["service", "program", "early"])
}

@Test func theBacklogsRows() throws {
  let rows = try MissingRow.parse(Array("# a comment\n\nprogram\tls\nsys\tHandle.raw\n".utf8), file: "m").get()
  #expect(rows.map(\.requirement) == [Requirement(.program, "ls"), Requirement(.sys, "Handle.raw")])
  #expect(rows.map(\.line) == [3, 4])
  for bad in ["program ls\n", "tool\tvx\n", "program\tls\nprogram\tls\n"] {
    #expect(throws: MissingRow.Problem.self) { try MissingRow.parse(Array(bad.utf8), file: "m").get() }
  }
}

func manual(_ pages: [(String, String)], missing: String = "") -> Manual {
  var m = Manual()
  for (path, text) in pages { m.add(path: path, bytes: Array(text.utf8)) }
  if case .success(let rows) = MissingRow.parse(Array(missing.utf8), file: "man/missing") { m.missing = rows }
  return m
}

let ls = ("man/1/ls", "page ls 1\nsummary list\nnames ls lc\n\n# DESCRIPTION\n\nSee cat(1) and {the guide|guide(6)#fences}.\n")

@Test func aManualThatChecks() {
  let m = manual([ls, ("man/6/guide", "page guide 6\nsummary format\n\n@node fences Fences\n\nText.\n")],
                 missing: "program\tcat\n")
  let required = [Requirement(.program, "ls"), Requirement(.program, "lc"), Requirement(.program, "cat"),
                  Requirement(.format, "guide")]
  #expect(Check.run(m, requirements: required, root: "/nonexistent", usage: []) == [])
  #expect(m.lookup("lc")?.path == "man/1/ls")
  #expect(m.indexTSV == """
    name\tpage\tsection\tnode\tsummary\tkeys
    ls\tls\t1\t\tlist\t
    lc\tls\t1\t\tlist\t
    guide\tguide\t6\t\tformat\t
    fences\tguide\t6\tfences\tFences\t

    """)
}

@Test func theBacklogOnlyShrinks() {
  let m = manual([ls], missing: "program\tls\nprogram\tgone\n")
  #expect(Check.run(m, requirements: [Requirement(.program, "ls"), Requirement(.program, "new")], root: "/", usage: []) == [
    "man/1/ls:7: cat(1) is no page",
    "man/1/ls:7: guide(6)#fences is no page",
    "no page for program new (section 1, 3, 4, 8), and no row in man/missing",
    "man/missing:1: program ls has a page now; take its row out",
    "man/missing:2: program gone needs no page; take its row out",
  ])
}

@Test func houseRulesAndPlaces() {
  let page = "page x 1\nsummary s \n\n# BUGS\n\n# SYNOPSIS\n\n# Notes\n\n```\n\tok in a fence\n" + String(repeating: "y", count: 81)
    + "\n```\n\ta tab\n"
  let m = manual([("man/2/x", page), ("man/1/y", "page y 1\nsummary s\nnames x\n\n#  \n")])
  #expect(Check.run(m, requirements: [], root: "/", usage: []) == [
    "man/1/y:5: an empty heading",
    "man/2/x:2: a trailing space",
    "man/2/x:12: a fence's line past 80 columns",
    "man/2/x:14: a tab outside a fence",
    "man/2/x:6: SYNOPSIS out of Plan 9's order (SYNOPSIS, DESCRIPTION, EXAMPLES, FILES, SEE ALSO, DIAGNOSTICS, BUGS)",
    "man/2/x:8: a heading is in capitals",
    "man/2/x: its header says x(1), so it belongs at man/1/x",
  ])
}

@Test func usageMessagesFromPages() {
  let m = manual([("man/1/mv", "page mv 1\nsummary move\nnames mv mvx\n\n# SYNOPSIS\n\n```usage\nmv a b\nmvx c\nmv a ... dir\n```\n")])
  guard case .success(let text) = UsageMessages.swift(m, commands: ["mv"]) else {
    Issue.record("no usage")
    return
  }
  #expect(text.hasSuffix("""
    enum Usage {
      static let mv = ["usage: mv a b", "       mv a ... dir"]
    }

    """))
  guard case .failure(let missing) = UsageMessages.swift(m, commands: ["mv", "cp"]) else {
    Issue.record("cp has no page")
    return
  }
  #expect(missing.names == ["cp"])
}
