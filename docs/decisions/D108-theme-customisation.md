# D108. Themes are customised in layers: a theme's knobs, borrowed parts, and the user's overrides by workspace, output and app, all in the theme format (2026-10-18, decided; extends D91)

D91 gives a user any theme, and gives a theme author inheritance and
variants. A person who likes Platinum Indigo but wants a green accent,
a denser Deskbar, NeXT's title bar or larger type can still only get
there by copying a whole theme and editing it, and that copy no longer
follows its parent's fixes. The owner asked for theming to be more
customisable (2026-10-18). This entry adds customisation without
adding a second styling mechanism: everything below is a theme file,
read by the same parser and judged by `theme check`.
`docs/theming.md` §13 is the design.

- **The resolved theme is a stack of layers,** each a theme file of
  overrides. From the bottom:
  1. the system's base;
  2. the theme's inheritance chain;
  3. its variant (`dark`, `high-contrast`);
  4. the user's own layer;
  5. the workspace's layer;
  6. an output's layer;
  7. an app rule's layer.
  
  A layer names only what it changes, so the theme under it still takes
  its author's updates. `ctl set` (the Appearance editor's live edit)
  writes to the user's layer or the workspace's, never into an
  installed theme.
- **Knobs:** a theme may declare named parameters with a type and a
  range: a role's colour (the accent: any colour, or one of a set the
  author suggests), a choice (density
  `compact`, `regular` or `comfortable`; the tab's side; the order of
  the close and zoom boxes), or a length or scale (corner radius, the
  text scale apart from the UI scale). Parts and tokens refer to knobs,
  and the Appearance panel shows them as controls. Setting a knob is
  one line in a layer. `theme check` judges the legibility floor at
  each knob's extremes, with the others at their defaults, and the
  user's own settings when they are loaded.
- **Borrowed parts:** a layer or a theme may take a family of parts
  from another installed theme (`parts window.* from next`). They are
  drawn with the borrowing theme's roles, so NeXT's title bar comes in
  Platinum Indigo's colours. A borrowed part is resolved and checked
  like the theme's own.
- **More of the screen is themed:**
  - the pointer's cursors, as vector parts;
  - rio's and vt's sixteen colours, as roles `term.0` to `term.15`, so
    a program's colours follow the theme;
  - the Deskbar's edge and density;
  - the desk's material and picture;
  - each font role's face and size.
- **Saving and sharing:** **Save as theme** flattens the stack into one
  file that inherits from the theme it started from. Sharing a theme is
  copying that file (principle 24). One that comes over 9gate is
  checked before it loads, like any other.

What stays as D91 has it: a theme is data, never code; the trusted
path, the lamps' meanings and the legibility floor are no layer's to
change; and high contrast stays one switch, above every layer.

Budgets: none new. A layer or knob change is a theme change, and
`theme.switch` (every visible window redrawn within two frames) judges
it. The part cache's key gains the layer stack's generation.

Placement: V5, with the themes' step (D107). The layers and knobs are
built into the resolver from its first version, not added after
Platinum Indigo, because a resolver designed for one file per theme
keeps that assumption.

Not chosen:
- user CSS-like selectors over any element, which make every widget's
  structure a promise to theme authors;
- per-app theming chosen by the app (D91);
- a separate "accent colour" setting outside the theme format, which
  would be a second styling mechanism.

A layer may still set any token or part, not only a knob: knobs are
what the author curated for the panel, layers are the whole format.
Whatever a layer sets is judged by `theme check` when it loads, and a
layer that fails the floor is refused with the reason, as a theme is.
