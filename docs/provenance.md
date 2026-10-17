# Provenance

Where each part of VectraOS comes from, and how it gets here. All three
source repositories are BSD-3-Clause by the same author, so code moves
between them freely. `IMPORTS.tsv` at the repository root lists every
imported file with its source repository, commit and path. Imported files
start out byte-identical to their source.

The actions in the tables:

| Action | Meaning |
|---|---|
| **Lift** | Copy as is, adjust paths, build. |
| **Port** | Copy, then change it to fit VectraOS decisions. |
| **Rewrite** | Write it again in Swift, using the source as a spec. |
| **Design** | Take the design or documents only. |
| **Drop** | Deliberately not carried forward. |

## croi (Embedded Swift + C23 kernel)

| Part | Action | Milestone | Notes |
|---|---|---|---|
| `boot/` UEFI loader | Lift | V0 | Swift loader |
| `kernel/` (about 38k lines) and `kernel/arch/*` | Lift | V0 | The whole object model comes first. Slimmed in V1 (D2). |
| `kernel/include/` ABI headers | Lift | V0 | Become VectraOS's C23 ABI |
| `lib/{handoff,elf,pagetables,fmt,rt}` | Lift | V0 | |
| `cmake/` toolchain, `CheckNoArc`, `CheckNoOptionSet`, `ld/image.ld` | Lift | V0 | One build graph (D11) |
| `user/userboot`, `user/vdso`, `user/test/usertest.c` | Lift | V0 | usertest is the kernel's regression suite |
| `tools/bench.py` | Port | V0 | Became `vx bench`, judged by todhchai's Judge; removed |
| `tools/{elf2efi,mkbootfs,check-pixels,qemu-monitor,todhchai-check}.py`, `zircon-bench/compare.py` | Rewrite | V0 | `vx` subcommands over `tools/image/lib` (ImageFormats); outputs checked byte-identical before the Python was removed |
| `tools/qemu.sh`, `tools/zircon-bench/run.sh` | Lift | V0 | Still bash |
| `docs/design/*`, `zircon-divergences.md`, the `CLAUDE.md` pitfalls | Lift | V0 | Under `docs/kernel/` |
| sockets, streams, FIFOs, eventpairs | Drop (candidates) | V1 | Rings replace them; each drop gets a decision entry |

## todhchai (Swift userland on croi)

