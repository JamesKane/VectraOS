# riscv64: Swift's calling conventions

Why tier 1 (D47) doesn't build for riscv64, what upstream has done
about it, and what owning the fix would take. Researched 2026-10-16,
against the pinned sources (`pins.txt`: Swift 6.4.0, its LLVM) and
upstream as of that day. The decision to defer stands (roadmap, V2
item 3): rv64 stays tier 0 until rc or FDIO needs tier 1 there.

## What breaks

Three layers, and only the first two fail:

- **clang refuses `swiftcall` on riscv64.**
  `RISCVTargetInfo::checkCallingConvention` doesn't accept `CC_Swift`, so
  the attribute is dropped with a warning, and every `swift_context`
  parameter after it is an error. With our clang
  (`.cache/toolchain/out/bin/clang -target riscv64-unknown-vectraos`):

      warning: 'swiftcall' calling convention is not supported for this target
      error: 'swift_context' parameter can only be used with swiftcall or
             swiftasynccall calling convention

  The Swift runtime's C++ hits this: `include/swift/Runtime/Config.h`
  defines `SWIFT_CC_swift` and `SWIFT_CONTEXT` when
  `__has_attribute(swiftcall)`, and that's true on every target, since
  the attribute is known even where it's refused.
  `__has_extension(swiftcc)` is the per-target answer: true on aarch64,
  false on riscv64.
- **The RISC-V backend has no Swift support.** `LowerFormalArguments`
  has no case for `CallingConv::Swift` ("Unsupported calling
  convention"), there are no registers for `swiftself` or `swifterror`,
  and there are no guaranteed tail calls for `swifttailcc`.
- **swiftc already copes.** `lib/IRGen/IRGenModule.cpp` (`isSwiftCCSupported`,
  `isAsyncCCSupported`) asks clang whether the target takes `CC_Swift`
  and `CC_SwiftAsync`. When it doesn't, Swift functions use the C
  convention, `ShouldUseSwiftError` is false (errors go through memory),
  and async calls are `tail`, not `musttail`: LLVM may make them tail
  calls, and need not. This is why Embedded Swift, tier 0, already runs
  on rv64.

## Upstream

| What | State (2026-10-16) |
|---|---|
| [llvm-project#213448](https://github.com/llvm/llvm-project/pull/213448), "[clang][RISCV] Support the Swift calling convention" | Open, no approval, quiet since 2026-08-13. A RISC-V reviewer asked for tests regenerated with `update_llc_test_checks.py`. |
| [swiftlang/llvm-project#13607](https://github.com/swiftlang/llvm-project/pull/13607) | The same change against Swift's fork. Open. |
| [swiftlang/llvm-project#5551](https://github.com/swiftlang/llvm-project/pull/5551) (2022, with D137309) | The first attempt. Closed unmerged 2026-06-24. |
| [RFC: Expectations about swiftcall implementations](https://discourse.llvm.org/t/rfc-expectations-about-swiftcall-implementations/91560) (rjmccall, 2026-08-13) | What Swift expects of a target's convention, in three stages; stage 1 may land alone. |
| [llvm-project#215915](https://github.com/llvm/llvm-project/pull/215915) | Merged 2026-08-13: `swiftcall` and `swiftasynccall` are ABI-unstable except where Swift has declared a stable ABI (Apple's platforms). |

The RFC's stages:

1. **The convention.** At least 8 GPRs for arguments on a 32-GPR ISA,
   FP registers (hard float unless asked otherwise), 2 to 4 return
   registers consistent with clang's `shouldPassIndirectly`, no stack
   area reserved for register arguments, and `swiftcontext` in a
   normally callee-saved GPR.
2. **`swifterror`** in a GPR that is neither an argument nor a return
   register, preferably normally callee-saved.
3. **`swiftasynccall`**: `musttail` between async functions becomes a
   real tail call even across differing signatures, the callee popping
   its stack arguments; calls to and from non-async functions work both
   ways.

#213448, as its author amended it after the RFC, is stage 1: arguments
in a0-a7 and fa0-fa7, returns in up to 4 registers (a0-a3, fa0-fa3),
`swiftself` in s4 (x20, as AArch64 uses x20), x21 and x22 informally
kept for `swifterror` and async. `swifterror` stays in memory, and
`CC_SwiftAsync` is refused on purpose. The RISC-V reviewer's condition
was a commitment from Swift to the ABI; the RFC is that commitment.
Nobody upstream is working on stage 3.

## Why it isn't done

Who needs what:

- **Apple's RISC-V work is 32-bit and embedded.** In #213448's thread,
  the RISC-V reviewer notes Apple engineers adding RV32 support to
  Mach-O upstream. Embedded Swift has no C++ runtime calling clang's
  `swiftcall`, and swiftc's fallback serves it, as it serves our tier 0.
  Apple ships full Swift (the C++ runtime, async with guaranteed tail
  calls) only on its own arm64 and x86-64 platforms.
- **Full Swift on riscv64 is community work.** The Linux port
  (swift-riscv.com, last release 5.10.1) carries its own patches, and
  both LLVM attempts came from a contributor outside the Swift compiler
  team.

No funded party needs stage 3, so nobody has done it.

## Owning it

Under the 6.4.0 pin this is ours, whatever happens upstream: a change
landing in LLVM now reaches a Swift release after 6.4. The ABI's
instability doesn't touch us, since one toolchain builds everything on
the device.

1. **The runtime's C++.** Two ways, the first cheaper:
   - A swift patch keying `Config.h` on `__has_extension(swiftcc)`, so
     the runtime uses the C convention, agreeing with swiftc's fallback.
     Untested.
   - #213448 as an llvm patch (stage 1): a real convention with the
     context register and 4 returns. Regenerating its tests as asked
     would help it land upstream.
2. **Async (stage 3).** Without guaranteed tail calls, each `await` may
   leave a frame behind, and a long chain of them grows the stack until
   it overflows. The concurrency test in `user/tier1` would show it
   first. The fix is `musttail` for `swifttailcc` in the RISC-V backend,
   callee-popped: [D102613](https://reviews.llvm.org/D102613) (ARM) and
   [D95443](https://reviews.llvm.org/D95443) (AArch64, x86) are the
   models. A medium backend job.

The order, when rc or FDIO needs tier 1 on rv64: step 1, then tier 1's
tests on rv64 to learn whether the concurrency test survives `tail`
calls, then decide on step 2. Neither gates the RV2 (V6b): its kernel
and tier 0 run on the fallback today.
