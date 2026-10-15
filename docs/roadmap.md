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

## V1. Setup-engine kernel

- Audit every object and syscall, and write a decision entry for each cut.
- Implement the one ring (architecture §3) in Swift and as `ring.h`, with a
  model checker.
- Doorbells are counters, and waits go through ports.
- Close the `channel_call` < 1 µs open item.

**Exit:**
- The kernel and IPC budgets are green.
- The syscall ceiling is published.
- `ring_kicks` = 0 under load.

## V2. Userland base

- Lift todhchai's ipc, node, namespaces, launch, sys, libc, router, the
  bus/PCI/ACPI drivers and virtio.
- Choose one shell.
- Console in QEMU.

**Exit:**
- `cat /svc/*/status` works.
- spawn → main < 200 µs.
- Services RSS < 32 MiB.

## V3. Taisce

- Lift Taisce as the FS service over virtio-blk, then NVMe.
- Attributes, indices and live queries over the Node protocol.
- Crash, shadow-model and query fuzzers run in CI.

**Exit:** the file budgets are green, and the crash harness passes every
write prefix.

## V4. Radxa Dragon Q8B

- Boot from UEFI and ACPI on SC8280XP: GIC with ITS, SMP across the
  heterogeneous cores, and the SMMU with the hypervisor's constraints.
- Stream logs off the board on every boot, which AbyssBSD's lessons
  require.
- Drivers: NVMe, `qcom-gcc`, a GOP framebuffer console, USB for HID, and
  Ethernet (TC956x).
- `firmware/README.md` lists each blob's provenance.

**Exit:**
- The native suite passes on the board through the serial budget scrape.
- Q8B power-on → console.

## V5. Desktop

- Radharc, Tracker and Deskbar, from simplefb or GOP up to virtio-gpu.
- `tile` and `space` workspace modes, switchable live with both arrangements
  kept. Spatial Tracker.
- SDK, with a reference app in ≤ 12 calls.
- Adreno 690 display, after ADR-0019's plan.

**Exit:**
- The desktop budgets are green on QEMU and on the Q8B.
- The mode-switch budget is green.

## V6. Edge: 9gate and the swarm

- 9P2000.L codec and translator, with export and import.
- Noise IK transport.
- VectraOS↔VectraOS extensions for attributes, queries, leases and ring
  bridging.
- Swarm node roles and `/swarm/pool`.

**Exit:**
- Linux `v9fs` mounts a VectraOS export and passes conformance.
- A PC mounts the Q8B's `/dev`.
- The LAN budgets are green.

## V7. Compute

- The `/dev/accel` protocol, `.vxm` artifacts, the `vxc` host compiler
  (ONNX/StableHLO → TOSA) and the CPU TOSA executor.
- The CDSP backend on the Q8B: a first-party FastRPC driver following
  AbyssBSD's NPU notes.
- Adreno Vulkan compute.

**Exit:**
- One `.vxm` runs on the CPU, the CDSP and Adreno, with results checked
  against the CPU reference.
- The camera → NPU → render path does 0 CPU pixel copies.

## V8. Wasm and games

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

## Open questions

1. Host tests: SwiftPM plus CTest, as todhchai does, or CTest only (D11).
   Decided in V0.
2. The shell: todhchai's `shell` or a Swift `rc` (V2).
3. A dedicated transport for remote ring bridging, versus 9P reads and
   writes (V6).
4. Whether the CDSP accepts unsigned first-party Hexagon code on the Q8B's
   firmware. Check AbyssBSD's `npu/` notes before V7.
5. `space` mode: is it plain free placement with spatial memory, or also a
   pannable, zoomable canvas larger than the screen? Decided in V5 against a
   reference workflow.
