# Architecture decision records

One file per decision, `NNNN-title.md`, numbered in order. An ADR records a decision the blueprint (docs 00–05) does not already settle, or an exception to a rule there. It is short: the context, the decision, and what follows from it. A superseded ADR stays, marked with the ADR that replaced it.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-toolchain-trust.md) | Toolchain trust: pinned clang, lld and compiler-rt | Accepted |
| [0002](0002-limine.md) | Limine 12.9.1, vendored unchanged and built by `build` | Accepted |
| [0003](0003-no-registries.md) | No package registries | Accepted |
| 0004 | The ring layout; freezes `vx-abi` v0 | Written at M2, when the ring code exists |
| [0005](0005-c23-house-subset.md) | C23 and the house subset | Accepted |
| [0006](0006-u9fs.md) | u9fs, vendored as a host test tool for 9P interoperability | Accepted |
| [0007](0007-musl.md) | musl 1.2.6, vendored unchanged, with a VectraOS back end | Accepted |
| [0008](0008-compiler-rt.md) | compiler-rt's builtins, vendored from LLVM 22.1.8 | Accepted |
| [0009](0009-namespace-groups.md) | Namespace groups shared by default, mounts found by identity, namespace(6) templates | Accepted |
| [0010](0010-notes-and-exit-strings.md) | Notes and exit strings, with POSIX signals built on notes | Accepted |
| [0011](0011-one-process-model.md) | One process table in `procfs`, served as files; `posixd` folded in | Accepted |
| [0012](0012-task-exec.md) | `task_exec`: `exec` keeps the task, and so the pid | Accepted |
| [0013](0013-text-is-utf8.md) | Text is UTF-8, handled in runes: `lib/vx-utf`, strings cut at rune boundaries, names without control characters, rune-aware line editors | Accepted |
| [0014](0014-catalogues.md) | Publisher catalogues for package dependencies: one signed list per publisher key, no shared name space, no install-time code; not a registry | Accepted |
| [0015](0015-lua.md) | Lua 5.5.1, vendored unchanged, as `/bin/lua`; vendored POSIX programs in `./build` | Proposed |
| [0016](0016-sbase.md) | sbase, vendored unchanged: one box binary with hard links in bootfs, in `/boot/bin/posix`, bound before `/boot/bin` for POSIX programs | Proposed |
| [0017](0017-debug-index.md) | The debug index is first-party: `vxdi`, built from DWARF 5 by `lib/vx-debug`; RDI is not vendored | Accepted |
| [0018](0018-gpu-drivers.md) | GPU drivers: one native `accel` protocol, Mesa ported to it, hardware whose firmware does the work only, display separate and flip-only first; amended for Adreno | Proposed |
| [0019](0019-adreno-q8b.md) | Adreno a6xx on the Q8B: `drv-gpu-adreno` with kernel-owned switched page tables, `disp-msm` ported from msmfb (amended for ADR-0026), `drv-qcom-gcc`, SCM operations, the SC8280XP record, pinned firmware | Proposed |
| [0020](0020-cpu-configure.md) | `cpu_configure`, the 63rd syscall: the firmware's idle states and performance domains into the kernel, and limits from the power profile and thermal policy | Proposed |
| [0021](0021-thermal-policy.md) | Thermal policy: `thermd`, zones from ACPI or the SoC record, critical, passive and active trips acting through `VX_CPU_LIMITS`, GPU `freq max` and `svcd` | Proposed |
| [0022](0022-remote-processors.md) | Remote processors: `drv-qcom-pas` boots and stops them through the secure world, `drv-qcom-glink` serves channels as ring sessions, consumers are ordinary drivers | Proposed |
| [0023](0023-device-tree-socs.md) | Device-tree SoCs: a boot stage keeps the kernel DT-free; `bus-dt` turns references into grants; `regulator`, `registers`, `i2c`/`spi` classes and `clock` v2; delegated CPU frequency; device-MMU domains; NPUs speak `accel` | Proposed |
| [0024](0024-acpi-methods-and-resources.md) | ACPI firmware services: AML methods as a per-device service, ACPI power and clocks through `clock`, ACPI resources turned into grants, `bus-acpi` owns its operation regions; late wake timers; CPU tiers by capacity | Proposed |
| [0025](0025-system-volume-format.md) | The system volume is our own copy-on-write format after gefs: Bε trees in `lib/vx-fs`, branches as subvolumes, deadlists, the seven-phase commit; `distd` verifies the base tree; `dosfs` and `isofs` for FAT and ISO 9660 | Proposed |
| [0026](0026-display-back-ends.md) | Display back ends: a narrow engine protocol under `displayd` (check, apply with a stamp, vblank events), adopting the firmware's pipeline first, one DisplayPort library `lib/vx-dp`, `lib/vx-edid` in `displayd`, block layouts in the SoC record | Proposed |
| [0027](0027-sky1-display.md) | The Sky1's display: `disp-linlon` for the Linlon-D6 (Arm's D71, from komeda), the Trilinear DP transmitter on `vx-dp`, flip only in the GOP's window, a DP-only output first | Proposed |
| [0028](0028-manual-format.md) | The manual is written in guide, a line-typed hypertext format after AmigaGuide, keeps Plan 9's sections and commands, and is checked against the code by `./build check` | Proposed |
| [0029](0029-broad-grants.md) | Broad grants (the whole home, another app's data, the dump, other windows, mixed context pools) are given only from the grant settings on the trusted path, never on request, at install or to agents; the POSIX template gives no home; app data lives outside the home | Proposed |
| [0030](0030-acpica.md) | ACPICA 20260930's OS-independent core vendored unchanged, built as a native port for `bus-acpi`; its OS layer first-party, the tables from the kernel's copies | Proposed |
| [0031](0031-system-power-and-clock-set.md) | Two syscalls on the root Resource: `system_power` (PSCI `SYSTEM_OFF` where powering off is not ACPI's) and `clock_set` (the wall clock as UTC's offset from the monotonic clock, read through `clock_read`); `devmgr` makes both for `bus-acpi` and clock drivers | Proposed |
| [0032](0032-monocypher.md) | Monocypher 4.0.3 vendored unchanged (core and its optional Ed25519), built as a native port: BLAKE2b for the content store's names, Ed25519 for release signatures from M10 | Proposed |
| [0033](0033-iso-c-library.md) | An ISO C library for native programs, `libvxc` (C23 clause 7 from musl's vendored sources, on `libvx`, no POSIX), a C++ support subset in C, and the `<arch>-unknown-vectraos` target with its sysroot; first-party code never includes it | Accepted |
| [0034](0034-swift.md) | Swift is a first-party language beside C23, for designs that need OO or protocol structure, functional patterns, namespacing or ARC: full Swift for applications and late services, Embedded Swift for drivers and the boot path, never the kernel or the ABI; on `libvx` only; toolchain pinned and patched in-tree; four gates before first-party Swift merges | Accepted |
