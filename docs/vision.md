# Vision

The source is *Scalable Edge Architecture: Integrating Microkernel
Ring-Buffers, 9P Userlands, and Heterogeneous Compute IRs* (October 2026). This
document says what VectraOS takes from that paper, what it changes, and what it
defers.

## The problem

Edge hardware is fragmented. The examples are Raspberry Pis, RK3588 and
SC8280XP boards, Hailo-8 modules and desktop GPUs. Each accelerator comes with
its own vendor toolchain: RKNN-Toolkit2, the Hailo Dataflow Compiler, QNN.
Monolithic kernels add per-packet and per-frame overhead through context
switches, copies across the user/kernel boundary, and lock contention. Indie
game developers, makers and systems hackers pay for both.

## The answer, in three layers

1. **A ring-buffer microkernel.** The kernel is a *setup engine*. It creates
   address spaces, threads, capabilities and shared regions, then gets out of
   the way. Bulk data moves in user space over lock-free SPSC rings that live
   in shared memory. Drivers are user processes that receive DMA memory
   through capabilities. LionsOS reaches about 9.6 Gb/s against Linux's
   3.5 Gb/s on the same core; that gap is our reference point.
2. **A namespace userland.** Every resource is a node in a per-process
   namespace, in the Plan 9 style: devices, services, windows, accelerators
   and remote machines alike. The control plane goes through the namespace.
   The data plane is the ring that the control plane negotiated. The
   namespace is exported to other machines over 9P2000.L, so
   `mount tcp!pi5!564 /n/pi5` gives you that board's devices.
3. **A heterogeneous compute IR.** Models and kernels are written once and
   lowered to the CPU, GPU or NPU on whichever node they run. Accelerators
   appear as nodes under `/dev/accel`. Inference is ring traffic between a
   camera, an accelerator and a renderer, and the CPU never touches the
   frames.

## What we take, and how it changes

| The paper says | VectraOS does | Why |
|---|---|---|
| A verified seL4/LionsOS kernel | croi, Swift with strict memory safety, cut down to the setup-engine role (D2) | We have a working kernel on 3 arches. We get memory safety from the language. We do not claim a formal proof. |
| SPSC rings with acquire/release cursors and cache-line padding | One ring format for every bulk path (architecture §3) | As the paper describes it: 128-byte cursor separation and counter doorbells. |
| 9P2000.L everywhere | The Node protocol locally and 9P2000.L on the network (D3) | Typed, zero-copy IPC on the machine. Linux v9fs and 9front can still mount us. |
| FlatBuffers for structured payloads | The IPC wire format (todhchai `wire-format.md`) everywhere (D6) | It is already little-endian, aligned and decoded in place. A second encoding would break principle 1. |
| MLIR, StableHLO, TOSA | Host-side compilers lower to TOSA. The device runs our own TOSA executor and backends (D4). | Nothing third-party on the device. Heavy compilers run where the developer is. |
| Halide algorithm/schedule split | A research track for the compute SDK | Valuable, but only after a working TOSA path. |
| WASI unikernels for Godot and Bevy | Wasm runs as an ordinary process whose WASI imports map onto the Node protocol and rings (D7) | On a microkernel a process already is the minimal environment. A second kernel image per app would be a second mechanism. |
| CHERI compartments | Deferred. rv64 is kept ready for CHERI-RISC-V (roadmap, research) | No CHERI hardware in our targets yet. The capability model is designed so CHERI could enforce it later. |
| hetIR live migration across GPUs | Research track after the swarm milestone | Depends on a working accelerator stack on two kinds of hardware. |
| SigmaOS realms, procs and initd | The swarm: node roles, Noise IK, leases (from NeoVectra's docs/02 §6) | The same idea expressed through namespaces. |
| RK3588 and Hailo-8 | The **Radxa Dragon Q8B** (SC8280XP, Adreno 690, Hexagon CDSP) first (D5). RK3588 and Hailo-8 later. | AbyssBSD already runs the Q8B under UEFI and ACPI, NPU included, and its notes are our ground truth. |

## Who it is for

- **Indie game developers.** A frame loop with a guaranteed deadline. Input,
  audio and GPU submission over rings. Wasm games run next to native Swift
  ones.
- **Makers.** Mount a board, `cat` its sensors, and pipe frames into an NPU
  from the shell.
- **Systems hackers.** The whole base system is small enough for one person
  to understand, measured against budgets, and traced end to end.

## What success looks like

These are the vision's demonstrations, in milestone order:

1. A Q8B boots VectraOS from NVMe to a desktop within its boot budget.
2. On a PC, `mount` exports the Q8B's `/dev/accel/cdsp0`. A camera
   ring on the PC feeds the remote NPU, and the masks come back into a game's
   render ring.
3. The same model runs on a Q8B CDSP, an Adreno GPU and a PC CPU, from one
   artifact, without changing a line of app code.
4. A Linux machine mounts a VectraOS namespace with stock `v9fs`.
