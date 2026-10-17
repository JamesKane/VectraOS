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
| `services/router` (plumber) | Lift | V2 | |
| `services/console`, `services/time`, `shell/commands` | Port | V2 | The console reads the debuglog ring (D38); UTC is a page (D48) |
| `tools/toolchain` (the `*-todhchai` series, renamed `*-vectraos`) and tier 1's sysroot | Lift | V2 | Tier 1 for FDIO and rc (D47) |
| `fs/taisce` and `services/fs` | Lift | V3 (RAM disk), V5 (on disk) | The one FS (D8). V3's file copies land in it. Replace its use of the `Synchronization` module in tier 0. |
| `services/radharc`, desktop shell (Tracker, Deskbar) | Port | V6 | Add the tile and space workspace modes (D9). The look is Platinum Indigo (D24), not `desktop.md` §6's neon. |
| `ui`, `text`, `graphics` (Vulkan/Venus), `codecs` | Lift | V6 | `graphics` changes on the way in: D55-D62 (memory by intent for both memory models, one sync mechanism, shader layouts from the IDL; F-106 not lifted) |
| N1 (`n1` branch): `crypto`, `services/net` (+ NetRing, NetIPC), `drivers/net` (class + virtio-net), `services/sshd` (+ SFTP) | Lift | V3 | The bring-up link (D15). The stack and crypto are also 9gate's and Noise's base in V7. |
| `rc`, the pty service, the launcher's `/dev/bin` union (N1e) | Lift | V2–V3 | rc is the one shell. The pty's line discipline as it was, its server and protocol on rings (D46); temporary, to be ejected for Plan 9's `/dev/cons` as rio serves it (services/pty/README.md) |
| `sdk/` and macros (`@AudioRenderer`) | Lift | V6 | |
| `services/keyring` | Lift | V3 | sshd's host key now; swarm identity in V7. Its native prompt needs Radharc, so a headless boot needs a decision (roadmap, known issues). |

## NeoVectra (C23 with third-party dependencies)

| Part | Action | Milestone | Notes |
|---|---|---|---|
| Rule 13 and the design rules | Design | V0 | Folded into principles.md |
| `lib/vx-ring` model test | Rewrite | V1 | The one ring (architecture §3) |
| `lib/vx-9p` codec and `.def` tables | Rewrite | V7 | 9gate's 9P2000.L codec, in Swift |
| docs/02 §6 swarm, `docs/proto/accel.md` | Design | V7–V8 | |
| ADR-0019 (Adreno on the Q8B), ADR-0022 (remote processors), docs/22 (real hardware) | Design | V4–V8 | |
| `lib/vx-net` (TCP, DHCP, DNS) | Drop | — | todhchai's `services/net` is the one network stack |
| `lib/vx-fs` (Bε-tree) | Drop | — | Taisce wins (D8) |
| `lib/vx-text` (sam-style structural regex) | Rewrite | later | For the editor |
| `vxui`, `winsrv`, `wm.lua` | Drop | — | Radharc and todhchai's UI win. Lua is third-party (D4). |
| `third_party/*` (Limine, musl, ACPICA, Lua, Monocypher, stb) | Drop | — | D4 |
| `rc` shell (`lib/vx-rc`) | Drop | — | todhchai's rc is the one shell (D15) |

## AbyssBSD (FreeBSD fork, hardware reference only)

| Part | Action | Milestone |
|---|---|---|
| `docs/boards/radxa-dragon-q8b/*` (ACPI facts, GPU and display, USB, power, NPU, lessons) | Design | V4–V8 |
| `firmware/` blob provenance for the Q8B | Design | V4 |
| `sys/dev/uart/uart_dev_qcom_geni.c`, `firmware-acpi-boot.md` (console pins, SPCR) | Design | V3–V4 |
| `sys/dev/tcx/` and `ethernet-tc956x.md` (TC956x Ethernet) | Design | V4 |

Linux-derived code from AbyssBSD's LinuxKPI ports is *not* used. Those notes
are read only as hardware documentation.

## Linux and FreeBSD (hardware reference only)

| Part | Action | Milestone |
|---|---|---|
| Linux `arch/riscv/boot/dts/spacemit/k1*.dts*` and the `spacemit,*` bindings (the RV2's SoC, memory, buses and devices) | Design | V4b |
| Linux `drivers/net/ethernet/spacemit/k1_emac.c`, `drivers/mmc/host/sdhci-of-k1.c`, `drivers/pci/controller/dwc/pcie-spacemit-k1.c` (register behavior) | Design | V4b |
| FreeBSD `sys/riscv/spacemit/`, `sys/dev/clk/spacemit/`, the X60's ids in `cpu.h` | Design | V4b |

No code is lifted from either (D4). `docs/boards/orangepi-rv2/` records
what was read and at which commit.
