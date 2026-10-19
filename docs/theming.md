# Themes

A vision and high-level design (2026-10-17, proposed; D91). The
storyboard's look, Platinum Indigo (D24), is the default experience, but
the system belongs to its user: they can adopt any visual style, in
`space` and `tile` workspaces alike (D9). This document says what a
theme is, how one reaches every pixel of chrome, how a theme scales
from 1080p to 4K and beyond, and which themes ship as worked examples
for the people who will write the next ones.

The sources are D24 and the [storyboard](https://claude.ai/artifact/BcQQLDod1qqmgwVzabeTPX)
(its kit and Appearance frames), todhchai's `docs/desktop.md` §6 and
`ui/core/lib/Theme.swift` (Neon Tab), and NeoVectra's
`03-desktop-agentic.md` §5.4 (reactive tokens) and §9.1 (`vx-magic`,
`vx-next`). §11 says what is taken from each.

## 1. Rules

- **The default is Platinum Indigo,** and it gets no privilege a user's
  theme lacks. It is built through the same seams as every other theme,
  which is how we know the seams are enough.
- **A theme is data, never code.** The compositor and every app read
  it, so a theme that ran code would be third-party code on the device
  (D4) inside the most trusted process the user looks at. Anything a
  theme can express is interpreted by first-party renderers.
- **Every theme is vector.** Chrome, icons and type are drawn from
  shapes and outlines at the output's scale, so one theme serves 100%
  to 300% with no second set of assets. A bitmap is a cache the
  renderer may keep (§5.3), never what a theme is made of.
- **One theme mechanism.** Radharc's decorations, the UI kit's widgets,
  Tracker, Deskbar, rio's text windows and the manual viewer all read
  the same tokens, materials and parts. No component has a private
  styling system.
- **Some things no theme may change** (§6): the trusted path, the
  meaning of the lamps, and the floor of contrast and legibility.
- **Installing a theme is copying a file** (principle 24), and removing
  it leaves nothing behind.

## 2. What a theme is

A theme is one file, text, that a person can read and write on the
device. It has seven sections, all optional but the name, because a
theme inherits from another (§2.7) and overrides only what differs.

### 2.1 Tokens: named roles

A token names a **role**, never a hue. todhchai's `Tokens` struct has
fields called `cyan`, `magenta` and `phosphor`, which tie every theme to
Neon Tab's palette; that is the first seam this design changes.

The required roles are a fixed, versioned set that every theme resolves
(inherited or its own):

| Group | Roles |
|---|---|
| Surfaces | `desk`, `chrome`, `chrome.behind`, `well`, `menu`, `panel` |
| Edges | `outline`, `bevel.light`, `bevel.dark`, `control` (a control's edge, 3:1 against surfaces) |
| Ink | `ink`, `ink.dim`, `ink.disabled`, `ink.on-select`, `ink.on-focus` |
| Meaning | `focus`, `selection`, `live`, `alert`, `warning`, `realtime` |
| Readouts | `lcd`, `lcd.ink` |
| Lamps | `lamp.local`, `lamp.agent`, `lamp.egress`, `lamp.swarm` |

- **Colours are given in linear light** with an SDR reference and an
  optional HDR peak in nits, as todhchai's desktop.md has it, so a glow
  can use an HDR display's headroom and is tone-mapped on SDR. A theme
  author may write sRGB hex; the parser converts it.
- **Lengths are logical pixels:** border widths, radii, the tab's
  height, padding. **Durations** are milliseconds, and **fonts** are
  references to font files (§2.4).
- **A theme may add its own tokens** (`neon.magenta`, `indigo.lavender`)
  for its own parts to use. Apps never see them: an app that styles a
  custom view asks for a role.

### 2.2 Materials: how a surface is filled

A material is a recipe over a rectangle, all of it analytic, so it costs
the same at every scale:

| Material | Parameters | Used by |
|---|---|---|
| `flat` | a role | wells, Neon Tab's panels |
| `gradient` | two or more roles, an angle | Platinum Indigo's tabs and buttons |
| `bevel` | `raised`, `inset` or `groove`; width; the light's angle | Platinum Indigo, Indigo Magic, NeXT |
| `glow` | a role, a reach, a falloff | Neon Tab's focus, the LCD's text |
| `pattern` | stripes, checks or dots; roles; pitch in logical pixels | Be's scrollbar track, MUI's backfills |
| `shadow` | offset, blur, role | window drop shadows |
| `image` | a user's picture, its fit | the desk only (§5.3) |

Materials stack: a button is a `gradient` under a `bevel raised` inside
an `outline`. The light's angle is one token (`light.angle`), so every
bevel in a theme agrees, as NeoVectra's lit chrome required.

### 2.3 Parts: the shapes of each control

A part is a named piece of chrome (`window.frame`, `window.tab`,
`window.tab.close`, `window.tab.zoom`, `button`, `button.default`,
`field`, `check`, `radio`, `group`, `scrollbar.track`, `scrollbar.thumb`,
`menu.item`, `deskbar.row`, `lcd`, `lamp`, and the rest of the kit
frame's components). Each part is drawn from a small, fixed vocabulary
of signed-distance primitives:

- a box with per-corner radius or 45° cut (todhchai's `UIQuad` already
  has both), a line, a circle, a chevron and an inset box;
- each with a material, in layers;
- placed by anchors and logical-pixel offsets within the part's
  rectangle, never by absolute coordinates.

States are variants of a part with the same shape vocabulary:
`button.pressed`, `window.tab.behind`, `field.focused`, `check.on`,
`*.disabled`. A theme that defines `button` and nothing else still
draws every state, by inheritance and by the system's derivations
(disabled is `ink.disabled` over the same part).

What this buys: Platinum Indigo's Be tab, NeXT's full-width black title
bar on the key window, and Neon Tab's chamfered panel are three
definitions of `window.tab` and `window.frame`, not three code paths in
Radharc.

### 2.4 Type

A theme maps todhchai's four font roles (`display`, `body`, `mono`,
`ui`) to families, weights, widths (variable axes), tracking, case and
size. Fonts are data (principle 28's data rule): each font file a theme
ships carries its licence and provenance, as D24 requires for Archivo
and IBM Plex. Text is drawn by our own shaper and MSDF rasteriser at the
output's scale. Every theme falls back through the system's stacks for
characters its faces lack.

### 2.5 Icons

Icons are vectors, one file each (NeoVectra's BeOS-style rule: seen from
above at three quarters, heavy outline, lit from `light.angle`). A theme
may ship an icon set, recolour the system's through roles, or leave
them alone. An icon set missing an icon falls back to the system's.

### 2.6 Motion and effects

- **Motion** is a set of named durations and curves (`motion.fast`, a
  critically damped spring, or `none`). Whether motion exists at all is
  todhchai's open question, and stays one (§12).
- **Effects** are first-party passes a theme turns on with parameters:
  Neon Tab's bloom (a quarter-resolution pyramid, cached until damaged)
  and its CRT pass (scanlines, phosphor decay, a slight barrel), and
  event glitches under 200 ms. A theme can't define a pass, only choose
  one. Effects are dropped first when a frame's budget is short, are off
  under direct scanout and game mode, and never animate an idle desktop.

### 2.7 Inheritance and variants

- `inherits platinum-indigo` takes everything, then overrides. Graphite
  is Platinum Indigo with a dozen tokens changed.
- The root of every chain is **the system's base**, which resolves every
  required role and part plainly, so a theme that defines one token
  still draws everything.
- **Variants** are named overrides inside one file: `dark`, `light`,
  `high-contrast`. A theme that has no `high-contrast` variant gets the
  system's derivation of it (§6).

## 3. Where themes apply

```
 theme file ──parse, check──► Radharc's theme tree ──tokens, materials, parts──►
      │                         /svc/windows/theme/                 │
      │                           active · themes/ · ctl · events   ├──► decorations (Radharc)
      │                                                             ├──► UI kit widgets (each app)
      └── Taisce attributes:                                        ├──► Tracker, Deskbar, rio
          workspace ⇢ theme                                         └──► the manual viewer
```

- **Radharc serves the theme** as a node tree, since it already owns
  decorations (todhchai: decorations belong to the server) and the
  window list (`/svc/windows`). `active` names the theme in force,
  `themes/` lists those installed, `ctl` takes `load`, `set TOKEN VALUE`
  (live, for the Appearance editor) and `variant`, and `events` is a
  waiting read (D84) of changes.
- **Apps receive the resolved theme in a VMO,** read-only and shared, in
  the wire format, with a generation counter. A change bumps the
  generation and arrives in the app's one port (principle 9); the UI kit
  repaints what changed on its next frame. An app never parses a theme
  file.
- **Themes follow workspaces.** Each workspace has a theme, the user's
  default unless they choose another, stored as a Taisce attribute next
  to its mode (D9). A window moved to another workspace takes that
  workspace's theme, as it takes its mode. So a user can keep a NeXT
  `tile` workspace for code beside a Platinum Indigo `space` workspace
  for their files.
- **The user may pin a theme to an app** (a game that wants Neon Tab
  everywhere), by a rule the user writes. An app can't pin one itself.
- **rio's text windows** take their colours and their mono face from
  the theme; a program in a rio window sees no escape sequences either
  way (D75).

## 4. Shipped themes, chosen to prove the seams

Each shipped theme exists for a reason beyond taste: it exercises a seam
the others don't, so a theme author has a worked example of every kind
of difference.

| Theme | From | What it proves |
|---|---|---|
| **Platinum Indigo** (default) | the storyboard, D24 | bevels, gradients and grooves; the Be tab; light from the top left; hairlines snapped at every scale |
| **Graphite** | the storyboard | a theme of tokens only, inheriting every part |
| **Indigo Magic** | the storyboard, NeoVectra's `vx-magic` | a different palette and light over the same parts; the lamps and the LCD restyled |
| **NeXT** | NeoVectra's `vx-next` | a different window shape: a full-width title bar, black on the key window, with no tab |
| **Neon Tab** | todhchai's desktop.md §6 | a dark theme; glow, chamfered cuts, HDR nits, uppercase tracked labels, four typefaces, and the effect passes |
| **High contrast** | todhchai's `Theme.accessible`, the storyboard | the accessibility floor, as a theme and as every theme's derived variant |

- **Neon Tab returns as a choice.** D24 replaced it as the default
  look; it ships as a theme, with the code todhchai already has
  (`Theme.neonTab`, the SDF glow and cuts in `UIQuad`) as its proof
  that porting a look onto the seams is possible.
- **Each shipped theme is a reference file** with comments explaining
  each section, so a new provider starts by copying the nearest one.

## 5. Scale

### 5.1 One scale per output

D24's rule holds for every theme: one UI scale per output, 100% to
300% (the storyboard's Appearance frame: a 3840 × 2160 output at 200%
lays out as 1920 × 1080). Fractional scales are allowed; a 4K display
at 150% is common.

### 5.2 Hairlines and snapping

- Bevels, outlines and grooves are given in logical pixels and **snapped
  to whole device pixels**, after scaling, by the renderer, so a
  one-pixel bevel is one crisp device pixel at 100% and two at 200%,
  never a blurred 1.5. A theme can't opt out.
- Text sits on whole device pixels vertically; todhchai's scroll offsets
  already land on whole pixels for the same reason.
- A window dragged between outputs of different scales redraws its
  chrome at the new scale when it crosses; the compositor never
  resamples chrome.

### 5.3 When a bitmap is allowed

Chrome is never authored as a bitmap. The renderer may still keep one:
- **A part cache.** When a part's layered materials cost more than a
  frame's budget allows (a heavy glow, many layers), the renderer
  rasterises the part at the output's exact scale and state, keyed by
  (theme, part, state, size, scale), and draws the cache. It is
  rebuilt, never resampled, when any key changes. This is the one
  sanctioned bitmap path, and it is a budget measure: it switches on
  per part when the composition budget (§8) would otherwise fail, and
  the trace records that it did.
- **The desk's picture** is the user's image, not chrome, and is scaled
  and filtered as an image. A theme may name a default picture but
  must also define the desk as a material.

## 6. What a theme can't change

- **The trusted path** (the Ghost's approvals, factotum's prompts, the
  storyboard's sealed prompt) is drawn in a material no theme can use or
  imitate, in every theme. The rest of the screen dims around it.
- **The meaning of signals.** Focus and selection stay distinct from
  each other; the lamps (local, an agent live, data left the machine, a
  swarm node in use) keep their meanings and stay distinguishable from
  each other and from their surroundings. A theme may recolour a lamp,
  not repurpose one.
- **The legibility floor.** Text against its surface at least 4.5:1,
  control edges at least 3:1 (todhchai's decision of 2026-10-12, WCAG
  2.2's 1.4.11), and a minimum text size at each scale. A theme that
  fails is refused with the reason, and the previous theme stays.
- **High contrast is one switch** in every theme. It takes the theme's
  own `high-contrast` variant, or the system's derivation of the
  theme, and turns off glow, flicker and motion.

## 7. For theme providers: the seams and their check

A provider gets:
1. **The role set and the part vocabulary,** versioned. A new role or
   primitive is added only with a page and a default in the base theme,
   so older themes keep working (principle 16: a version promises
   little, and every theme declares the version it was written for).
2. **The reference themes** of §4, each the nearest example of a kind of
   difference.
3. **`theme check FILE`**, on the device and as `vx theme check` on the
   host, which parses the file and:
   - resolves every required role and part through inheritance;
   - checks the floor of §6 for every variant;
   - draws the kit frame (the storyboard's component kit) at 100%,
     150%, 200% and 300%, and checks that hairlines land on device
     pixels;
   - measures the theme's composition cost against §8.
4. **Pixel tests,** for the shipped themes: the kit frame drawn by the
   CPU renderer (the UI kit's reference) at each scale, compared by
   `vx check-pixels`, so a change to the renderer that alters a theme is
   seen.
5. **Pages:** `theme(6)` for the file format and `radharc(4)` for the
   theme tree, written with the code (D86).

A look that the vocabulary can't express is a request for a new
primitive or material, made against the base theme and shipped for
everyone, never a private escape hatch for one theme.

## 8. Budgets

Each lands with its check and its milestone (principle 13). todhchai's
desktop budget is the starting point:

| Budget | Target | Check |
|---|---|---|
| `theme.compose.4k` | under 1.5 ms GPU time at 4K with a theme's effects on, under 0.3 ms off, on the reference GPU, for every shipped theme | desktop bench, per theme |
| `theme.compose.board` | the same frame on each board's GPU at its default scale | board bench (V6) |
| `theme.switch` | every visible window drawn in the new theme within two frames of `load` | self-test |
| `theme.idle.wakeups` | 0 with any theme on an idle desktop, effects included | `idle.wakeups` |
| `theme.part_cache.bytes` | the part cache's memory at 4K and 300%, per theme | self-test |
| `theme.check` | every shipped theme passes `theme check` | `vx ci` |

If a theme misses `theme.compose`, its effects are dropped first, then
the part cache switches on for its costliest parts; a shipped theme that
still misses is fixed or not shipped, and the limit isn't loosened in
that change (principle 15).

## 9. Where it goes

Themes are part of **V5**, because the default look and the seams must
be built together: a theme engine designed around one look keeps that
look's assumptions, as todhchai's `Tokens` shows. Proposed for V5:
- the theme file, its parser and `theme check`;
- the role set, materials and parts, with `UIQuad`'s format extended for
  bevels, gradients and patterns (§12);
- Radharc's theme tree and the resolved-theme VMO;
- Platinum Indigo and High contrast, and Neon Tab as the second, unlike
  theme that proves the seams;
- per-workspace themes;
- the layers, knobs and borrowed parts of §13 (D108), in the resolver
  from its first version.

D107 orders V5: UICore's theme is ported onto roles first, before any
app is ported onto its styles; Platinum Indigo is the default from
Radharc's first step; the rest of the themes and the Appearance panel
come after the shell.

V5's exit gains: the desktop budgets green under Platinum Indigo and
Neon Tab, a live switch between them within `theme.switch`, and the kit
frame's pixel tests passing at four scales. Graphite, Indigo Magic and
NeXT follow in V5 if time allows, or with V6's board.

The Ghost (D90) can write themes later, as one of its settings (it
proposes a file; `theme check` judges it).

## 10. The Appearance panel

The storyboard's Appearance frame is the user's front door: the theme
swatches, the per-output UI scale, motion, and the trusted prompt. It
gains:
- a theme per workspace, shown on the Deskbar's workspace tiles;
- **Edit**, which makes a copy that inherits from the selected theme and
  edits it live through `ctl`'s `set`, with `theme check`'s findings
  shown as they happen;
- an app's pinned theme, listed and removable.

## 11. What we take, and how it changes

| Source | Here | Why |
|---|---|---|
| D24 and the storyboard | the default theme, the material rules, the per-output scale | The look decided |
| todhchai's `Theme` (styles by class with dot fallback, sorted arrays for tier 0) | kept as the resolved form | It already fits tier 0 |
| todhchai's `Tokens` (fields named by hue) | roles | A hue-named struct ties every theme to one palette |
| todhchai's `UIQuad` (SDF boxes, cuts, glow) | the base of the part vocabulary, extended | Analytic shapes scale for free |
| todhchai's Neon Tab and its effects | a shipped theme | D24 replaced it as the default, not as a choice |
| NeoVectra's tokens as files, events, derived tokens | Radharc's theme tree and `events` | The same shape, under Radharc |
| NeoVectra's `vx-magic` and `vx-next` | Indigo Magic and NeXT | Two unlike looks over one vocabulary |
| NeoVectra's per-app overrides by `wm` rules | the user's pinned themes | `wm` and Lua aren't carried (provenance) |
| NeoVectra's trusted-path material | §6 | Unchanged |

## 12. Open questions

1. **The quad format.** `UIQuad` is 64 bytes, pinned by a test against
   the shader. Bevels, gradients and patterns need more parameters:
   a wider quad, a second record for materials, or a material table
   indexed from the quad. Measured in V5 against the composition budget.
2. **The theme file's syntax.** Line-oriented `name value` records, as
   NeoVectra's token file was, fit a person editing on the device. It
   should be the system's one rules syntax, the question `docs/ghost.md`
   §13 also asks.
3. **Per workspace or per output.** Per workspace is proposed; a user
   with one theme per output can have that too, by giving each output's
   workspaces the same theme. Is that enough?
4. **Fonts a theme ships.** Only openly licensed fonts with recorded
   provenance, as D24 has it; do third-party themes record theirs in the
   file, and does `theme check` refuse a font with none?
5. **Metrics that change layout.** A taller tab or wider borders change
   a window's content size. Apps already take `configure` events with a
   sequence (todhchai F-208); is any metric off limits to themes so that
   a window's content size never changes on a theme switch?
6. **Motion:** todhchai's open question (springs or none), measured with
   its wakeups, before any theme can ask for it.

## 13. Customisation in layers (D108)

A user who likes a theme but wants it changed doesn't copy it. The
resolved theme is a stack of layers, each a file in the theme format
naming only what it changes, so the theme beneath keeps taking its
author's fixes:

```
 app rule's layer        (a user's rule: this app, this layer)
 output's layer          (this output: larger type on the TV)
 workspace's layer       (this workspace: NeXT's title bar)
 the user's layer        (everywhere: a green accent, compact)
 variant                 (dark, high-contrast)
 the theme and its chain (inherits platinum-indigo ...)
 the system's base
```

High contrast sits above them all: one switch (§6), whatever the
layers say.

### 13.1 Knobs

A theme declares the parameters its author means people to turn, each
typed and bounded; its tokens and parts refer to them. The syntax is
illustrative until §12's second question is settled:

```
knob accent    role  default indigo.lavender  suggest indigo.lavender teal amber
knob density   choice compact regular comfortable  default regular
knob tab.side  choice left right                   default left
knob boxes     choice close-left close-right       default close-left
knob radius    length 0 8                          default 3
knob text      scale  0.8 1.6                      default 1
```

The Appearance panel (§10) shows a theme's knobs as controls; turning
one writes a line to the user's or the workspace's layer through
`ctl set`. `theme check` judges the floor of §6 at each knob's extremes
with the others at their defaults, and again on the layers actually
loaded.

### 13.2 Borrowed parts

A theme or a layer can take a family of parts from another installed
theme, drawn with its own roles:

```
parts window.* from next
```

NeXT's full-width title bar then comes in Platinum Indigo's colours
and light. A borrowed part is resolved and checked as the theme's own.

### 13.3 What more is themed

Beyond §2's tokens, materials and parts, a theme or a layer sets:
- the pointer's cursors, as vector parts;
- rio's and vt's sixteen colours, roles `term.0` to `term.15`;
- the Deskbar's edge and density;
- the desk's material and picture;
- each font role's face and size, apart from the output's UI scale.

### 13.4 Saving and sharing

**Save as theme** flattens the stack into one file that inherits from
the theme it began from. Sharing a theme is copying the file; one that
arrives over 9gate is checked before it loads, as any other is. A
layer that fails the check is refused with the reason, and the stack
stays as it was.

`theme.switch` judges a layer or knob change as it judges a switch of
theme; the part cache's key (§5.3) gains the stack's generation. No
budget is added.
