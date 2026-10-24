# D128. User code learns the CPU's features from the topology page, and libraries pick their fast paths once at startup through tables, not IFUNCs; ports read them through `getauxval` (2026-10-24, for the owner's review)

D51, D52 and D53 set each arch's baseline, the level user code may
assume, and named what stays a run-time option: AVX2, FMA and AVX-512
on amd64, SVE2 and the crypto instructions on arm64 (the Sky1 has
both, `docs/boards/orangepi-6-plus/`), and V on rv64. Nothing lets user
code find those options. The kernel measures each CPU's extended state
(`ExtendedStateFacts`, with `common()` for what every CPU shares, and
the RHCT's ISA strings on rv64) but keeps it to size thread state; no
info topic, vDSO page or call carries it, and the only user probe is
amd64's `td_cpuid`. ld refuses IFUNCs (system/ld/lib/Dynamic.swift).
The libc's memcpy, memmove and memset go a word at a time and the rest
a byte at a time, so there is nothing yet to choose between.

A review on 2026-10-24 also found that the baselines never reached the
build: `CROI_USER_CFLAGS` is empty on amd64 (x86-64 with SSE2), arm64
has `-mbranch-protection=bti` alone, rv64 `-march=rv64gc`, and the
loader checks no CPU against its baseline. Each of D51-D53 lists that
work as its own change; it comes before this one, since a tier above a
floor means nothing until the floor is assumed and checked.

## The decision

- **Floors, then tiers.** Code is compiled for its arch's baseline
  and assumes it; the loader refuses a CPU below it (D51-D53). Above
  the floor an arch has at most two tiers, each a fixed set of
  features that is all present or not used:

  | Arch | Floor | Tier 2 | Tier 3 |
  |---|---|---|---|
  | amd64 | ivybridge (AVX) | x86-64-v3 (AVX2, FMA, BMI1/2) | x86-64-v4 (AVX-512 F/BW/CD/DQ/VL) |
  | arm64 | armv8.2-a+fp16+dotprod+rcpc | AES, PMULL, SHA1, SHA2 (both boards) | SVE2 (the Sky1) |
  | rv64 | RVA22U64 | V (at any VLEN) | |

  A routine names the tier it needs, never a single feature, so the
  combinations to build and test stay three per arch at most. A new
  tier, or a feature moved between tiers, is a change to this table.
- **The kernel publishes one record.** The topology page (include/
  shared.h, already read-only and per system, with the cache lines)
  grows a features block in a new version: the tier, a bitmap of the
  run-time options every CPU shares, and the vector lengths (arm64 SVE
  and SME, rv64 `vlenb`). It is filled once at boot from what
  `ExtendedStateFacts.common()` and the ISA probes already compute,
  with each feature counted only where the kernel has enabled its
  state (XCR0 on amd64, the CPACR/ZCR and SMCR fields on arm64, VS in
  sstatus on rv64). A feature on some CPUs only is not published:
  threads migrate. It replaces nothing because nothing exists; it
  extends the page that already carries what the hardware is, rather
  than adding a call or a page (principle 1).
- **Raw CPU probes are not the interface.** User code may still run
  CPUID (amd64), but the published record is the answer: it is what the OS saves and
  what every CPU shares. `td_cpuid` stays for what it does now, finding
  the hypervisor.
- **Our libraries dispatch through tables filled once.** The libc
  (and later any library with fast paths) keeps a table of function
  pointers, set from the record before any constructor runs, then
  read only (its page is protected after the fill, like RELRO). The
  first users are memcpy, memmove, memset, memcmp, the str* scans and
  the checksums. The floor's routine is the table's initial value, so
  a program that runs before the fill still works.
- **No IFUNCs.** ld keeps refusing them; a table is simpler to read,
  test and trace than a resolver run in the middle of relocation, and
  it keeps ld's rule that everything is bound at load and nothing runs
  there. If a port's dependence on IFUNCs proves expensive to patch,
  supporting them is a new decision.
- **Ports read the record through the calls they already use.** The
  libc provides `getauxval(AT_HWCAP)` and `AT_HWCAP2` with Linux's bit
  assignments for each arch, and FreeBSD's `elf_aux_info`, both built
  from the record, so zlib-ng, simdjson, libjpeg-turbo, SDL and
  compiler-rt's `cpu_model` find their paths without patches. Bits
  beyond the record read as absent. On amd64 these libraries use CPUID
  directly, which reports what the CPU has; the OS-enabled check they
  pair with it (XGETBV) agrees with the record because XCR0 is what the
  kernel set.
- **Fast paths are C23 or a separately compiled module.** Swift has no
  per-function target attribute, so a tier's routine is a C23 file or a
  Swift module compiled with that tier's flags. Each such file's header
  says which tier it serves, which is the C rule's reason.
- **Every tier is tested and measured.** The floor runs that D51-D53
  plan (`-cpu IvyBridge`, `cortex-a76`, `rva22s64`) exercise the floor
  routines; `-cpu max` the top tier. A suite checks each table entry
  against the floor routine on the same inputs, at every tier the CPU
  allows (a routine can be called directly whatever the table holds).
  A tier that doesn't beat the floor on the budgets it serves (today
  `ring.per_1000_slots` for memcpy) is not added.

## What a board below the floor would reopen

The StarFive VisionFive 2 (JH7110, four SiFive U74 harts) is the board
in question. From memory, not yet checked against its devicetree, the
U74 is RV64GC with Zba and Zbb: no V, and none of RVA22's Svpbmt,
Zicbom, Zicboz or Zicbop. That is below D51's floor, not a board
without one tier, so chasing it reopens D51:
- **The floor itself.** Either rv64's floor drops to RVA20U64 with
  Zba and Zbb (every rv64 program loses what RVA22 lets it assume, and
  the dispatch table gains an RVA22 tier), or rv64 gets two floors
  with two builds of everything, which this decision's limit of three
  combinations per arch rules out.
- **The kernel's paths.** D51 plans to remove the Svpbmt fallback and
  `boot-smoke-no-svpbmt`; a U74 board needs them kept. Cache
  maintenance without Zicbom goes through the SoC's own controller
  (SiFive's L2 cache flush), a board rule under D126.
- **Firmware.** Like the RV2, the board ships U-Boot and a devicetree;
  D51's open firmware question applies to it as well.
- **What to check first:** the JH7110's `riscv,isa-extensions` in
  Linux's devicetree, and whether its harts take misaligned loads in
  hardware (the libc's rv64 copies assume they may trap).

Until the owner decides to chase such a board, D51's floor stands and
its follow-ups proceed as planned.

## Follow-ups, each its own change

The baselines in code (D51-D53's lists), then the record on the
topology page and its man page (D86), `getauxval` and `elf_aux_info`,
the libc's table with memcpy and memset as its first entries and their
suite, and user.md's "AVX are run-time options", which D52 changed.