| Part | Action | Milestone | Notes |
|---|---|---|---|
| `tools/bench/lib` (Judge, History) and the `td` budget scrape | Lift | V0 | Contracts from day one (D10) |
| `system/trace` with its format | Lift | V0 | Same record as the kernel |
| `tools/td` | Port → `tools/vx` | V0 | One front door (D11) |
| `system/ipc` (wire, `@IPCLibrary`), `idlc` | Lift | V2 | The control plane (D3) |
| `system/node`, namespaces, `/srv` | Lift | V2 | |
| `system/launch` (manifests), `system/sys`, `system/libc`, `system/fdio` | Port | V2 | Onto V1's ABI through its headers (D45); stdio and pipes on rings (D46) |
| `system/ld` (dlopen) | Port | V2 | Its core (`Dynamic.swift`) as is; its loader onto croi's ELF and bootfs readers and userboot's segment mapping (`user/lib/loader`) |
| `system/elf`, `system/bootfs` (readers) | Drop | V2 | croi's win: `lib/elf`'s ElfImage (the kernel's, the loader's, userboot's) and userboot's Bootfs, allocation-free over spans. The launcher's loader (V2's item 4) uses them too |
| drivers: bus/PCI/ACPI, virtio | Lift | V2 | |
| `services/router`, as `services/plumber` (D85) | Port | V2 | plumber(4)'s files at /mnt/plumb; its rules engine and regexp lifted, its typed RouterIPC not |
| `services/console`, `services/time`, `shell/commands` | Port | V2 | The console reads the debuglog ring (D38); UTC is a page (D48) |
| `tools/toolchain` (the `*-todhchai` series, renamed `*-vectraos`) and tier 1's sysroot | Lift | V2 | Tier 1 for FDIO and rc (D47) |
| `fs/taisce` and `services/fs` | Lift | V3 (RAM disk), V4 (on disk) | The one FS (D8). V3's file copies land in it. Replace its use of the `Synchronization` module in tier 0. |
| `services/radharc`, desktop shell (Tracker, Deskbar) | Port | V5 | Add the tile and space workspace modes (D9). The look is Platinum Indigo (D24), not `desktop.md` §6's neon. |
| `shell/terminal`, as `shell/rio` (D75) | Port | V5 | Rio's text window inside Radharc, serving `/dev/cons`; `TerminalCore` as `vt`, a program in a window; the router's route as plumbing from the window's directory. |
| `ui`, `text`, `graphics` (Vulkan/Venus), `codecs` | Lift | V5 | `graphics` changes on the way in: D55-D62 (memory by intent for both memory models, one sync mechanism, shader layouts from the IDL; F-106 not lifted) |
| N1 (`n1` branch): `crypto`, `services/net`'s stack (serving `/net`; NetRing and NetIPC not lifted, D79), `drivers/net` (class + virtio-net) | Lift | V3 | The bring-up link (D15, D77): the stack and crypto under 9gate's core and Noise IK, brought forward from V7. `services/sshd` and SFTP are not lifted (D77). |
| `rc`, the pty service, the launcher's `/dev/bin` union (N1e) | Lift | V2–V3 | rc is the one shell. The pty's line discipline as it was, its server and protocol on rings (D46); temporary, and ejected in V3 (2026-10-17) for Plan 9's `/dev/cons` (D77) |
| principle 17 and `CodeModule` (architecture §16, sdk.md §11), principle 27 | Design | V5, V9 | Hot reload and plug-ins as processes (D92, `docs/plugins.md`) |
| `ui/core` (`Theme`, `UIQuad`) and the Neon Tab look (desktop.md §6) | Port | V5 | Themes as data over roles, not hue-named tokens; Neon Tab ships as a theme, not the default (D91, `docs/theming.md`) |
| `sdk/` and macros (`@AudioRenderer`) | Lift | V5 | |
| `services/keyring`, as `services/factotum` (D75) | Lift | V3 | Noise IK's static key, the node's identity, from V3 (D77). Already after Plan 9's factotum; renamed, its AuthIPC sessions kept. A headless factotum asks no one (D75); keys persist with Taisce on disk (V4). |
| `docs/browser.md`, `docs/research/communications.md`, `docs/research/office-suite.md`, Edit, Mail and People (desktop.md, sdk.md) | Design | V11–V13 | The applications both projects planned (D95, `docs/apps.md`): the browser's engine and its stages; one sync service per protocol, apps as live queries; ODF, not a native format |
| `codecs` translators beyond V5's, Player and the music library (desktop.md) | Port | V14 | Decoders checked against host oracles after D89 (`docs/apps.md` §7) |
| Radharc's `capture` and the Recorder (desktop.md) | Design | V5, V15 | Per-window capture and the lamp in V5; the Recorder is Studio with a file output (D96, `docs/studio.md`) |

## NeoVectra (C23 with third-party dependencies)

