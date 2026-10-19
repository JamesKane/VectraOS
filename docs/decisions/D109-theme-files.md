# D109. UICore's theme is ported onto roles: theme files are ndb entries, resolved in D108's layers by one tier 0 library (2026-10-18, decided; extends D91, D107, D108)

D107's first step ports UICore before any app is ported onto its
styles. todhchai's `Theme` is a Swift value: a `Tokens` struct of
colours named by hue (`cyan`, `magenta`, `phosphor`) and about a
hundred styles by class, built by a Swift function. A theme there is
code. D91 needs it to be data, over roles, and D108 needs layers in the
resolver from its first version. This entry settles the file, the
library that reads it and what UICore keeps, and answers
`docs/theming.md` §12's second question.

## The file

- **A theme file is ndb(6)'s format.** The owner chose this
  (2026-10-18) over plumb(6)'s verb lines and a format of its own:
  the device already parses ndb, and the system should have one rules
  syntax (theming.md §12, ghost.md §13). ndb's parser leaves
  `services/ndb` for a library of its own, `system/ndb` (`NdbFile`),
  which ndb, the themes and later the Ghost's policy all read. Its
  pairs carry their line numbers, so `theme check` names the line.
- **A file is records.** A record begins at a head pair (`theme`,
  `role`, `typeface`, `part`, `knob`, `parts`, `textscale`), and its
  other pairs are the ones after it, up to the next head. An entry,
  ndb's unit, matters only to a variant: `variant=dark` makes the rest
  of its entry the variant's.
- **Quoting is ndb's.** A value with a space in it is quoted. That
  happens in names people read (a theme's title, a font's family, a
  knob's label), and never in the names code looks up (roles, parts,
  knobs), which are dotted words.

```
theme=neon-tab title="Neon Tab" inherits=base version=1
	author="todhchai's storyboard, ported" licence=BSD-3-Clause
role=desk color=0x0a0a12
role=chrome color=0x12121e
role=neon.cyan color=0x00e5ff
role=panel color=chrome
typeface=body family="IBM Plex Sans" weight=400
typeface=ui family="Barlow Condensed" weight=500
part=button stroke=control ink=ink border=1
	font=ui weight=600 size=12.8 tracking=0.08 case=upper
	padding=5.76,11.52,5.76,11.52
part=code.highlight fill=neon.cyan@14
knob=accent type=role default=neon.cyan suggest=neon.cyan,neon.amber
	label="Accent colour"
knob=density type=choice choices=compact,regular default=regular
	label="Window density"
part=window.body.focused stroke=$accent glow=5.76 glowcolor=neon.glow
parts=window.* from=next
variant=high-contrast title="Neon Tab, high contrast"
	role=desk color=0x000000
	role=chrome color=0x000000
	textscale=1.25
```

  A layer is the same format. A user's layer that turns a knob and
  changes one face reads:

```
knob=accent value=neon.amber
typeface=mono family="IBM Plex Mono" weight=500
```

- **Values.**
  - A colour is `0xrrggbb` or `0xrrggbbaa` in sRGB, `none`, a role, or
    a role at an alpha in percent (`neon.cyan@14`). The form is
    draw(2)'s, not CSS's `#rrggbb`, because in ndb `#` begins a comment
    wherever it stands. A colour written with `#` would need quotes, and
    unquoted it would silently read as empty.
  - A role's colour may name another role, resolved last, so a
    variant that changes `chrome` changes `panel` too.
  - Lengths are logical pixels, and `$name` is a knob.
  
  Linear light and an HDR peak in nits wait for the colour design,
  which comes before Radharc's step (D107).

## The library

- **`Themes`** (`ui/theme`, tier 0) holds:
  - the role set of theming.md §2.1 with `term.0` to `term.15` (D108);
  - the parser;
  - the resolver;
  - the check;
  - the system's base theme, compiled in so that resolving never
    lacks a root.
  
  Radharc, UICore and `vx theme check` all link it. Apps never parse a
  file: from Radharc's step on, they get its resolved form in a
  shared VMO (D91).
- **The resolver is D108's stack.** In order: the base, the theme's
  chain (`inherits`), the variant, then the user's, the workspace's,
  the output's and an app rule's layers, each a file of the same
  format. High contrast sits on top. A layer sets a knob with
  `knob=NAME value=V`.
  1. Everything is merged symbolically, so roles and knobs stay
     names.
  2. Borrowed parts (`parts=PREFIX from=THEME`) are taken from the
     lender's own resolved chain.
  3. Then each part is evaluated against the borrower's roles. A
     role the borrower lacks takes the lender's value.
  
  A cycle in `inherits`, a role, length or knob that can't be resolved,
  or a knob set outside its type is an error. It is named with its
  file and line, and the layer that caused it is refused while the
  stack beneath it stands (theming.md §13.4).
- **The check** (`theme check`):
  - Every required role resolves.
  - Ink against its surface is at least 4.5:1: `ink`, `ink.dim` and
    the meanings on each surface role, `ink.on-select` on `selection`,
    `ink.on-focus` on `focus`, and each part's ink on its own opaque
    fill.
  - `control` is at least 3:1 against each surface.
  - These hold in every variant, and at each knob's extremes with the
    others at their defaults.
  
  The kit frame drawn at four scales and the composition cost join it
  with Radharc and the GPU (theming.md §7). The host's
  `vx theme check FILE...` runs the same code. It joins `vx ci` with
  step 5, but ThemesTests already passes every shipped theme through
  it.

## What UICore keeps

- **todhchai's resolved form stays** (theming.md §11): a `Style` per
  class with dot fallback, in sorted arrays because tier 0 has no
  dictionary.
  - `Tokens` and the hue-named fields go.
  - `Theme.color` takes a role.
  - `Theme.neonTab` and `Theme.accessible` become files:
    - Neon Tab, translated from todhchai's `storyboard` function;
    - its accessible theme, as Neon Tab's `high-contrast` variant.
  
  UICore's tests prove the port: Neon Tab's file resolves to exactly
  the styles todhchai's code built.
- **States are parts with derivations.** `X.held` (pressed) that a theme
  doesn't define is derived as todhchai derived it: the accent at 20%
  inside, the edge and label in the accent. Disabled is `ink.disabled`
  over the same part. Class names stay todhchai's (`button.primary`,
  `window.tab.focused`, `.held`) until each app is lifted, which
  renames none of them.
- **Materials beyond a flat fill** are parsed, resolved and checked now,
  and drawn from Radharc's step: gradient, bevel, pattern and shadow. A
  style carries them as layers, and the CPU renderer draws a flat
  fill, an edge, corners, cuts and glow, as todhchai's does. How a
  quad carries a material is theming.md §12's first question. It is
  settled before Radharc's step, against the CPU renderer first and the
  composition budget later, and doesn't change the file.
- **Where themes live:**
  - in the tree, `ui/theme/themes/NAME`;
  - on the device, `/lib/theme/NAME` in bootfs, from Radharc's step.
  
  The base is compiled in.

Not chosen:
- plumb(6)'s lines, and a format of themes' own (the owner's choice
  above);
- keeping `Tokens` beside roles for a transition (two vocabularies,
  which D91 rejects);
- resolving to concrete colours before borrowing parts, which would
  carry the lender's palette with its parts and defeat D108's
  borrowed parts.
