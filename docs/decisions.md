# Decision log

Entries are dated and never edited after the fact. A reversal is a new entry
that names the one it replaces.

- **Decided** means the project owner made the call.
- **Proposed** means it was drafted with the founding docs and stands until
  someone confirms or reverses it.

## D1. Languages: Embedded Swift first, C23 where necessary (2026-10-15, decided)

The toolchain is Swift 6.4 (swiftly), with the clang, lld and llvm-objcopy
bundled with it. Tier 0 uses Embedded Swift with `-strict-memory-safety`.
Tier 1 uses full Swift. C23 is allowed for ABI headers, the compiler runtime,
trampolines and code that Embedded Swift cannot express (principle 29).

## D2. The kernel: lift croi, then slim it (2026-10-15, decided)

Import croi whole in V0 so the system boots from day one. In V1, audit every
object and syscall against the setup-engine role (principle 4). Cut what
rings replace. Publish a syscall-count ceiling that only goes down.

- **Rejected:** a new minimal kernel mined from croi. It is slower to reach
  a boot, and croi's object model is already capability-based.
- **Rejected:** keeping croi unchanged. That leaves two bulk mechanisms.

## D3. The control plane: todhchai's Node protocol locally, 9P2000.L only at the network edge (2026-10-15, decided)

On the machine, services speak the Node protocol and typed `@IPCLibrary`
interfaces over croi channels, using the IPC wire format. `9gate` is the only
component that speaks 9P2000.L. It exports subtrees to the network and
imports remote servers.

- **Principle 1:** the gateway is a translator at a boundary, not a second
  local mechanism. No local service may speak 9P.
- **Rejected:** 9P2000.L everywhere, and NeoVectra's 9Px.

## D4. Third-party code: first-party on the device, heavy tools only on the host (2026-10-15, decided)

Everything that executes on a VectraOS device is first-party Swift or C23.
That includes the Wasm runtime, the TOSA executor, crypto, codecs and the
network stack.

- **Host tools** may use third-party compilers as build tools. MLIR and
  StableHLO, inside `vxc`, are the expected case. A host tool's output must
  be one of our artifact formats.
- **Firmware blobs** that the hardware requires are listed with their
  provenance in `firmware/README.md`. The Q8B's ADSP, CDSP and GPU firmware
  are examples.
- **Rejected:** vendoring pinned libraries onto the device (NeoVectra's
  model), and zero third-party code even on the host.

## D5. First hardware: Radxa Dragon Q8B (2026-10-15, decided)

The board is a Qualcomm SC8280XP: Cortex-X1C/A78C cores, an Adreno 690 GPU
and a Hexagon CDSP NPU, with UEFI and ACPI firmware.

- **Why:** AbyssBSD already runs it under ACPI with the CDSP working, and its
  notes (`AbyssBSD/docs/boards/radxa-dragon-q8b/`) are ground truth. croi's
  ACPI-only boot path carries over, so no devicetree work is needed.
- **Later:** RK3588 and Hailo-8 follow once the accelerator protocol exists.

## D6. One wire format: todhchai's IPC wire format, not FlatBuffers (2026-10-15, proposed)

The paper asks for FlatBuffers so ring payloads can be read in place. The IPC
wire format already gives that: little-endian, 8-byte aligned and decoded in
place. It is also what the Node protocol uses. Adopting FlatBuffers as well
would mean two encodings (principle 7).

- **Ring payloads** use the wire format's layout rules, with no message
  header.

## D7. Wasm as a process, not a unikernel (2026-10-15, proposed)

The paper compiles WASI apps into unikernels to avoid OS overhead. On this
kernel a process with ring-mapped I/O already has that property. So `wasmd`
runs each Wasm app as an ordinary process, with WASI imports mapped onto
nodes and rings. There is no second kernel image format.

## D8. One file system: Taisce (2026-10-15, decided)

When two projects solved the same problem, we keep the one that gives
BeOS-style database abilities. Taisce has typed attributes, indices, live
queries and a change journal. NeoVectra's Bε-tree FS has none of these, so it
is not carried forward. FAT stays read-only for the ESP.

## D9. Desktop: tile and space workspace modes, switchable live (2026-10-15, decided; details proposed)

The owner asked for tiling and spatial window management to be easy to
switch between, with several workspaces of either kind. The design is in
architecture §7.

- **Proposed:** plain stacking is `space` at 1:1, not a third mode.
- **Proposed:** both arrangements persist as Taisce attributes.

## D10. Performance contracts from todhchai (2026-10-15, decided)

- `Judge` (`todhchai/tools/bench/lib/Judge.swift`) decides pass or fail:
  median of the last 5 runs plus a tolerance and a floor, and an optional
  hard limit.
