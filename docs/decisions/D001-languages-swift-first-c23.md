# D1. Languages: Embedded Swift first, C23 where necessary (2026-10-15, decided)

The toolchain is Swift 6.4 (swiftly), with the clang, lld and llvm-objcopy
bundled with it. Tier 0 uses Embedded Swift with `-strict-memory-safety`.
Tier 1 uses full Swift. C23 is allowed for ABI headers, the compiler runtime,
trampolines and code that Embedded Swift cannot express (principle 29).
