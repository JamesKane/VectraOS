# Roadmap

Each milestone has exit criteria. A milestone is done when its criteria pass
under `vx ci` and every budget it introduces has a running check
(principle 13).

## V0. Ground

Goal: croi boots from this repository, and the measuring works from the
first commit.

- Lift croi's boot, kernel, lib, cmake, ld, userboot, vdso and usertest
  (provenance.md).
- Lift todhchai's bench `Judge` and `History`, the trace format, and the
  budget scrape. Port `td` to `vx` with `build`, `boot`, `test`, `bench`,
  `trace`, `ci` and `loc`.
- Write `CLAUDE.md` with the merged toolchain pitfalls.

**Exit:**
- `vx ci` builds and boots amd64, arm64 and rv64 in QEMU.
- croi's self-tests and usertest pass.
- Boot budgets are recorded, and the size budgets run.

## The critical path to the board

V0 → V2 → V3 → V4. Bring-up is fastest with a shell, file copies and a
warm reboot already working when the board first boots (D15), so the
bring-up link (V3) comes before the board (V4).

V1 is not on this path. todhchai's userland already runs on croi as it
is, so V2 and V3 don't wait for the kernel to be slimmed. V1 runs
alongside them, and each cut it makes adapts the lifted code in the same
change.

## V1. Setup-engine kernel (alongside V2–V4)

- Audit every object and syscall, and write a decision entry for each cut.
- Implement the one ring (architecture §3) in Swift and as `ring.h`, with a
  model checker.
- Doorbells are counters, and waits go through ports.
- Close the `channel_call` < 1 µs open item.

**Exit:**
- The kernel and IPC budgets are green.
- The syscall ceiling is lowered and published.
- `ring_kicks` = 0 under load.

## V2. Userland base

- Lift todhchai's ipc, node, namespaces, launch, sys, libc, router, the
  bus/PCI/ACPI drivers and virtio.
- Lift todhchai's rc and the pty service. V3's SSH sessions run rc, which
  settles open question 2.
- Console in QEMU.

**Exit:**
- `cat /svc/*/status` works.
- spawn → main < 200 µs.
- Services RSS < 32 MiB.

## V3. Bring-up link (D15)

A shell, file copies and log streaming from the dev machine, plus booting
a new kernel without the USB stick. All of it works in QEMU first, on all
three arches, so the board meets a tested path.

- **Network:** lift todhchai's N1 work: crypto, `services/net` (Ethernet,
  ARP, IPv4/IPv6, DHCP, TCP over NetRing), the net driver class and
  virtio-net.
- **SSH:** lift `services/sshd` (transport, public-key auth, `exec`,
  `shell` through rc on a pty, SFTP v3) and the keyring that holds the host
  key.
  - Off unless the image is built with `vx boot --ssh [PUBKEY]`.
  - Listens on-link only; public keys only.
  - A test checks that a normal image has no listener.
- **Files:** copies land in Taisce on a RAM-backed block device. Lifting
  Taisce's service here means bring-up uses the one file system, not a
  second RAM-only one (D8). Durability on disk is V5's.
