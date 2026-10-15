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
| `boot/` UEFI loader, `tools/elf2efi.py` | Lift | V0 | Swift loader; PE32+ conversion. LLVM has no RISC-V COFF backend. |
| `kernel/` (about 38k lines) and `kernel/arch/*` | Lift | V0 | The whole object model comes first. Slimmed in V1 (D2). |
| `kernel/include/` ABI headers | Lift | V0 | Become VectraOS's C23 ABI |
| `lib/{handoff,elf,pagetables,fmt,rt}` | Lift | V0 | |
| `cmake/` toolchain, `CheckNoArc`, `CheckNoOptionSet`, `ld/image.ld` | Lift | V0 | One build graph (D11) |
| `user/userboot`, `user/vdso`, `user/test/usertest.c` | Lift | V0 | usertest is the kernel's regression suite |
| `tools/bench.py` | Port | V0 | Became `vx bench`, judged by todhchai's Judge; removed |
| `tools/qemu.sh`, `mkbootfs.py`, `elf2efi.py`, `check-pixels.py` | Lift | V0 | Still Python and shell, driven by CMake; folding them into Swift is open |
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
| `system/launch` (manifests), `system/sys`, `system/libc`, `system/fdio` | Port | V2 | Trimmed to the slimmed kernel |
| drivers: bus/PCI/ACPI, virtio | Lift | V2 | |
| `services/router` (plumber) | Lift | V2 | |
| `fs/taisce` | Lift | V3 | The one FS (D8). Replace its use of the `Synchronization` module in tier 0. |
| `services/radharc`, desktop shell (Tracker, Deskbar) | Port | V5 | Add the tile and space workspace modes (D9) |
| `ui`, `text`, `graphics` (Vulkan/Venus), `codecs`, `crypto` | Lift | V5 | |
| `services/net`, `sshd` | Lift | V6 | Base for 9gate's transport |
| `sdk/` and macros (`@AudioRenderer`) | Lift | V5 | |
| `services/keyring` | Lift | V6 | Swarm identity |

## NeoVectra (C23 with third-party dependencies)

| Part | Action | Milestone | Notes |
|---|---|---|---|
| Rule 13 and the design rules | Design | V0 | Folded into principles.md |
| `lib/vx-ring` model test | Rewrite | V1 | The one ring (architecture §3) |
| `lib/vx-9p` codec and `.def` tables | Rewrite | V6 | 9gate's 9P2000.L codec, in Swift |
| docs/02 §6 swarm, `docs/proto/accel.md` | Design | V6–V7 | |
| ADR-0019 (Adreno on the Q8B), ADR-0022 (remote processors), docs/22 (real hardware) | Design | V4–V7 | |
| `lib/vx-net` (TCP, DHCP, DNS) | Drop | — | todhchai's `services/net` is the one network stack |
| `lib/vx-fs` (Bε-tree) | Drop | — | Taisce wins (D8) |
| `lib/vx-text` (sam-style structural regex) | Rewrite | later | For the editor |
| `vxui`, `winsrv`, `wm.lua` | Drop | — | Radharc and todhchai's UI win. Lua is third-party (D4). |
| `third_party/*` (Limine, musl, ACPICA, Lua, Monocypher, stb) | Drop | — | D4 |
| `rc` shell | Open | V2 | Choose one shell: todhchai's `shell` or a Swift `rc`. Decided at V2. |

## AbyssBSD (FreeBSD fork, hardware reference only)

| Part | Action | Milestone |
|---|---|---|
| `docs/boards/radxa-dragon-q8b/*` (ACPI facts, GPU and display, USB, power, NPU, lessons) | Design | V4–V7 |
| `firmware/` blob provenance for the Q8B | Design | V4 |

Linux-derived code from AbyssBSD's LinuxKPI ports is *not* used. Those notes
are read only as hardware documentation.
