# D2. The kernel: lift croi, then slim it (2026-10-15, decided)

Import croi whole in V0 so the system boots from day one. In V1, audit every
object and syscall against the setup-engine role (principle 4). Cut what
rings replace. Publish a syscall-count ceiling that only goes down.

- **Rejected:** a new minimal kernel mined from croi. It is slower to reach
  a boot, and croi's object model is already capability-based.
- **Rejected:** keeping croi unchanged. That leaves two bulk mechanisms.
