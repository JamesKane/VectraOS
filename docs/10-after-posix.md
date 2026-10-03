# 10 — After POSIX: a speculative vision

_Vision, 2026-10-02. **Non-binding.** This is speculation about where the system could go after M12, written so the direction can be argued about before anything is built. Nothing here changes a rule or decision in 00, and nothing here is scheduled. A part becomes binding only through an ADR, and most parts would need rule 13 or D1, D8 or D10 amended first (§9). Facts about other projects were gathered on 2026-10-02 and are cited in §11; figures are as their authors report them._

## 1. The claim

**POSIX dies when a developer can spend a whole working day on VectraOS without running a single program linked against it.** That means editing, building, debugging, testing, profiling, committing and pushing. Deleting musl is not the aim. The POSIX personality stays as a guest that runs software written for other systems (01 §9), as 9front keeps APE. What changes is that nobody writes new code against it, because nothing a VectraOS developer needs lies on that side.

Today the blueprint says the opposite on purpose: rule 13 makes POSIX "the foundation the development tools stand on", because "we are not reinventing LLVM, Git or the toolchains built on POSIX". That was the right call, and it stands: clang, lld and the ported tools ship first, and M12 self-hosts with them. This document is not a race with them. It asks what happens after that, once `libvx` (09) exists and every first-party program already avoids POSIX. At that point the toolchain is the last reason a developer touches POSIX, and LLVM is the largest thing in the image that no one on the project can read.

## 2. What others have done

From the survey (§11), arranged by where each system sends software written for POSIX:

| Legacy route | Systems | What the native developer sees |
|---|---|---|
| **A Linux system-call personality** | Fuchsia (Starnix), Managarm, Asterinas, Unikraft's binary-compatibility mode, early Twizzler | Fuchsia: FIDL, components and handles; POSIX Lite (`fdio`) deliberately incomplete. Managarm and Asterinas: Linux, in practice |
| **Recompile against a POSIX libc** | Redox (relibc), Genode (a FreeBSD-derived libc per component), CheriBSD, WASI (wasi-libc), Essence | Redox: schemes, but fd-shaped and POSIX-first. Genode: C++ session interfaces. WASI 0.3: typed WIT interfaces, `stream<T>`, `future<T>`, one completion-based loop |
| **Whole guest systems or driver VMs** | LionsOS (Linux driver VMs), Genode/Sculpt (VirtualBox) | LionsOS: notifications and shared-memory queues, with a coroutine library for blocking-style code layered over them |
| **No route at all** | Hubris, Tock, Xous, CHERIoT RTOS, Oberon/A2 | Only the native API. Every one of these is embedded or single-purpose |

Four lessons follow from it.

1. **POSIX pulls hard.** Managarm moved from its own ABI to the Linux ABI in 2023, because ported software hardcodes Linux constants, and took systemd as its init in 2025. Ladybird left SerenityOS for Linux and macOS. Unikraft added `fork` to a single address space (μFork, SOSP 2025). Every general-purpose system that wanted third-party software kept a POSIX or Linux route open.
2. **Only embedded systems run with no route at all.** None of them has a developer who must build a compiler on the device.
3. **Fuchsia shows the strategy that works for a general-purpose system.** New capabilities are reachable only through the native interfaces. The POSIX library is deliberately incomplete: it leaves out `kill` because that needs global state. Full Linux compatibility lives in a personality with no special standing. The personality is complete enough to *run* old software and useless for writing *new* software.
4. **The field converges on what VectraOS already has.** That means capability handles, per-process namespaces assembled by a parent, spawn with explicit grants (Baumann et al., "A fork() in the road"), and completion rings in place of blocking calls (io_uring, Managarm, WASI 0.3). Plan 9 had the namespaces in 1992. 01 and 09 add the handles and the rings. The OS design is not the hard part. The tools are.

Toolchains are moving the same way. Language projects are taking the debug-build path in-house and keeping LLVM only for optimised output. Zig's own x86_64 back end became the default for debug builds in 2025, Rust's Cranelift back end aims at production use, and Odin dropped the Tilde back end in 2026 to write its own. These are cited as evidence of a trend only; none of them is a candidate here (D1).

## 3. Where POSIX still stands in a developer's day

After M12, as the blueprint plans it:

| Activity | Tool | Native? |
|---|---|---|
| Edit | `hx` (08) | Yes |
| Shell, scripts | `gsh`; Lua | `gsh` yes. Lua builds against musl with `LUA_USE_POSIX` (ADR-0015), though without that flag it needs only ISO C |
| Build orchestration | `build` (04 §3.2) | Becomes native once it links `libvx` instead of the host libc |
| **Compile, assemble, link** | clang, lld, compiler-rt | **No: LLVM over POSIX** |
| **Format and lint** | clang-format, clang-tidy, the clang static analyzer | **No: LLVM** |
| **Sanitizers and fuzzing** | ASan, UBSan, libFuzzer | **No: LLVM passes and compiler-rt runtimes** |
| Debug, profile | `dbg` (05) | Yes, over `/proc` |
| **Version control** | Git | **No: POSIX port** |
| Test | `./build test`, QEMU | QEMU runs on the host and is outside this question until VectraOS hosts its own tests |
| Python, other ports | ports | No, and that is fine: these are guests |

Three anchors remain: **the C library** (for imported ISO C code such as Lua), **the toolchain**, and **Git**. Everything else in the developer's path is already first-party and native by design.

## 4. Move one: ISO C is the language, POSIX is not

The C23 standard library (clause 7: `<stdio.h>`, `<stdlib.h>`, `<string.h>`, `<math.h>`, `<time.h>`, threads) is part of the language D1 chose. POSIX is a different standard layered on top of it. Plan 9 drew the same line: its own libc served native programs, and ANSI/POSIX lived in APE.

The speculative move is a **hosted C23 library implemented directly on `libvx`**, without `fork`, signals beyond `raise`, file descriptors as integers, `errno`-as-ABI or locales. It would be enough for code that asks only for ISO C: Lua built without `LUA_USE_POSIX` (losing `io.popen` and `mkstemp`-based `os.tmpname`, which a native Lua library could give back over `libvx`), kb_text_shape, stb_truetype and Monocypher. Today those either build freestanding or go through musl. With this library, Lua moves out of the POSIX personality, and so do the scripts and the `wm` policy that run on it.

**The tension with rule 13 is real, and the vision does not hide it.** A C library over `libvx` is a second interface over the first. The case for it is that the standard library is not a portability layer: it is the language, and a compiler that implements C23 is expected to supply it. The case against it is that first-party code would gain a second way to open a file. One rule would contain that: **first-party code never includes the hosted headers** (`./build check` enforces it, as it enforces the house format), so the library exists only for imported code. Whether that is enough is open question 1.

## 5. Move two: a toolchain one person can read

### 5.1 The shape

Ken Thompson's Plan 9 compilers are the model, evolved to standard C23 as the rest of the system is (00 §1). A compiler per architecture (`6c`, `7c`) merges preprocessing, parsing, code generation and the first half of assembly. The loader (`6l`, `7l`) does instruction selection, scheduling and the second half of assembly. Each piece stays small because the machine-specific work has one home. Go's toolchain grew from the same design, and goken9cc (2025) is reviving the C half of it.

A VectraOS toolchain on that pattern, named here only for discussion:

- **`vc`**: a C23 front end and an SSA middle end with one back end each for x86_64 and aarch64. The target is QBE's stated goal: about 70% of an industrial compiler's performance in about 10% of the code. MIR's author reports output about 6% slower than `gcc -O2` on his benchmarks. That is one author's measurement, not a promise.
- **`vl`**: the linker and loader, designed together with the dynamic loader that 09 §4.8 needs for hot reload (dynamic linking is the direction). The ABI it targets is one fixed ABI (§7), so it is small.
- **The assembler is integrated** into `vc` for the few `.S` files in `kernel/arch/` and `vx-rt`, as clang's is today.
- **`vfmt`** and the house-subset checks move into the toolchain. The formatter applies the one house format (04 §1.1), as `gofmt` does, and has no options. The subset rules (no VLAs, no recursion in the kernel, `ckd_*` on sizes from another task, `[[nodiscard]]` on wrappers) become compiler diagnostics instead of `.clang-tidy` configuration, because the front end already has the parse tree.

### 5.2 What leaving LLVM would cost, and how much of it can be kept

