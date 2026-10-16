// SPDX-License-Identifier: BSD-3-Clause

// <ctype.h> (C23 §7.4, M6d) in the "C" locale, the only one: §7.4.1's
// classes over the 128 ASCII values (the rest, and EOF, in none), and
// §7.4.2's case mapping. An argument outside unsigned char's values and
// EOF is undefined; here it is in no class and maps to itself.

@inline(__always) func inRange(_ c: Int32, _ low: UInt8, _ high: UInt8) -> Bool { c >= low && c <= high }

public func isdigit(_ c: Int32) -> Int32 { inRange(c, 0x30, 0x39) ? 1 : 0 }
public func isupper(_ c: Int32) -> Int32 { inRange(c, 0x41, 0x5A) ? 1 : 0 }
public func islower(_ c: Int32) -> Int32 { inRange(c, 0x61, 0x7A) ? 1 : 0 }
public func isalpha(_ c: Int32) -> Int32 { isupper(c) | islower(c) }
public func isalnum(_ c: Int32) -> Int32 { isalpha(c) | isdigit(c) }
public func isxdigit(_ c: Int32) -> Int32 { isdigit(c) | (inRange(c, 0x41, 0x46) || inRange(c, 0x61, 0x66) ? 1 : 0) }
public func isblank(_ c: Int32) -> Int32 { c == 0x20 || c == 0x09 ? 1 : 0 }
public func isspace(_ c: Int32) -> Int32 { c == 0x20 || inRange(c, 0x09, 0x0D) ? 1 : 0 }
public func iscntrl(_ c: Int32) -> Int32 { inRange(c, 0x00, 0x1F) || c == 0x7F ? 1 : 0 }
public func isprint(_ c: Int32) -> Int32 { inRange(c, 0x20, 0x7E) ? 1 : 0 }
public func isgraph(_ c: Int32) -> Int32 { inRange(c, 0x21, 0x7E) ? 1 : 0 }
public func ispunct(_ c: Int32) -> Int32 { isgraph(c) != 0 && isalnum(c) == 0 ? 1 : 0 }
public func tolower(_ c: Int32) -> Int32 { isupper(c) != 0 ? c + 0x20 : c }
public func toupper(_ c: Int32) -> Int32 { islower(c) != 0 ? c - 0x20 : c }
