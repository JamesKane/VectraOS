// SPDX-License-Identifier: BSD-3-Clause

// <ctype.h> (M6d) against the host's glibc in the "C" locale: every class
// and both mappings at EOF and each unsigned char's value; and strerror_r's
// XSI contract: 0, ERANGE when the message is truncated, EINVAL with
// "Unknown error N" for an unknown number, as glibc's __xpg_strerror_r
// (whose words for known numbers are Linux's, ours POSIX's).

import Glibc
@testable import LibC
import Testing

@Test func ctypeMatchesGlibcInTheCLocale() {
  setlocale(LC_ALL, "C")
  typealias Pair = (String, (Int32) -> Int32, (Int32) -> Int32)
  let pairs: [Pair] = [
    ("isalnum", { Glibc.isalnum($0) }, LibC.isalnum), ("isalpha", { Glibc.isalpha($0) }, LibC.isalpha),
    ("isblank", { Glibc.isblank($0) }, LibC.isblank), ("iscntrl", { Glibc.iscntrl($0) }, LibC.iscntrl),
    ("isdigit", { Glibc.isdigit($0) }, LibC.isdigit), ("isgraph", { Glibc.isgraph($0) }, LibC.isgraph),
    ("islower", { Glibc.islower($0) }, LibC.islower), ("isprint", { Glibc.isprint($0) }, LibC.isprint),
    ("ispunct", { Glibc.ispunct($0) }, LibC.ispunct), ("isspace", { Glibc.isspace($0) }, LibC.isspace),
    ("isupper", { Glibc.isupper($0) }, LibC.isupper), ("isxdigit", { Glibc.isxdigit($0) }, LibC.isxdigit),
  ]
  for c in Int32(-1)...255 {
    for (name, host, ours) in pairs {
      #expect((host(c) != 0) == (ours(c) != 0), "\(name)(\(c))")
    }
    #expect(Glibc.tolower(c) == LibC.tolower(c), "tolower(\(c))")
    #expect(Glibc.toupper(c) == LibC.toupper(c), "toupper(\(c))")
  }
}

typealias XSIStrerror = @convention(c) (Int32, UnsafeMutablePointer<CChar>?, Int) -> Int32

@Test func strerrorRFollowsXSI() throws {
  let glibcs = try #require(dlsym(nil, "__xpg_strerror_r").map { unsafeBitCast($0, to: XSIStrerror.self) })
  // The numbers our <errno.h> defines, and some neither knows (Linux's
  // run to 134 here; ours are a subset so far).
  for errnum in Int32(-3)...210 where LibC.errorMessage(errnum) != nil || errnum < 0 || errnum > 200 {
    for size in [0, 1, 5, 16, 64] {
      var host = [CChar](repeating: 0x7F, count: 64), ours = host
      let h = glibcs(errnum, &host, size), o = LibC.strerror_r(errnum, &ours, size)
      if let message = LibC.errorMessage(errnum) {
        // Known: our words (POSIX's), so the truncation is by their length.
        #expect(o == (message.utf8CodeUnitCount < size ? 0 : ERANGE), "strerror_r(\(errnum), \(size)): \(o)")
      } else {
        #expect(h == o, "strerror_r(\(errnum), \(size)): glibc \(h), ours \(o)")
      }
      if size > 0 {
        let text = String(cString: ours)
        #expect(text.utf8.count < size, "strerror_r(\(errnum), \(size)) is terminated in the buffer")
        if size == 64 && (h != 0 || errnum == 0) {
          // Unknown numbers have the same words; known ones are POSIX's.
          if h != 0 { #expect(String(cString: host) == text, "strerror_r(\(errnum))'s text") }
        }
      }
    }
  }
}