| LLVM provides | Cost of leaving | Native answer, speculative |
|---|---|---|
| `-O2` code quality, vectorisation | A small back end optimises less, and does not vectorise | Not a contest with clang: `vc`'s code is measured against 00 §8's budgets, and hot code that needs SIMD uses intrinsics explicitly |
| **DWARF 5 with types and locations** | Of the small C compilers, only Kefir emits real DWARF 5; QBE has line information only | **A requirement, not an option:** D15 makes DWARF 5 `dbg`'s only format. `vc` emits it from the start, and `dbg`'s flat index (05) is its first consumer |
| UBSan | Small compilers have none | Trap mode (`-fsanitize-trap`, which the debug kernel already uses) is inserted checks with no runtime. A compiler of this size can emit them |
| ASan, libFuzzer | The largest loss: shadow memory, a runtime, coverage instrumentation | Coverage counters (one increment per edge) are easy to emit. A first-party fuzzer drives them. Address checking with a first-party shadow runtime is already planned for the kernel (04 §1.2). Until both are good enough, clang stays as the CI auditor (§5.3) |
| clang static analyzer | Path-sensitive analysis is not small | The house-subset diagnostics cover most of what the project relies on. The rest stays in the auditor lane |
| C++ | `vc` compiles C only | The C++ imports (Mesa's ACO, llama.cpp; 04 §1) are already built once and cached by source hash (04 §3.2). They would be built in the auditor lane, on the host, and enter the tree as reviewed artifacts, as firmware does. No developer runs that build |

### 5.3 Clang becomes the auditor, then the second compiler

LLVM leaves the developer's machine first, while it stays in the checking path.

1. **The auditor.** CI builds the same tree with clang for ASan, libFuzzer, the analyzer and the C++ imports. The developer's edit-build-debug loop uses `vc` and `vl` only. LLVM runs on the CI host, never on VectraOS.
2. **The second compiler.** With reproducible builds (04 §7), Wheeler's diverse double-compiling checks `vc` against clang: build `vc` with clang and with itself, then let each result rebuild `vc`. Bit-identical output rules out a self-reproducing compromise in either compiler. ADR-0001's trust in Fedora's signatures becomes trust in a check anyone can repeat.
3. **The bootstrap.** If `vc` is written in the subset of C that tcc compiles, `vc` can be built from source by the live-bootstrap chain, which starts from a hex seed of a few hundred bytes. This holds on x86_64 today, with aarch64 less complete. No binary compiler would then be needed to trust the system at all.

### 5.4 A staged path, cheapest step first

| Stage | What | Why this order |
|---|---|---|
| S0 | Keep the tree free of clang-only extensions; a CI lane builds the libraries with a second, small C compiler on the host | Costs almost nothing and keeps every later stage possible. Nothing small compiles C23 on aarch64 today (cproc lacks `constexpr` and `#embed`; slimcc and Kefir are x86_64 only), so this lane covers what it can |
| S1 | `vl` replaces lld | The smallest and most self-contained piece, and the dynamic loader needs the same knowledge |
| S2 | `vfmt` and the subset checks replace clang-format and clang-tidy | A small front end is enough for these; this is the first time the project owns a C parser |
| S3 | `vc` compiles user space; clang still compiles the kernel | User space has no inline assembly in the hot paths and survives a miscompile better than the kernel does |
| S4 | `vc` compiles the kernel; diverse double-compiling against clang in CI | The kernel needs `volatile`, atomics and exact code for the `.S` boundaries |
| S5 | clang leaves the developer's path; it stays only as the auditor | The developer's day no longer needs LLVM (§1) |

The size budget comes from rule 13's last test, that one person can understand the base system. A compiler for two architectures with its linker should fit in the kernel's own budget of 15–25 kLOC. A design that cannot fit is the wrong design.

## 6. Move three: Git as a format, not a program

9front already answers this. Ori Bernstein's `git` for 9front is a native implementation, written as a file server in Plan 9 style, that reads and writes Git's object format and speaks its wire protocol. A VectraOS version would serve a repository as files (`/mnt/git/branch/…`, `/mnt/git/object/…`), which `hx` (08) already expects to reach through files.

That is not a compatibility layer. Git's object format and protocol are a data format and a protocol, like IMAP for the mail client (07 §6). Speaking them is how the system reaches the world's code, just as `webfs` speaks HTTP. Git itself, the 400-command C program, stays a port for anyone who wants it.

## 7. The OS and the toolchain, simpler together

Clang and lld are large partly because they serve every ABI, object format, code model and language on every operating system. A toolchain for one system can drop most of that. In practice that means:

- **One calling convention per architecture** (System V on x86_64, AAPCS64 on aarch64), with no variants and no attributes that change it.
- **One object format:** ELF restricted to the relocations VectraOS uses. **One TLS model,** the one `libvx`'s thread state needs (09 §4.5). **One code model.** No symbol versioning and no lazy binding, both of which D20 already rejects.
- **The ABI is data the compiler reads.** Syscall numbers, rights, ring opcodes and 9Px messages are already X-macro tables in `abi/vx/*.def` (04 §1.1). `vc` could check wrappers and record layouts against them directly. Bindings for other languages, such as Odin through `vxui.h`, would come from the same tables rather than from parsing C headers. This is the role WIT plays for WASI, done in ndb and X-macros instead of a new IDL (D5 and D14 already reject a new IDL).
- **Debug information has one consumer.** `vc` emits the DWARF 5 subset that `dbg` indexes and nothing else. It can also emit the zone markers and frame-pointer rules 05 §4 and §9 rely on.
- **The build tool and the compiler meet.** `build` already treats each component as one translation unit (D10). A compiler that runs in-process inside `build`, as a library, would remove process start-up and argument parsing from every compile. That suits the build-time budget (under 1 s for the kernel, under 10 s for all first-party code), which this design would also make tighter.

## 8. The POSIX personality as a guest

Fuchsia's lesson (§2, lesson 3) becomes a rule for the personality. **It may run anything, and it may offer nothing that `libvx` does not.** Every capability the system gains (a new `/dev` tree, a ring protocol, a namespace feature) appears in `libvx` first. If POSIX callers can reach it at all, they reach it through the back end, built on `libvx`. A developer who wants something new has no reason to look on the POSIX side.

Two speculative extensions are worth naming, and the vision leans against both.

- **A Linux system-call personality** in place of musl source ports, Starnix-style, would run unmodified binaries and end port maintenance. It would also bring in Linux's ABI, bug for bug, and run binaries no one reviewed (D13). Managarm's path shows where the gravity of that ABI leads. **Not proposed.** 00 §7 already leaves it possible "later, because personalities are ordinary processes", and that is enough.
- **Shrinking the personality to a measured set.** Once the developer's day is native, `procfs` can say which processes run the POSIX back end. A scenario test can then assert that a scripted day (edit in `hx`, `build`, `dbg`, commit and push) starts none of them. That is the measurable form of §1, and it would be the exit criterion of any milestone that takes this up.

## 9. What would have to change

| Today | Would need |
|---|---|
| Rule 13: POSIX is "the foundation the development tools stand on"; "not reinventing LLVM, Git" | An amendment: POSIX is the foundation for *imported* tools, and the base system's development tools are native. The no-shims part of rule 13 is unchanged and becomes stronger |
| D1, D10: compiled by clang; clang + lld | A toolchain ADR per stage (S1–S5), each with the size budget, the DWARF requirement and the auditor lane |
| ADR-0001: trust in Fedora's signed packages | Diverse double-compiling and a bootstrap path replace it (§5.3) |
| 04 §1.1: house subset enforced by clang-tidy and clang-format | Enforced by `vc` and `vfmt`; `.clang-tidy` stays only for the auditor lane |
| M12: clang, lld, Git and Python ported to VectraOS so it rebuilds itself | Unchanged. They ship first, and the ported clang is what builds `vc` and `vl` on VectraOS, and later the auditor lane and the second compiler of §5.3 |
| D8: musl with a vx back end | Unchanged. It stays as the personality |

## 10. Risks

- **It is years of work for one person,** and it starts only after the pillars in 04 §6. A compiler is never finished, and a miscompile in the kernel is worse than any bug clang has. Differential testing across the whole tree (the same sources built by `vc` and clang, with the same test results) is the minimum safety net.
- **POSIX pulls hard (§2).** Each port that arrives makes the personality more central. The guest rule in §8 only works if it is enforced from the first port onward.
- **Losing the sanitizers too early** would trade a large, unreadable toolchain for a small one that finds fewer bugs. The auditor lane exists to stop that, and it should go last.
- **No small C23 compiler for aarch64 exists today.** This would be the first, so there would be no outside reference to learn from.
- **A tool can be produced cheaply now, but it still has to be reviewed.** Anthropic's 2026 experiment had agents write a compiler that builds Linux. It is about 100 kLOC of Rust, which makes the point: writing a compiler has become cheap, reviewing one has not. The budget in §5.4 is a review budget.

## 11. Sources

Gathered 2026-10-02.

**Systems**
- Fuchsia: [libc and fdio](https://fuchsia.dev/fuchsia-src/concepts/kernel/libc), [Starnix](https://fuchsia.dev/fuchsia-src/concepts/starnix/kernel), [RFC-0082](https://fuchsia.dev/fuchsia-src/contribute/governance/rfcs/0082_starnix)
- Redox: [capability namespaces](https://www.redox-os.org/news/nlnet-cap-nsmgr-cwd/), [August 2026 report](https://www.redox-os.org/news/this-month-260831/)
- seL4: [Microkit](https://trustworthy.systems/projects/microkit/), [LionsOS](https://lionsos.org/), [LionsOS paper](https://arxiv.org/html/2501.06234v2)
- Genode: [2026 news](https://genode.org/news/2026); Hubris: [reference](https://hubris.oxide.computer/reference/), [Idol](https://github.com/oxidecomputer/idolatry)
- Theseus: [OSDI 2020](https://www.usenix.org/conference/osdi20/presentation/boos); Twizzler: [ATC 2020](https://www.usenix.org/system/files/atc20-bittman.pdf), [repository](https://github.com/twizzler-operating-system/twizzler)
- Ladybird: [the fork](https://ladybird.org/posts/fork/); Managarm: [end-of-2025 update](https://managarm.org/2026/01/13/end-of-year-update.html)
- Unikraft: [binary compatibility](https://unikraft.org/guides/bincompat), [μFork](https://arxiv.org/pdf/2509.09439)
- WASI: [WASI 0.3](https://bytecodealliance.org/articles/WASI-0.3)
- CHERI: [CheriBSD 25.03](https://www.cheribsd.org/release-notes/25.03/index.html), [CHERIoT RTOS](https://www.cl.cam.ac.uk/research/security/ctsrd/pdfs/202510-sosp-cheriot-rtos.pdf)
- Tock: [2.2](https://www.tockos.org/blog/2025/tock2.2/), [a decade of Tock](https://tockos.org/assets/papers/2025-sosp-tock-decade.pdf)
- Hermes: [from the ground up](https://drewdevault.com/blog/Hermes-from-the-ground-up/)
- Asterinas: [ATC 2025](https://arxiv.org/abs/2506.03876); Xous: [book](https://betrusted.io/xous-book/)
- Barrelfish and beyond: [the hardware dumpster fire](https://people.inf.ethz.ch/bfiedler/papers/hwdf_hotos_2023.pdf)

**POSIX critiques**
- Atlidakis et al., [POSIX abstractions in modern operating systems](https://dl.acm.org/doi/10.1145/2901318.2901350), EuroSys 2016
- Baumann et al., [A fork() in the road](https://dl.acm.org/doi/10.1145/3317550.3321435), HotOS 2019

**Toolchains**
- [QBE](https://c9x.me/compile/), [cproc](https://sr.ht/~mcf/cproc/), [Kefir](https://kefir.protopopov.lv/) (its author has announced the end of public development), [slimcc](https://github.com/fuhsnn/slimcc), [TinyCC](https://repo.or.cz/tinycc.git), [MIR](https://github.com/vnmakarov/mir), [libFirm](https://github.com/libfirm/libfirm)
- Thompson, [A New C Compiler](https://9p.io/sys/doc/compiler.html); [goken9cc](https://github.com/aryx/goken9cc)
- [TPDE](https://arxiv.org/pdf/2505.22610); [Cranelift progress](https://bjorn3.github.io/2025/06/30/progress-report-june-2025.html); [Odin drops Tilde](https://forum.odin-lang.org/t/tilde-backend-got-removed/1697); [Zig's LLVM issue](https://github.com/ziglang/zig/issues/16270) (as trend evidence only)
- [stage0-posix](https://github.com/oriansj/stage0-posix), [live-bootstrap](https://github.com/fosslinux/live-bootstrap), Wheeler, [Fully countering trusting trust](https://dwheeler.com/trusting-trust/)
- [The agent-written C compiler](https://www.infoq.com/news/2026/02/claude-built-c-compiler/)

## 12. Open questions

1. **Is a hosted C23 library over `libvx` a shim?** §4 argues it is the language, not a layer, and contains it with "first-party code never includes it". The alternative is to port Lua and the other ISO C imports to `libvx` with small patches, and have no hosted library at all. That costs patches against rule 13's "vendored unchanged" habit (ADR-0015).
2. **Write `vc`, or harden an import?** cproc with QBE is about the right size, but it lacks C23 features, inline assembly and PIC, and is written in C99. A first-party compiler costs more to write and less to review against the house rules. Either choice would need an ADR under D13.
3. **Plan 9 objects, or ELF?** Plan 9's loader-centric split keeps the compiler small but invents an object format. Restricted ELF keeps `dbg`, Limine and the dynamic loader unchanged. ELF is the likely answer.
4. **When does the auditor lane end, if ever?** Perhaps never: clang in CI costs nothing on VectraOS, and a second compiler is what diverse double-compiling needs. The vision only requires that it leave the developer's day.
