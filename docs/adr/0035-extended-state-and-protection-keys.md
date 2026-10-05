# ADR-0035: Extended register state and protection keys

Status: accepted, 2026-10-05. M6 step 6c's changes to the ABI (01 §3): the FP/SIMD state as the hardware saves it (6c1), what user code learns of the CPU (6c1, for 6c3's dispatch), and protection keys (6c4, 6c5). No new syscall: two `thread_state` ops, a flag field on `as_map` and `as_protect`, two calls `as_key_alloc` and `as_key_free`, and an exception kind.

## Context

Until now x86_64 saves FXSAVE's 512 bytes at each switch and leaves OSXSAVE off, so AVX faults in user code; aarch64 saves V0-V31, FPCR and FPSR. `vx_fpregs` is exactly those images, and a debugger reads and writes them with `thread_state`'s `GET_FPREGS` and `SET_FPREGS`.

6c turns on everything the CPU has (01 §11; decided 2026-10-05: userland's baseline is x86-64-v3 and armv8.2-a, with AVX-512 and SVE by runtime dispatch). That brings three needs:

- **State larger than FXSAVE's,** of a size only CPUID knows: AVX's upper halves, AVX-512's mask and upper registers, and later PKRU. A debugger must reach all of it.
- **What the CPU has, from user code,** for runtime dispatch. On x86_64 user code has CPUID and XGETBV. On aarch64 the ID registers trap at EL0.
- **Protection keys** (01 §13 question 7, decided 2026-10-04: all the way). x86's PKU gives 16 keys; a mapping carries one and a per-thread register, PKRU, says which keys the thread may read and write, changed by the unprivileged `WRPKRU`. Arm's permission overlays (FEAT_S1POE) are the same idea: a mapping's overlay index, and the thread's `POR_EL0`, writable at EL0. They are not a security boundary, since the instruction that changes the rights is unprivileged: untrusted code is still a process (01 §6.6). They contain trusted but buggy code: hx's grammars parsing with the buffer write-protected (08 §6).

## Decision

### Extended state (6c1)

1. **`VX_STATE_GET_XSTATE` and `VX_STATE_SET_XSTATE`** read and write a thread's whole FP/SIMD state, on the same terms as `GET_FPREGS` (a thread stopped at a port, or suspended with `DEBUG`). The buffer is the architecture's own image:
   - x86_64: XSAVE's standard (not compacted) format, `vx_cpu_info.xstate_size` bytes, every component XCR0 enables. `SET` refuses (`INVALID`) a header whose `XSTATE_BV` or `XCOMP_BV` has a bit XCR0 lacks, reserved header bytes not zero, or an MXCSR with a bit `mxcsr_mask` lacks, as XRSTOR would fault on them.
   - aarch64: `vx_fpregs` (V0-V31, FPCR, FPSR), then `POR_EL0` when the CPU has overlays: `xstate_size` says which. SVE's and SME's state join it when the kernel saves them.
   - `GET_FPREGS` and `SET_FPREGS` stay, the legacy part alone (x86's first 512 bytes). A `SET_FPREGS` leaves the rest as it was.
2. **`VX_STATE_GET_CPU`,** with thread 0, fills a `vx_cpu_info`: what the kernel saves and lets user code use.
   - Both: `xstate_size`; `keys`, the protection keys a task may allocate (0: none).
   - x86_64: `xfeatures` (XCR0) and `mxcsr_mask`. User code still asks CPUID for instruction sets.
   - aarch64: the ID registers user code needs for dispatch, as the kernel read them, fields it does not support zeroed: `ID_AA64ISAR0_EL1`, `ID_AA64ISAR1_EL1`, `ID_AA64ISAR2_EL1`, `ID_AA64PFR0_EL1`, `ID_AA64PFR1_EL1`, `ID_AA64ZFR0_EL1`, `ID_AA64SMFR0_EL1`, `ID_AA64MMFR3_EL1`.
   libvx wraps it as `vx_cpu()` (cached), and the C library's `getauxval(AT_HWCAP)` is derived from it on aarch64.

### Protection keys (6c4, 6c5)

3. **`as_key_alloc(task, &key)`** takes a task handle with `WRITE` (as `as_map` does) and gives a free key, 1 to `keys`; `NO_SPACE` if none is free, `UNSUPPORTED` where `keys` is 0. Key 0 is every mapping's default and is never allocated. **`as_key_free(task, key)`** frees it; `BAD_STATE` while a mapping still uses it, so a freed key never names a live mapping under its next owner.
4. **A key on a mapping:** `as_map` and `as_protect` take it in their flags, `VX_MAP_KEY(k)` (bits 8-11); a key the task has not allocated is `INVALID`. `as_protect(task, address, size, flags)` changes a range's rights and key together, cutting mappings as `as_unmap` does; it comes in 6c4, ahead of the rest of 6e's address-space calls, as protection keys need it.
5. **A thread's rights** are its PKRU (x86_64) or POR_EL0 (aarch64), part of its extended state. A thread sets its own with libvx's `vx_keys_set(key, rights)`, rights `VX_KEY_READ` and `VX_KEY_WRITE`: the unprivileged instruction, no syscall. A new task's first thread has key 0 open and the rest closed; a thread created by a thread of its own task takes its creator's rights; `fork` keeps the keys, every mapping's key and the forking thread's rights.
6. **The kernel honours the calling thread's rights** in its copies to and from user memory, as the hardware checks them for it (x86's PKU applies to supervisor accesses to user pages too). On aarch64 a privileged access is checked against POR_EL1, not the thread's POR_EL0, so the copies move from `ldrb`/`strb` to the unprivileged `ldtrb`/`sttrb` (6c5); for the same reason the kernel's user copies there stay scalar, as no SIMD load or store is unprivileged. A syscall given a buffer its caller may not read or write fails with `ACCESS`.
7. **A violation** is the exception `VX_EXCEPTION_PROTECTION_KEY`: `address` what was touched, `code` read 0 or write 1, and the key in `vx_exception.key` (the former `reserved` field). Under POSIX it is `SIGSEGV` with `SEGV_PKUERR` and `si_pkey`.
8. **Handlers:** the kernel diverts a thread to its in-task handler with key 0 opened in its rights, so the handler can always use its stack, and puts the rights it had in `vx_exception.rights`; `exception_resume` with thread 0 restores them. musl's signal delivery and `sigreturn` follow from it.
9. **The debugger** shows and sets the rights with the extended state (procfs's `xregs`, dbg's `regs`).

## Consequences

- The ABI grows by two `thread_state` ops, `vx_cpu_info`, two calls, `as_protect`'s implementation, a flags field and an exception kind. `vx_exception` keeps its size: `reserved` becomes `key`, and `rights` takes 8 bytes of what follows (the struct grows by 8; it is not yet frozen, ADR-0004).
- Each x86 thread's save area is sized at boot from CPUID, about 2.7 KiB with AVX-512 where FXSAVE was 512 bytes, allocated with the thread instead of inside it.
- Protection keys are a hardening aid inside a process, not isolation. The manual says so in as(2) and sharing(7).
- Neither tiered arm64 board has overlays, so there `keys` is 0 and the calls answer `UNSUPPORTED`; tests of keys run on x86 under KVM, and on aarch64 only if QEMU's `max` CPU emulates FEAT_S1POE.

## Alternatives

- **`pkey_alloc`'s initial rights argument** (Linux): left out. The caller sets its own with `vx_keys_set`, so one call does one thing.
- **A system-information syscall** for the CPU's features: a `thread_state` op on thread 0 serves, as `GET_TLS` already does for the caller's own state, without a new call.
- **Emulating EL0 reads of the ID registers on aarch64** (Linux traps them): more kernel surface than handing over the values once.
- **Freeing a key that mappings still use** (Linux allows it): refused, since its next owner would inherit those mappings' protection.