- Budgets are reported on the console as `budget name=… value=… unit=…
  limit=…` lines and kept in a per-host history.
- The tracer uses one 32-byte record, shared by kernel and user space.

These carry over unchanged. See performance.md.

## D11. One front door: `vx` (2026-10-15, proposed)

todhchai's `td` becomes `vx`: build, boot, test, bench, trace and ci. There
is one build graph, CMake and Ninja with presets (from croi). Whether host
tests also run under SwiftPM, as in todhchai, or only under CTest is decided
in V0.

## D12. Names (2026-10-15, proposed)

Component names from the earlier projects stay: Taisce, Radharc and croi
inside `kernel/`. Renaming adds churn and buys nothing.

## D13. Host tools under SwiftPM, images under CMake (2026-10-15, decided in V0)

This settles D11's open question. SwiftPM (`Package.swift`) builds `vx`,
the host libraries (Bench, TraceFormat, TraceReader) and their tests.
CMake builds the loader, kernel and user images, one tree per arch. The
two never build the same target, and `vx` drives both, so this is still
one way to build.

- **`tools/bench.py` is removed.** `vx bench` replaces it, judged by
  todhchai's `Judge`. The two duplicated each other (principle 1).
- **History units.** `bench/history/brimstone.tsv` was converted from
  nanoseconds to seconds, the unit Judge uses.
- **Limits.** The kernel's exclusive `limit=L` is read as Judge's inclusive
  `L - 1` (in ns or the count).

## D14. No Python in the build (2026-10-15, decided)

The owner asked for this to cut the build chain's dependencies. croi's
Python tools are rewritten in Swift as `vx` subcommands:
- `elf2efi`, `mkbootfs` and `check-pixels`, over the `ImageFormats`
  library;
- `qemu-monitor`, `todhchai-check`, and `bench --zircon` (was
  `zircon-bench/compare.py`).

CMake builds `vx` with SwiftPM and runs it for its build steps.

- **Checked before removal.** Every output was compared with the Python
  version's: the PE images of all three arches' loaders, every arch's
  `bootfs.img`, the pixel checks, and the names in Todhchai's bootfs
  images. All were byte-identical. Then the Python was removed.
- **What a build needs now:** the Swift toolchain, CMake, Ninja, QEMU and
  bash. `qemu.sh` and `zircon-bench/run.sh` stay as bash.

## D15. A bring-up link before the board, over SSH (2026-10-15, decided)

The owner asked for a remote shell and file copies to the board during
bring-up, ahead of V4. The roadmap now has V3, the bring-up link,
between V2 and V4. Later milestones are renumbered: Taisce on disk is V5,
the desktop V6, the edge V7, compute V8, Wasm V9. V1 moves off the
critical path and runs alongside.

- **Protocol: SSH, lifted from todhchai's N1** (owner's choice over a 9P
  subset of 9gate). The crypto, network stack, sshd and SFTP are mostly
  built and tested there. Stock OpenSSH on the dev machine needs nothing
  of ours, and the link is encrypted and key-authenticated from the first
  day.
- **This amends D3.** SSH is allowed as a development tool:
  - off unless the image is built with `--ssh`;
  - on-link only;
  - public keys only;
  - never spoken by a local service.

  9gate remains the only namespace protocol on the network, and reuses
  V3's stack and crypto.
- **Links: a serial console plus Ethernet** (owner's choice).
  - A GENI UART driver makes the board's output and hangs visible from the
    first boot. It needs a 1.8 V USB-serial adapter on the header.
  - The TC956x Ethernet carries SSH.
  - Both are developed against QEMU first: virtio-net there, and a
    register-level model for GENI.
- **Warm boot from memory** (owner's choice), so a new kernel needs no
  stick and no walk. The kernel hands off to an image held in memory,
  reusing the loader's ELF, page-table and handoff libraries. It is a
  `SYSTEM_POWERCTL` command, so there is no new syscall. UEFI network boot
  was not chosen (roadmap, open question 7).
- **Files land in Taisce on a RAM-backed block device**, so bring-up has
  no second file system.
- **The shell is todhchai's rc**, since SSH sessions run it. NeoVectra's rc
  is dropped. This settles open question 2.

## D16. Milestones run in order (2026-10-15, decided; corrects D15)

D15 moved V1 off a "critical path" to run alongside V2–V4. That framing
was wrong. The aim is to have the board's dependencies in place before
bring-up is attempted, not to reach the board as fast as possible. The
milestones run in order, V0 → V1 → V2 → V3 → V4 → …. V3 (the bring-up
link) stays ahead of V4 because the board work depends on it.
