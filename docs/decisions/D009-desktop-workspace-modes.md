# D9. Desktop: tile and space workspace modes, switchable live (2026-10-15, decided; details proposed)

The owner asked for tiling and spatial window management to be easy to
switch between, with several workspaces of either kind. The design is in
architecture §7.

- **Proposed:** plain stacking is `space` at 1:1, not a third mode.
- **Proposed:** both arrangements persist as Taisce attributes.

**Decided (2026-10-22, D116):** plain stacking is `space`. `space` has
no zoom level, because it is plain free placement, not a canvas. Both
arrangements persist as Taisce attributes on Settings areas
(`Workspaces`, `Frames`).
