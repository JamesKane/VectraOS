# VectraOS

VectraOS is a capability microkernel OS for edge hardware: maker SBCs, desktop
PCs and the NPUs and GPUs attached to them. Several machines running it can be
joined into one namespace. It is written in Embedded Swift, with C23 where
Swift cannot reach.

On a single machine:
- the kernel sets up shared memory, and lock-free rings move the bulk data;
- every service is a browsable node in a per-process namespace;
- files carry typed attributes and the file system answers live queries, as
  in BeOS;
- each desktop workspace is either tiled or spatial, and you can switch it
  either way at any time.

Across machines, the namespace is exported over 9P2000.L. A Raspberry Pi's
GPIO, a Q8B's NPU or a PC's GPU becomes a directory you can mount.

This repository starts a new direction. It builds on three earlier projects:

| Source | What it gives VectraOS |
|---|---|
| [croi](../croi) | the kernel, the UEFI loader and the arch code (already Embedded Swift + C23) |
| [todhchai](../todhchai) | performance contracts, the Node protocol and typed IPC, the Taisce file system, the Radharc compositor and the SDK |
| [NeoVectra](../NeoVectra) | the "one mechanism per job" rule, the ring and doorbell data plane, the swarm design and the Q8B hardware notes |

## Start here

1. [docs/vision.md](docs/vision.md): what we are building, and what we take
   from the Scalable Edge Architecture paper.
2. [docs/principles.md](docs/principles.md): the rules every change follows.
3. [docs/architecture.md](docs/architecture.md): how the layers fit together.
4. [docs/performance.md](docs/performance.md): the budgets and how they are
   enforced.
5. [docs/provenance.md](docs/provenance.md): which code comes from which
   repository, and why.
6. [docs/decisions.md](docs/decisions.md): the dated decision log.
7. [docs/roadmap.md](docs/roadmap.md): the milestones and their exit criteria.

## Status

V0 (ground) has not started. The tree holds design documents only.

## License

BSD-3-Clause, as for croi.
