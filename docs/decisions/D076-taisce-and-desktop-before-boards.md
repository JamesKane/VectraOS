# D76. Taisce on disk and the desktop come before the boards (2026-10-16, decided; amends D16)

The owner's direction (2026-10-16): Taisce on disk and the desktop move
ahead of board bring-up. D16's reason for the order holds and now
reaches further: a board should meet a system whose parts are already
tested in QEMU, not bring them up there for the first time. Milestones
still run in number order, so they are renumbered:

| Was | Now | Milestone |
|---|---|---|
| V3 | V3 | Bring-up link |
| V5 | V4 | Taisce on disk |
| V6 | V5 | Desktop |
| V4 | V6 | Orange Pi 6 Plus |
| V4b | V6b | Orange Pi RV2 |
| V4c | V6c | The AMD tower |
| V7–V9 | V7–V9 | unchanged |

- **What needed a board moves to the board.** Taisce's volumes on NVMe
  and the desktop on the Orange Pi 6 Plus (its GOP framebuffer, then its
  own display path, D69) are now V6's items and exit; NVMe on the tower
  is V6c's. V4 and V5 finish in QEMU: Taisce on virtio-blk, the desktop
  on GOP or ramfb and then virtio-gpu.
- **The living documents use the new names**: the roadmap, CLAUDE.md,
  the README, the architecture, performance and provenance notes, the
  board notebooks, and the support list's `milestone` column. Decisions
  before this one keep their text, as records: read their V4, V4b, V4c,
  V5 and V6 through the table above.
- The bring-up link stays ahead of everything that runs on a board
  (D15); nothing in V4 or V5 needs it except Taisce's file copies, which
  already land on its RAM disk (V3).
