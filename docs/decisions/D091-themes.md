# D91. Themes are data over one vocabulary; Platinum Indigo is the default, not the only look (2026-10-17, proposed; extends D24)

The owner's direction (2026-10-17): the storyboarded UI is the default
experience, but the system belongs to the user, who can adopt any
visual style in `space` and `tile` workspaces. Themes after todhchai
and NeoVectra ship too, as seams and examples for new theme providers.
Every theme scales from 1080p to 4K and beyond, so chrome isn't a
bitmap unless a budget can't otherwise be met. `docs/theming.md` is the
design.

- **A theme is one text file, data and never code:** tokens named by
  role (not by hue), materials (flat, gradient, bevel, glow, pattern,
  shadow), parts drawn from a fixed vocabulary of signed-distance
  primitives, type, icons, motion and a choice of first-party effect
  passes, with inheritance and variants.
- **One mechanism:** Radharc serves the theme tree and gives apps the
  resolved theme in a shared VMO; decorations, the UI kit, Tracker,
  Deskbar, rio and the manual viewer all read it.
- **Themes follow workspaces,** stored beside the mode (D9); a window
  takes its workspace's theme.
- **Vector at every scale,** hairlines snapped to device pixels; the
  only bitmap is a part cache the renderer keeps, at the exact scale,
  when the composition budget would otherwise fail.
- **No theme changes** the trusted path, the lamps' meanings, or the
  legibility floor (4.5:1 text, 3:1 control edges); high contrast is one
  switch in every theme.
- **Shipped:** Platinum Indigo (default), Graphite, Indigo Magic
  (NeoVectra's `vx-magic`), NeXT (`vx-next`), Neon Tab (todhchai's look,
  which D24 replaced as the default) and High contrast, each proving a
  different seam.
- **Proposed placement:** V5, with Platinum Indigo, High contrast and
  Neon Tab at its exit, since the seams must be built with the default
  look, not after it.

Not chosen: themes as code (third-party code in the compositor, D4);
bitmap themes per scale (a second set of assets per scale, and blurred
at fractional ones); a theme per app chosen by the app (the user's
choice, not the app's); keeping todhchai's hue-named `Tokens` (it ties
every theme to Neon Tab's palette).