| Part | Action | Milestone | Notes |
|---|---|---|---|
| Rule 13 and the design rules | Design | V0 | Folded into principles.md |
| `lib/vx-ring` model test | Rewrite | V1 | The one ring (architecture §3) |
| `lib/vx-9p` codec and `.def` tables | Rewrite | V3 | 9gate's 9P2000 codec, in Swift (D77, D78) |
| docs/02 §6 swarm, `docs/proto/accel.md` | Design | V7–V8 | |
| ADR-0019 (Adreno on the Q8B), ADR-0022 (remote processors), docs/22 (real hardware) | Design | V8 | The Q8B moved to V8 (D69) |
| docs/03 §6.1 and ADR-0056 (the hot-reload host, code images), 01 §6.6, §7.4 and ADR-0043 (plug-ins as processes, seals and leases, live update) | Design | V5, V9 | D92, `docs/plugins.md`; Lua (ADR-0015) not carried |
| docs/03 §5.4 (reactive tokens), §9.1 (`vx-magic`, `vx-next`), §9.5 (the trusted path) | Design | V5 | Radharc's theme tree; Indigo Magic and NeXT themes (D91) |
| docs/03 §8 (`aid`), docs/18 §4 (verbs as tools), ADR-0029 (broad grants) | Design | V10 (proposed) | The Ghost (D90, `docs/ghost.md`); its vendored runtimes and `auditfs` dropped (D4, principle 1) |
| docs/07 (native apps: the protocol stance and table, `webfs`, adapters), docs/17 (Page, Sheet, Stage, Jukebox, Photos), docs/08 (`hx`) | Design | V11–V14 | D95, `docs/apps.md`; NetSurf's libraries, vendored decoders, tree-sitter and Lua user functions not carried (D4, D92); Paint, Draw, Notes, Reminders, Stickies and printing wait for decisions |
| `lib/vx-net` (TCP, DHCP, DNS) | Drop | — | todhchai's `services/net` is the one network stack |
| `lib/vx-fs` (Bε-tree) | Drop | — | Taisce wins (D8) |
| `lib/vx-text` (sam-style structural regex) | Rewrite | V11 | For the editor (D95) |
| `vxui`, `winsrv`, `wm.lua` | Drop | — | Radharc and todhchai's UI win. Lua is third-party (D4). |
| `third_party/*` (Limine, musl, ACPICA, Lua, Monocypher, stb) | Drop | — | D4 |
| `rc` shell (`lib/vx-rc`) | Drop | — | todhchai's rc is the one shell (D15) |
| docs/12-manual.md, ADR-0028, `lib/vx-guide`, `man/` | Rewrite | V2–V3 | The manual (D86): guide's body grammar kept, its ndb header replaced by directives; section 7, the intros, `guide(6)` and `man(1)` rewritten; pages for dropped code not carried |

## AbyssBSD (FreeBSD fork, hardware reference only)

| Part | Action | Milestone |
|---|---|---|
| `docs/boards/radxa-dragon-q8b/*` (ACPI facts, GPU and display, USB, power, NPU, lessons) | Design | V8 |
| `docs/boards/orangepi-6-plus/*` (the board, `gpu.md`, `npu.md`, `vpu.md`; at `bfc0b05`) | Design | V6 |
| `firmware/` blob provenance for the Q8B | Design | V8 |
| `sys/dev/uart/uart_dev_qcom_geni.c`, `firmware-acpi-boot.md` (console pins, SPCR) | Design | V8 |
| `sys/dev/tcx/` and `ethernet-tc956x.md` (TC956x Ethernet) | Design | V8 |

Linux-derived code from AbyssBSD's LinuxKPI ports is *not* used. Those notes
are read only as hardware documentation.

## Linux and FreeBSD (hardware reference only)

| Part | Action | Milestone |
|---|---|---|
| Linux `arch/riscv/boot/dts/spacemit/k1*.dts*` and the `spacemit,*` bindings (the RV2's SoC, memory, buses and devices) | Design | V6b |
| Linux `drivers/net/ethernet/spacemit/k1_emac.c`, `drivers/mmc/host/sdhci-of-k1.c`, `drivers/pci/controller/dwc/pcie-spacemit-k1.c` (register behavior) | Design | V6b |
| FreeBSD `sys/riscv/spacemit/`, `sys/dev/clk/spacemit/`, the X60's ids in `cpu.h` | Design | V6b |

No code is lifted from either (D4). `docs/boards/orangepi-rv2/` records
what was read and at which commit.