- **Push and run** (todhchai N1e): the launcher finds programs in a
  writable `/dev/bin` over bootfs's `bin`, so `scp prog board:/dev/bin/ &&
  ssh board restart prog` runs a new build without a reboot.
- **Board tools:** `log -f` (the debuglog, streamed), `ps`, `kill`,
  `restart`, `trace`, `poweroff`, `reboot`.
- **Warm boot:** `ssh board warmboot kernel.elf bootfs.img` hands off to a
  new kernel and bootfs held in memory. No firmware, no stick.
  - The kernel reuses the loader's ELF, page-table and handoff code
    (`lib/elf`, `lib/pagetables`, `lib/handoff`): it parks the other CPUs,
    builds a handoff from the one it booted with, and enters the new
    kernel as the loader would.
  - It goes through `SYSTEM_POWERCTL` as a new command, so no new syscall
    and the ceiling holds.
  - `vx remote boot HOST` does the copy and the call in one step.
- **The GENI console, written ahead:** a polled driver for the Qualcomm
  GENI UART in the loader and the kernel's early console (SPCR interface
  type 0x13). AbyssBSD's `uart_dev_qcom_geni.c` is the reference. QEMU has
  no GENI, so a register-level model test covers it here and the board
  proves it in V4.

**Exit, in QEMU on amd64, arm64 and rv64, under `vx ci`:**
- `ssh` gives rc.
- `scp` of a program to `/dev/bin`, then run it.
- `log -f` streams while a test runs.
- `vx remote boot` round-trips to a new kernel and is back on SSH.
- No listener without `--ssh`.
- The bring-up budgets are green.

## V4. Radxa Dragon Q8B

The board work starts with V3's link, so every later step is a rebuild
and `vx remote boot`, not a stick and a walk.

1. **Console first:** the loader and kernel print through the GENI UART
   from the first boot. This needs a 1.8 V USB-serial adapter on the
   40-pin header: pin 6 GND, pin 8 TX (gpio63), pin 10 RX (gpio64). Never
   connect it to the 3-pin header by USB-C, which is 12–20 V power in.
2. **The platform:** GIC with ITS, SMP across the heterogeneous cores,
   PCIe segment 4 behind UEFI's TC9563 switch, and the SMMUv3 under the
   hypervisor's rules (AbyssBSD's `lessons.md`).
3. **Ethernet:** a TC956x driver (XGMAC2, XPCS, QCA8081 PHY) in the net
   class, after AbyssBSD's `tcx` driver and `ethernet-tc956x.md`. Note the
   DMA address offset of `0x10_0000_0000`.
4. **The V3 link on the board:** `ssh`, `scp`, `log -f` and `vx remote
   boot` against the Q8B.
5. **Then the rest:** NVMe, `qcom-gcc`, a GOP framebuffer text console,
   and USB for HID.

`firmware/README.md` lists each blob's provenance.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- Q8B power-on → console, and warm-boot turnaround, are within budget.

## V5. Taisce on disk

- Taisce's volumes on virtio-blk, then NVMe (V3 lifted the service on a
  RAM disk).
- Attributes, indices and live queries over the Node protocol.
- Crash, shadow-model and query fuzzers run in CI.

**Exit:** the file budgets are green, and the crash harness passes every
write prefix.

## V6. Desktop

- Radharc, Tracker and Deskbar, from simplefb or GOP up to virtio-gpu.
- `tile` and `space` workspace modes, switchable live with both arrangements
  kept. Spatial Tracker.
- SDK, with a reference app in ≤ 12 calls.
- Adreno 690 display, after ADR-0019's plan.

**Exit:**
- The desktop budgets are green on QEMU and on the Q8B.
- The mode-switch budget is green.

## V7. Edge: 9gate and the swarm

- 9P2000.L codec and translator, with export and import, on V3's stack.
- Noise IK transport, on V3's crypto.
- VectraOS↔VectraOS extensions for attributes, queries, leases and ring
  bridging.
- Swarm node roles and `/swarm/pool`.

**Exit:**
- Linux `v9fs` mounts a VectraOS export and passes conformance.
- A PC mounts the Q8B's `/dev`.
- The LAN budgets are green.

## V8. Compute

- The `/dev/accel` protocol, `.vxm` artifacts, the `vxc` host compiler
  (ONNX/StableHLO → TOSA) and the CPU TOSA executor.
- The CDSP backend on the Q8B: a first-party FastRPC driver following
  AbyssBSD's NPU notes.
- Adreno Vulkan compute.

**Exit:**
- One `.vxm` runs on the CPU, the CDSP and Adreno, with results checked
  against the CPU reference.
- The camera → NPU → render path does 0 CPU pixel copies.

## V9. Wasm and games

- `wasmd`, interpreter first, then AOT through `vxc`.
- WASI over nodes and rings.
- A reference game: a frame-loop intent, input and audio rings, Vulkan.

**Exit:**
- A Wasm build of a small Bevy or Godot sample runs at its frame budget on
  the Q8B.

## Research tracks (unscheduled)

- CHERI-RISC-V on rv64 (QEMU-CHERI first).
- Halide-style algorithm/schedule split in VXCompute.
- hetIR-style checkpoint and migration of accelerator work across swarm
  nodes.
- RK3588 (DT-only, so it needs an ADR) and the Hailo-8 over M.2.

## Known issues

1. **The rv64 PMU self-test fails intermittently** (found 2026-10-15, in V0's
   first `vx ci`). `boot-smoke` panicked with `pmu self-test: overflow
   sampling`: overflows 57, samples 55, with frames 55, on idle CPUs 1
   (overflows 1). The next 4 runs passed, so it failed 1 time in about 6
   rv64 boots. `PmuSelfTest` counts any cycle sample on another CPU as
   "on an idle CPU". A background thread (`dlog-dumper`, `reclaim`) that
   runs during the sampling window may be enough to trip it. Not yet
   diagnosed. Fix before V0 exits, either in the kernel or in the test's
   definition of idle, with the reason written in
   `docs/kernel/design/cpu.md`.
2. **Status of todhchai's N1** (2026-10-15). It lives on its unmerged `n1`
   branch:
   - **Done:** crypto, the stack hosted and native, sshd hosted with SFTP,
     the net class, virtio-net.
   - **Left:** sshd on croi (d4), rc on a pty (d5), push and run (N1e).
   - **Open there:** a decision on where a headless boot's host key lives,
     because the native keyring needs Radharc for its prompt.

   V3 lifts from a pinned commit of that branch. It either waits for d4/d5
   or does them here; IMPORTS.tsv records the commit either way.

## Open questions

1. Host tests: SwiftPM plus CTest, as todhchai does, or CTest only (D11).
   Decided in V0.
2. ~~The shell~~: todhchai's rc, because V3's SSH sessions run it (D15).
3. A dedicated transport for remote ring bridging, versus 9P reads and
   writes (V7).
4. Whether the CDSP accepts unsigned first-party Hexagon code on the Q8B's
   firmware. Check AbyssBSD's `npu/` notes before V8.
5. `space` mode: is it plain free placement with spatial memory, or also a
   pannable, zoomable canvas larger than the screen? Decided in V6 against a
   reference workflow.
6. A hardware watchdog on the Q8B, so that a hang becomes a reboot into
   the stick's known-good kernel instead of a walk. Does the firmware
   expose WDAT or an SBSA watchdog? Check in V4.
7. UEFI network boot (todhchai N1f), for recovering from a kernel that
   won't come up at all. Not chosen for V3 (D15); revisit if V4's hangs
   are frequent.
