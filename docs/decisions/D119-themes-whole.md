# D119. The themes whole: Settings' Appearance area is the theme in force, a theme per workspace, an accent knob in each shipped theme, high contrast one switch, and `theme.switch` measured by Radharc (2026-10-22, built; for the owner's review; extends D91, D108, D109, D113, D116)

V5's step 5 (D107; `docs/theming.md` §8 to §13). The resolver already
has D108's layers, knobs, borrowed parts and the high-contrast switch
(D109), and both shipped themes have a high-contrast variant. What
was missing is everything that reaches them from the desk:
- Radharc started in Platinum Indigo every time, and nothing read
  Settings' `Appearance:Theme`.
- No shipped theme had a knob.
- There was no theme per workspace.
- `theme.switch` had no check.
- `vx theme check` wasn't in `vx ci`.
- The kit frame's tests left out the high-contrast variants.

The owner set finishing V5 as the goal and left the choices here to
the recommendations, so this note is for their review.

## Decided

- **Settings' `Appearance` area is the theme in force.** Radharc reads
  it at start and follows it through its Settings watch (D116's):
  - `Appearance:Theme`: the theme;
  - `Appearance:HighContrast`: high contrast, one switch over every
    layer (theming.md §6);
  - `Appearance:Accent`: the accent knob's choice, `theme`, `cool` or
    `warm`.

  `ctl`'s `load`, and a new `contrast on|off` and `knob NAME VALUE`,
  write the same attributes. So the preference app, rc's `attr` and the
  theme tree are three doors to one store, not three mechanisms. A
  value that doesn't resolve or fails the floor is refused, as `load`
  is today, and the theme before stays.
- **The user's layer is the knobs.** The Appearance settings become one
  layer of `knob=NAME value=VALUE` records over the theme. A knob the
  theme doesn't declare is left out, so a theme without an accent
  ignores the setting rather than refusing.
- **A theme per workspace:** `Workspaces:<n>:Theme`, set by `ctl`'s
  `theme <name>|none [<n>]`, is the theme in force while that workspace
  is shown; `none` follows `Appearance:Theme`. There is one output, so
  one workspace shows at a time, and switching workspaces is a theme
  change, judged by `theme.switch` like any other.
- **The accent knob.** Each shipped theme declares `knob=accent
  type=role` with the roles `accent.theme`, `accent.cool` and
  `accent.warm`, and its `selection` is the knob:
  - Platinum Indigo: blue, teal or plum.
  - Neon Tab: magenta, cyan or amber.

  `theme check` judges each suggestion at the floor, as D108 says.
- **`theme.switch` is Radharc's to measure.** A window that follows the
  theme says which generation its next present is drawn in
  (`drawnIn(generation:)`, the Window protocol's version 10; the SDK
  calls it after each `.themeChanged`). A theme change records its
  vblank. The switch is done at the first latch at which every visible
  window that has ever said a generation shows a present drawn in the
  new one. The frames between are `theme switch <n> frames` in
  `status`. kit-test reports `budget name=theme.switch` for a switch
  between the two themes and for an accent change; the bench judges
  it, limit 2. Radharc can't tell a follower otherwise: the theme's
  `events` readers are anonymous.
- **`vx ci` runs `vx theme check`** over every shipped theme, with
  every variant and knob extreme it already judges.
- **The kit frame's pixel tests include each high-contrast variant,**
  at 100%, 150%, 200% and 300%, beside the plain ones. Drawing them
  showed Platinum Indigo's high contrast kept its gradients' light
  colours under white ink: its variant now draws those parts flat, and
  its field a well.

## Left out

- **Edit and Save as theme (theming.md §10, §13.4).** An editor of a
  user's layer, with its findings live, is an app of its own over the
  same `ctl`. It isn't needed by V5's exit, and is listed in the
  roadmap.
- **An output's layer and app rules:** there is one output until the
  GPU's outputs (step 6). One resolved theme is served to every
  client, so an app's own theme would need a theme a window, which is
  D108's open question.
- Graphite, Indigo Magic and NeXT: with V6's board, as theming.md §9
  allows.
