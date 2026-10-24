# libc

Our libc, in Swift, from ISO C and POSIX (the F track).

## libc (the F track)

`system/libc` is our libc, in Swift, written from ISO C and POSIX
(principle 29): `<string.h>` and, since M4e, `<stdlib.h>`'s integer
conversions and `getenv` (C23's, with `0b`: compared with glibc's
`__isoc23_strtol`). (todhchai's `symbols.tsv`, what tier 1's toolchain's
runtime needs, comes with the toolchain: V2's item 3.) Every function gets a
differential test in `system/libc/tests` against the host's glibc: seeded random
cases, comparing results and whole buffers. memcpy, memmove and memset
go through a dispatch table (`native/dispatch.c`, D128) whose entries
start as the baseline's routines (`Memory.swift`'s, exported as
`td_*_baseline`); the floor has it set for the CPU's tier before any
initializer runs, and then its page is read only. No tier has a routine
of its own yet: one joins when it beats the baseline on the budget it
serves. The `libc` suite checks each entry against the baseline's and
the page's protection. Since M6c it has stdio:
`printf`'s family (`stdio/Format.swift`, exact decimal digits in
`Decimal.swift`) and `strtod`/`strtof` (`stdlib/Strtod.swift`), correctly
rounded, with the variadic entries and `va_list` readers in C
(`native/stdio.c`); `TODHCHAI_FORMAT_CASES` and `TODHCHAI_STRTOD_CASES` run
more cases. Its libm (`system/libc/math`, `<math.h>`): exact functions bit
for bit with glibc, transcendentals within an ulp of the truth (glibc's
80-bit functions, `TODHCHAI_MATH_CASES`). Since M6d, long double:
`strtold` and printf's `%L`, in x87's format on amd64 and binary128's
elsewhere (`Big` and `Digits` are value-generic over their capacity;
binary128 is tested against glibc's `strtof128`/`strfromf128` through the
tests' `TDFloat128` shim; `TODHCHAI_STRTOLD_CASES`), and what libc++
needs: `<ctype.h>`, `<inttypes.h>`, the rest of the integer conversions,
`qsort`, `bsearch`, `strerror_r`, errno set from Swift (`stdlib/Errno.swift`,
`__errno_location`: glibc's hosted, so the tests compare it). Struct
returns and `strtold` are C (`native/stdlib.c`). The file calls are weak
and fail (`native/files.c`, ENOENT for a path, EBADF for a descriptor,
`getcwd` gives "/") until tier 1's fdio defines them. LibC is compiled `-O` in
SwiftPM's debug builds too (unspecialized value generics are slow). Their constants are computed by
`vx mathgen` (`tools/vx/MathgenCommand.swift`); after changing it,
regenerate and commit:

    .build/debug/vx mathgen system/libc/math/generated/Constants.swift

Its pthreads (M5k) are `system/libc/pthread` (`PThread`; since M6c over a
platform layer, `platform/floor` natively, runtime-free, and `platform/hosted`
over Sys for the tests; natively in CMake, `cmake/CroiUser.cmake`, as
part of libc.a), declared by
`system/libc/include/pthread.h` with our layouts (all-zero is a default
object); natively exported under their C names (`pthread/native`). A
thread's record is found through `Sys.ThreadSlot`, one word per thread.
`PThreadTests` compares each call's result with glibc's on the same
scenario and runs the objects under contention; natively, the `libc` suite
(`user/test/swift/LibcSuite.swift`, its C side `LibcSuite.c`) runs them on
croi with printf's family, each arch's long double and ELF TLS. C code
has ELF TLS natively (`_Thread_local`, `errno`): the floor copies the
program's `PT_TLS` (at its load bias, for a static PIE) into each
thread's area in the psABI's layout (`system/sys/floor/Thread.swift`:
variant II on amd64, I on arm64 and rv64, where the thread block is the 64
bytes below the thread pointer); the `libc` suite checks it. Swift code
still has none.

dlopen (M5k) is `system/ld` (`docs/kernel/design/user.md`, "dlopen").
