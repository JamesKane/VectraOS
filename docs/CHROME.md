# Chrome: the look, and what it asks of the draw server

**Written before the code. None of this document is built.** A sibling
project, `plan-neo`, drew its desktop as a study before it wrote a line of
it: `~/Development/c/pneo/docs/design/chrome-study.html`, the Plan Neo
Chrome Study. The two projects share their ideas and differ in how they
build them. The study shows the look this tree has always aimed at better than
the tree does. This is the plan to adopt it.

The study names ten parts, A to J, and this document keeps its letters. It
says what each part looks like, and then what the draw server, the toolkit
and the desktop must grow to draw it. `docs/WORKBENCH.md` owns the desktop
and `docs/DRAW.md` the protocol. Each of them points here for the look, and
each keeps its own decisions.

## 1. What changes, and what does not

**The idea is the same.** `docs/HANDOFF.md` section 1 calls the look a
"Cyberpunk Workstation 1994": heavy bevels, brushed metal, lit accents. The
study keeps every word of that and changes three things.

- **The palette.** Magnesium, slate, amber and copper become a violet
  panel over a near-black void, with magenta, cyan, amber and green as
  signal colours. The rule the study states is that neon is signal. A
  colour that glows says something, and a surface that says nothing stays
  dim.
- **The surfaces.** A face is a flat rectangle today. In the study a
  surface is a material: anodized panel, brushed metal, glass, a backlit
  LCD. Each is a recipe of gradients and noise, with no bitmap in it.
- **The desktop's furniture.** A NeXT main menu in place of a menu bar, a
  dock of live tiles on the right, a top bar of status, a column file
  viewer, and vector icons in BeOS's style.

**What does not change.** The window is still a client of `/srv/draw` with
a store of its own. The server still draws chrome and nothing else. The
look is still a file, and a program still never names a colour. The six
verbs stay six. Section 2 is why that last one holds.

| Part | What it is | Where it lands |
|---|---|---|
| A | the window frame: gadgets, a metal title bar, a glow on the active window | `servers/intuition`, section 7 |
| B | a docked main menu, NeXT's, at the top left | `sys/libmui`, a window kind, section 8 |
| C | the same menu as a popup at the pointer | `sys/libmui`, section 8 |
| D | any menu torn off into a panel that stays | `sys/libmui`, a window kind, section 8 |
| E | MUI's preferences: pages, framed groups, knobs, Save/Use/Cancel | `apps/prefs`, section 9 |
| F | LCD readouts and LEDs, the LEDs reporting `/srv` | `sys/libmui`, section 10 |
| G | a column file viewer over the namespace | `apps/workbench`, section 11 |
| H | a dock of live tiles on the right edge | `apps/workbench`, section 12 |
| I | a top bar: the workspace, the display, the status line | `apps/workbench`, section 12 |
| J | vector icons, BeOS's style, a kind per icon | `/lib/icons`, `sys/libraster`, section 6 |

## 2. The rule under all of it: inside a window is the client's

The study draws gradients, noise, inner and outer shadows, glows, blur and
antialiased text. `docs/DRAW.md` section 12 says a gradient is one fill per
row, and that a gradient verb is the seventh verb the protocol guards
against. Both of those stay true under one rule.

**Every effect inside a window's rectangle is the client's, painted in the
client's own memory. Every effect outside it is the compositor's, and is
chrome.**

The first half is possible because of the window store, `docs/DEVTOOLS.md`
step 1. A client maps its window's pixels and paints them directly, and a
write to `store` flushes a rectangle. So a gradient, a noise tile, a glyph
blended onto brushed metal, and an icon's soft shadow are pixels a client
computes and writes. The server never learns what they were. A window stays
one opaque rectangle, which is what the compositor's occlusion and the
backing store both rest on.

The second half is small. A glow around the active window, and a drop
shadow under a window, fall outside every window's rectangle, on the pixels
of the windows beneath. No client may write those. The compositor already
draws one thing over other windows, the cursor. These are the same kind of
thing: chrome, from the server's own state, with no verb.
`docs/DRAW.md` section 19 is that half.

**The cost is the per-face atlas.** `sys/libmui` draws text today by
blitting glyphs baked for one ink on one background, because `blit` is
opaque. A label on a gradient has no one background. So the toolkit stops
drawing through the command stream and paints its window's store, the way
`sys/libapp` already does. The command stream stays for `apps/terminal` and
every client that wants it. Section 13 records the reversal.

**Over a `cpu` connection the store is not shared.** `shmattach` refuses
across the wire, and `sys/libapp` already answers that. It paints a local
copy and sends it as `load` bands. The toolkit does the same, which is
slower and correct. A person who runs the toolkit remotely and minds the
speed turns the effects down, section 3.

## 3. Schemes, roles, and the effects

**A scheme is a set of colours with names. A theme maps roles to them.**
The theme file already does the second half. Roles such as `face` and
`text` name `sys/libpal` colours or six hex digits. The first half is new.
A theme file may define a colour:

    colour void     0a0a18
    colour panel    1b1535
    colour mag      ff2bd6

The theme's roles then name these colours as they name `libpal`'s now. A
scheme is a theme file of `colour` lines and nothing else, so switching
scheme changes every colour and moves no role. The `use` line already picks
a file under `/lib/themes`, and a scheme is one of those files.

**Three schemes ship, and the study's neon becomes the default at brick
5.** Until the frame and the toolkit wear the materials, `/lib/theme` stays
the chassis, and `use neon` is one line.

| Name | Void | Panel | Raised | Well | Text | Dim |
|---|---|---|---|---|---|---|
| `neon` | `0a0a18` | `1b1535` | `2a2150` | `110d24` | `e8e6ff` | `a49cd6` |
| `neon-hc` | `000000` | `0d0d14` | `1d1d2b` | `000000` | `ffffff` | `d8d8f2` |
| `daylight` | `c6c0da` | `e3dfef` | `f1eef8` | `d3cee5` | `17122e` | `4b4470` |

| Name | Mag | Cyan | Amber | Green | Red | Violet |
|---|---|---|---|---|---|---|
| `neon` | `ff2bd6` | `00e5ff` | `ffb000` | `39ff14` | `ff3b5c` | `9d5cff` |
| `neon-hc` | `ff5ce6` | `5cf3ff` | `ffc940` | `6bff4f` | `ff6b82` | `c29cff` |
| `daylight` | `b0008f` | `006b7a` | `8a5a00` | `1c7a00` | `b3002d` | `5b2fc2` |

Each scheme also names its metal (`metal.hi`, `metal.lo`), its bevel light
and shadow, its LCD (`lcd.bg`, `lcd.fg`, `lcd.ghost`), and the edge. The
study has the full list, and the three files copy it. The fourth scheme is
`magnesium`, today's chassis, so today's look stays one line away.

**The roles are what a colour is for, never its hue.** The study calls its
tokens `--mag` and `--cyan`, and uses each for one job. The roles name the
job, and the scheme names the hue:

    accent      mag       the selection, the default button, a menu's hot item
    focus       cyan      the active window, the focus ring, a served folder
    warn        amber     a degraded server, a folder, the LCD's ink
    ok          green     a running server
    fault       red       a failed server, a fault notice
    link        violet    a link, the desk's glow
    panel       panel     a window's body
    raised      raised    a control's face
    text, dim   text, dim labels, and labels that cannot act

The toolkit's roles and the job roles name the same values: `ground` is
`panel`, `face` is `raised`, and `hot` is `accent`. A personal theme written
last month still reads. `well` stays the metric it is, the depth of a sunk
field. The colour of a sunk field waits for brick 3. `sys/libraster` is the
first painter to draw one apart from the panel.

**The effects are roles too, and each is a number.** These are the study's
Effects page, as lines a person may write:

    glow        60        the focus glow's strength, per cent (0 is none)
    bevel       1         a raised edge's width
    shadow      1         a drop shadow under windows, on or off
    scan        0         CRT scanlines over the glass, on or off
    bloom       1         a glow around lit LCD segments, on or off
    motion      1         animation, and 0 is the study's "reduce motion"

`glow`, `shadow` and `scan` are the compositor's, and `intuition` reads them
with the frame's roles. `bevel`, `bloom` and `motion` are the toolkit's.

**Contrast is checked, not trusted.** The study measures every text colour
against the panel for WCAG AA, 4.5 to 1, and finds two tokens that fail on
a raised surface. `tools/contrast.py` does the same over `/lib/themes`: for
each scheme, `text`, `dim`, `accent` and `focus` against `panel`, `raised`
and `well`. It exits non-zero on a pair under 4.5 that a role uses for text,
and the build's `lint` step runs it. A scheme that fails does not ship.

## 4. Materials, and who paints them

**A material is a recipe, and the recipe is code, not a picture.** The
study builds each surface from gradients and noise. `sys/libraster` is the
package that paints them into a pixel buffer. It is a software rasterizer
for ring 3, and it is the only new library the look needs.

| Material | How the study builds it | Used for | Painted by |
|---|---|---|---|
| Anodized panel | fractal noise over a vertical gradient, a bevel lit from the top left | window bodies | the client, `sys/libmui` |
| Brushed metal | two hairline patterns across a gunmetal gradient | title bars, menu titles | the server for a frame, the client for a menu |
| Glass | a blur of what is behind, a bright edge | the overview | the compositor |
| Backlit LCD | an inner shadow, a sheen, unlit ghost segments, bloom | readouts | the client |
| LED | a radial gradient in its colour, and a glow | state | the client |
| Knob | a knurled edge, a tick ring, a glowing pointer | the knob gadget | the client |

**A material is baked once, then copied.** Noise is a hash of the pixel's
position, so a tile of it is the same every time it is made. A panel's
noise is a 64 by 64 tile made once per scheme and repeated. A brushed bar is
a column pattern times a row gradient, so a bar is made once per height and
copied along its width. A knob is made once per size and turned by drawing
only its pointer. So a frame of the toolkit is copies and fills, and the
recipes run when the scheme or a size changes.

**`sys/libraster` is small on purpose.** Its operations:

    fill        a rectangle, one colour
    vgrad       a rectangle, a colour per row between two colours
    radial      a disc, a colour by distance from a point
    noise       a tile of hashed noise, in a colour and a strength
    hairline    a column or row pattern at a spacing
    bevel       the lit and shadowed edges of a rectangle, at a width
    inset       an inner shadow: a darkened edge ramp inside a rectangle
    blur        a box blur of a rectangle, three passes for a Gaussian
    coverage    an 8-bit mask in a colour, blended: glyphs, icons, glows
    path        a filled outline, antialiased, for section 6's icons

The blend is 8-bit alpha over an opaque buffer, which is all a client ever
needs. It paints into its own store, which is opaque, so the result is
opaque too. `sys/libdraw`'s pieces and `sys/libpal` stay as they are. The
kernel's splash keeps its own `brushed` and `gradient_v`, and gains the
neon colours from `libpal`.

## 5. Type: four faces, baked to coverage

**Four faces, one job each.** The study's rule is that a face says what the
text is:

| Role | Face | Used for |
|---|---|---|
| `chrome` | Chakra Petch 600, upper case, wide tracking | title bars, menu titles, group legends, buttons |
| `interface` | IBM Plex Sans Condensed | menu items, labels, lists |
| `readout` | VT323 | LCDs and dock tiles, and nowhere else |
| `namespace` | IBM Plex Mono | paths, file contents, key equivalents, status lines |

All four are under the SIL Open Font License, so the tree may ship them.
The license text goes in `/lib/font/OFL.txt` beside them.

**The faces are baked on the host, not rasterized on the target.** A
TrueType rasterizer in ring 3 is a large piece of code that the target does
not need. The faces come at a few sizes, and a size is a set of pixels that
never change. So `tools/genface.py` opens each OFL file in `tools/fonts`
and writes a `.face` file per size. Each glyph is an 8-bit coverage mask
with its own advance and its place from the pen. The file is checked in the
way `latin1.subf` is.

The target reads a coverage mask and blends it
with `libraster.coverage`, which is the whole text path.

    /lib/font/chrome/11.face        Chakra Petch 600, 11 px
    /lib/font/interface/13.face     IBM Plex Sans Condensed, 13 px
    /lib/font/readout/20.face       VT323, 20 px, and 32.face for the dock's clock
    /lib/font/namespace/12.face     IBM Plex Mono, 12 px

Each carries ASCII, Latin-1, the dashes and quotes, and the arrows, the
ranges `/lib/font/default.font` gives the 8x16 face.

**A face is a file of its own, not a deeper subfont.** The plan was a depth
word in the subfont format. A subfont is a fixed cell, and a proportional
face is not one. Bending the format would teach the console's loader a shape
it never draws. `sys/libfont`'s `face.odin` reads a `.face`
over a buffer the caller holds: the header, the rune ranges, a record per
glyph, and the masks. `apps/terminal` and the kernel console keep the 8 by
16 face, which is a fifth face and stays the fixed one.

The generator lifts each glyph's coverage by a small factor, held to 255.
That is the stem darkening a renderer does for small light text on a dark
ground. It gives most glyphs a pixel of full ink.

**Tracking and upper case are the toolkit's.** The `chrome` face is set in
capitals with wide letter spacing, 0.14 em for a menu title. That is layout,
not glyphs, so `sys/libmui`'s text measure takes a tracking in pixels and a
case from the role. The theme names a face per role:

    font.chrome      /lib/font/chrome/11.face     track 1 caps
    font.interface   /lib/font/interface/13.face
    font.readout     /lib/font/readout/20.face
    font.namespace   /lib/font/namespace/12.face

A role the theme names nothing for draws in the 8x16 cells, so a theme with
no font lines is the look before this section. `libmui.face_of` loads a
file the first time a role asks for it and keeps it for the program's
life. `text_width` and `face_text` apply the same capitals and tracking, so
what is measured is what is drawn.

**Which gadgets wear the faces now.** A `Text` label wears `interface` and
a `Button` wears `chrome`. A `List`, a `String` field, an icon's name and a
menu's rows stay in the 8x16 cells. Their layout counts cells: `sys/libdoc`
wraps a page to a column count, and `apps/mothra`, `apps/prefs` and
Workbench size their windows in cells. Moving those to the faces is a later
brick. The server's window titles move to `chrome` in brick 5, with the
frame.

## 6. Icons: vector, by kind, with an emblem

**An icon is a small vector file, as Haiku's HVIF is.** The study's icons
are in three-quarter view, with a heavy dark outline, light from the top
left, and a soft shadow. They show at 16, 32, 64 and 128 pixels. A bitmap
per size is four files per icon that drift apart. One outline drawn at each
size is one file. The format is text, so a diff shows what changed:

    # folder: the study's amber drawer
    view 64 64
    shape  fill warn   stroke edge 2   M 6 18 L 26 18 L 30 22 L 58 22 L 58 54 L 6 54 Z
    shape  fill warn.lit               M 6 26 L 58 26 L 58 30 L 6 30 Z
    shadow 3 4 30                      # dx, dy, per cent, cast to the bottom right
    lod    16 32                       # the shapes after this line only from 16 to 32 px
    shape  fill edge                   M 8 20 L 56 20 L 56 22 L 8 22 Z

A fill names a role, so a scheme repaints every icon. `warn.lit` is a role
one step lighter, the lamp's rule `docs/DRAW.md` section 12 already has for
an unlit lamp. `lod` is HVIF's level of detail: a shape that only reads at
one size is drawn at that size and no other. `libraster.path` fills a shape
with nonzero winding and four vertical samples a pixel, which is the
antialiasing the study's edges need at 16 pixels.

**The kind rule stays, and the kinds grow.** `docs/WORKBENCH.md` section 6
says an icon is a kind a `stat` can answer, never a file beside the file.
That holds, with the namespace as a second witness:

| Kind | How it is known | Icon |
|---|---|---|
| folder | a directory | `folder` |
| union | a directory with more than one member in `/proc/N/ns` | `folder`, a union emblem |
| served | a directory that is a mount of a `/srv` name | `folder`, a served emblem |
| remote | a mount through `import` or a network `/srv` | `folder`, a remote emblem |
| home | `$home` | `home` |
| file | anything else | `file` |
| ctl | a file named `ctl` | `ctl` |
| scheme | a file under `/lib/themes` or `$home/lib/themes` | `scheme` |
| channel | a name in `/srv` | `srv` |
| tool | a file under `/bin`, or with its execute bit | the tool's own, or `tool` |
| Recycler | `$home/lib/wb/recycler` | `recycler` |

**An emblem is a small shape in a corner, in the `focus` colour.** The
study marks type with an emblem, not with a plinth, so the kinds share one
outline and differ in a corner. A served or union folder has a cyan emblem,
and the eye learns one colour for "this is not a disk".

**A tool names its own icon.** `/lib/icons/<name>.icon` is the icon for the
tool of that name: `rc`, `acme`, `prefs`, `viewer`. A tool with no file
gets `tool`. `$home/lib/icons` is read first, so a person replaces an icon
by writing a file with its name. That is the `$home/lib/wb/icons` tree
`docs/WORKBENCH.md` section 8 left for a later day, and it keeps the kind
rule.

**The Recycler is new.** The study's icon set has one, so `Delete...`
moves a file to `$home/lib/wb/recycler` in place of removing it. The
Recycler's own menu has `Empty`, which removes what is in it. A `rm` at a
shell is still a remove, and the Recycler is the desktop's alone.

## 7. A: the window frame

**The gadgets stay where Intuition put them.** Close at the top left, zoom
and depth at the top right, and a sizing corner. Each gadget is 20 by 18
with a 12-pixel glyph, and a press sinks it into a well. That is what the
frame does now, in the new colours.

**The title bar is brushed metal, 24 pixels with a 1-pixel edge.** The
metal is the scheme's `metal.hi` to `metal.lo`, with the hairlines over it.
The title is the `chrome` face in capitals, in `dim` on an inactive window.

**The active window says so with light, not with a colour of bar.** Today
the front bar is lit copper and the rest are copper one step down. In the
study every bar is the same metal, and the active window has three extras:

- a 1-pixel `focus` line under its bar
- its title in `text`, with a `focus` glow behind the letters
- a `focus` glow around the whole frame, 26 pixels at full `glow`

The first two are inside the frame, so the server paints them into the
window's store as it paints the bar now. The third is outside every window,
so the compositor draws it, `docs/DRAW.md` section 19. At `glow 0` the
frame keeps the line and the letters, and there is no halo.

**The frame's size moves, and brick 1 cleared the way for it.** A 24-pixel bar with a 1-pixel edge is not today's 20 and 3.
`sys/libmui` places its client area by `FRAME_INSET_X` and `FRAME_INSET_Y`,
constants copied from the server. So the first brick of this plan put
the insets on a window's `wctl` line, for every client to read. A frame's
metrics are the theme's now, and brick 5 changes the numbers.

## 8. B, C, D: one menu, three places

**A menu is one tree, and the program owns it.** `docs/WORKBENCH.md`
section 8 decides that menus are popups the program draws, and the study
does not change that. It changes where a menu appears. `sys/libmui`'s
`Menu` holds one tree of items, and shows that tree in three ways.

**B: docked.** The main menu is a column at the top left of the screen,
NeXT's. Its title is the program's name in the `chrome` face on brushed
metal. Each item is a raised key with its label on the left and its
shortcut on the right in the `namespace` face. A submenu item has an arrow.
There is no menu bar across the screen.

A program's docked menu is a window of the new kind `menu`. The server puts
it at the top left, and shows only the menu of the program in front. A
`menu` window writes `parent N` for the window it serves. When the front
window, or its parent, is that N, the menu shows, and all other menus hide.
The person may drag a menu by its title. The server keeps that place per
`app` for as long as it runs.

**C: at the pointer.** Button 3 anywhere in a window opens a copy of the
main menu under the pointer. It is a `popup`, as `rio` and MUI's `Popmenu`
are today. A submenu opens as a second popup beside its item. The copy is the
same tree, so a program writes its menu once.

**D: torn off.** Every menu and submenu has a tear-off gadget in its title.
A press opens the same items in a window of the new kind `panel`. A panel
has a small frame with a close gadget and no zoom or depth. It sits above
normal windows and under popups. A panel stays until it is closed, OPEN LOOK's pushpin.

A torn-off `Tools` menu is a palette of launchers a person keeps on screen.

**Workbench's menus are its main menu.** When the backdrop or a drawer
is in front, the docked menu is Workbench's. Its items are today's four
menus as submenus: `Workbench`, `Window`, `Icons`, `Tools`. The screen bar
carries no menus any more, section 12.

**The keyboard reaches all three.** `alt-m`, the `menu` chord, opens the
front program's menu under the pointer. A shortcut shown on an item is a
chord the program's window hears, as MUI's hotkeys are today.

## 9. E: preferences, as MUI drew them

`apps/prefs` exists, and it is a list of every role with its value. The
study's layout replaces the list. It keeps the rule that the rows come from
the parser's roles, so a new role is a new row with no code.

- **A page list on the left.** Scheme, Effects, Type, Frame, Keys,
  Workspaces, Display, Servers. A page is a group of roles, and the
  grouping is a table in `apps/prefs`. A role in no group goes on `Other`,
  so none is lost.
- **Framed groups with their title set into the border.** The title is the
  `chrome` face in `dim`, centred, as a `fieldset`'s legend is.
- **The right gadget for the role's type.** A colour is a swatch and a
  `Cycle` of the scheme's names. A number with a range is a `Knob` or a
  `Slider`. An on-or-off effect is a `Checkmark`. A font is a `Cycle` of
  the files under `/lib/font`.
- **Save, Use, Cancel across the bottom**, MUI's three. `Save` writes the
  changed roles to `$home/lib/theme` and sends `reload`. `Use` applies them
  for this session only. `Cancel` returns to what was in use when the
  window opened.

**`Use` needs a place to keep a theme that is not a file.** The draw server
serves a new root file, `overlay`. Its lines merge after `$home/lib/theme`
in every reader, and a write replaces them and bumps the theme generation.
It is memory in `intuition`, so a restart forgets it, which is what `Use`
means. `Save` writes the file and empties the overlay. `Cancel` empties it.

**The toolkit grows the classes the page draws:**

    Knob        a disc turned by a vertical drag, a value in a range
    Readout     an LCD: digits in the readout face over their ghosts
    Led         a lamp in a state colour: ok, warn, fault, or off
    Cycle       the arrow segment on its left, as the study draws it
    PageList    a list whose selection shows one child group of a set
    Group       a title set into the frame line, in place of above it

## 10. F: readouts, and LEDs for `/srv`

**A readout is an LCD, and it shows its unlit segments.** The ground is
`lcd.bg` with an inner shadow and a sheen across its top third. Under each
lit character, the same place shows the full segment set, `8`, in `lcd.fg`
at `lcd.ghost`, 13 per cent in `neon`. That is what a real backlit panel
looks like when it is on. With `bloom`, a blur of the lit characters is
blended back over them at low strength. `Readout` is the class, and the
dock's clock and the Display page use it.

**An LED is a state, in the colour the state has.** `ok` is running, `warn`
is degraded or starting again, `fault` is failed, and an unlit LED is
stopped. An unlit LED is dark in its own colour and never grey, which is
`docs/DRAW.md` section 12's rule for a lamp.

**The LEDs report the servers posted in `/srv`, and a file says how each
one is.** A name in `/srv` says a server is posted. It does not say the
server answers. So a server may serve a `status` file at its root, one word
long: `ok`, `degraded`, `starting`, or `failed`. A reader with a timeout
decides:

| What the reader finds | LED |
|---|---|
| the name, and `status` says `ok`, or there is no `status` file | green |
| `status` says `degraded` or `starting` | amber |
| `status` says `failed`, or the mount does not answer in two seconds | red |
| no name in `/srv` | off |

The reader is `cmd/srvstat`, which prints one line per name, so a shell and
a script see what the Servers page sees. The two-second timeout is on its
own io proc, so a wedged server costs a red LED and never a wedged page.
Which servers need a `status` file is each server's own plan. None needs
one to show green.

## 11. G: the column viewer

**A second way to look at a drawer, not a second file manager.** The study's
File Viewer is Miller columns: each directory a column, the selection in
one column opening the next to its right. It is NeXT's browser, and it
suits a namespace, because a path is the thing a person reads.

`Workbench`'s drawer window gains a view: icons, as now, or columns. The
person picks from the `Window` menu, and `Snapshot` keeps the choice per
drawer. The column view has:

- **A shelf across the top.** A person drops any icon there to keep it, and
  a click opens it. The shelf is `$home/lib/wb/shelf`, one path per line.
- **An icon path.** The current directory as a row of icons, one per path
  element, each a place to click back to.
- **The columns**, with a scroller across the bottom when there are more
  than fit. A column's rows are the icon at 16 pixels and the name in the
  `interface` face.
- **A union shows as a union.** A column for a union directory lists its
  members' entries in bind order, and a tag at its foot names the members,
  in the `namespace` face in `focus`. Section 6's `union` kind says which
  directories are unions.
- **The status line names the server behind the folder**, from
  `/proc/N/ns`: `kfs`, `/srv/fatfs`, `#c`, or `import one`. A person sees
  which machine and which server a file is on before opening it.

The mount table is the witness for both of the last two. `/proc/N/ns`
lists it in the namespace file's grammar, and `sys/libuser` already reads
that grammar with `ns_word` and `ns_target`. The view asks it which entries
cover a path, and it does not guess.

## 12. H and I: the dock, and the top bar

**H: the dock is a column of tiles on the right edge.** Each tile is 64 by
64, raised, with a 44-pixel icon and an LED in its corner. The LED is lit
when a window of that program is up, from the `app` word in the server's
`ctl` report. A click on a tile brings that program's front window forward,
or runs it when none is up. The tiles come from `/lib/wb/dock` and then
`$home/lib/wb/dock`, one per line:

    # dock: a tile, and what it runs
    tile  rc      window rc -i
    tile  acme    window acme
    tile  viewer  viewer
    clock                              # the time, in the readout face
    load                               # the processor, as a bar of LEDs

Two tiles are not programs. `clock` is a `Readout` of `/dev/time`. `load`
is a column of LEDs from `/dev/sysstat`, lit bottom up. Today's amber lamps
down the right edge, one per window slot, go, and the dock is where state
on the right edge lives now.

**I: the top bar is status, and nothing else.** Today's screen bar has
Workbench's name, the memory, the workspace lamps, and the menus on button 3.
The menus move to the docked main menu. The rest stays, in the study's
layout:

- the workspace, as the nine lamps and the current number in the readout
  face
- the display: the output and its mode from `/dev/fbctl`, then the scale
- the status line: the last notice, in the `namespace` face, with the
  notice history on a click as today

**Scale is 1, and it has somewhere to go.** The study shows a 1.5 times
scale and a colour profile. Neither exists here. The icons are vector and
the faces are baked per size, which are the two things a scale needs. So
the day a display needs a scale, the theme names one and the toolkit lays
out in logical pixels. Until then the bar shows the mode and no scale.

**The bar and the dock are one kind of window, on two edges.** `bar` takes
an edge, `bar top` or `bar right`, and the server keeps the strip clear.
`zoom`, the `snap` words and the overview lay out in the screen less both
strips.

**The chords stay on Alt.** The study binds Super with the digits,
Super-Tab, and Super-O. `kbdfs` does not report a Super key yet, so the
keys file ships Alt, as now. The day `kbdfs` reports one, a person writes
`super-1` in the keys file and nothing else changes.

## 13. Decisions, and what would reverse them

- **Inside a window is the client's, outside is the compositor's.** This is
  why the protocol keeps six verbs. The reversal is a client that must draw
  outside its rectangle, and there is not one. A shadow or a glow is
  chrome.
- **The toolkit paints its store, and the per-face atlas goes.** The atlas
  of 2026-09-04 bakes glyphs per ink and background, and a gradient has no
  one background. The cost is the remote case, which sends `load` bands.
  The reversal is a masked blit, which is the seventh verb, and the store
  makes it unneeded.
- **Faces are baked on the host.** A rasterizer on the target would let a
  person add a TrueType file at run time. That is a real want, and it is
  a later one. The reversal is `libraster` growing a quadratic outline
  filler, which `path` is most of.
- **The icon is a text file of shapes.** HVIF is binary and small. Text is
  larger and a diff can read it. The reversal is a size budget the icons
  break, which a few hundred bytes each will not.
- **Roles name jobs, schemes name hues.** A role named `cyan` in a scheme
  where focus is teal would be a lie in the file. The study's own token
  names are the scheme's names, so its files read the same here.
- **neon is the default, and magnesium is one line away.** The kernel's
  splash moves to neon too, so boot and desktop stay one machine. The
  reversal is `use magnesium` in `/lib/theme`, one line.
- **No global menu bar.** A bar across the screen names one program's
  menus in a place far from its window. NeXT's docked menu is as near to
  the pointer as the popup is, and it is the same tree.
- **A server's health is the server's word.** A reader cannot tell a slow
  server from a failed one without a timeout, and cannot tell a degraded
  one at all. So the server says, and a server that says nothing is green
  while it answers.

## 14. The order

Each brick ends with a check in `kernel/user/verify.odin`, on three
architectures, and a screendump in `docs/` where the brick changes the
look.

1. **Insets on `wctl`. Done, September 2026.** The window's `wctl` line
   ends with the frame's four insets, and the theme names the frame's
   three numbers, `frame.edge`, `frame.title` and `frame.well`. The toolkit
   reads the insets with `window_locate`, and the copied constants are
   gone. `sys/libapp` already read its origin off the `store` file, and
   `cmd/window` never needed one. A reload that changes the frame keeps
   each client area's size and pixels, and the window grows round it. The
   check: a theme with `frame.title 30` moves the demo's face ten rows
   down under a taller bar, with its client area the same size. This is
   also step 5's "frames by name".
2. **Schemes. Done, September 2026.** `colour` lines, read into a
   `libpal.Colours` table by both readers. The job roles, as other names
   for the toolkit's roles, and `focus`, `warn`, `ok` and `fault` new. The
   four scheme files, and `tools/contrast.py` in `lint`. The study's
   violet fails 4.5 as link text on `raised`, so neon's `link` is a lighter
   violet, `b28aff`.

   The checks: `use neon` makes the demo's face neon's
   `raised` and the front bar neon's `metal.hi`. `use daylight` makes them
   daylight's. A personal `colour` line names a colour a role takes.
3. **`sys/libraster`, and the toolkit on its store. Done, September
   2026.** The operations of section 4 are `sys/libraster`, and
   `tests/raster` checks each against pixels worked out by hand. The
   toolkit paints its window's store and writes `store` to show it. A
   label is its glyph's bits laid in the ink, so the per-face atlas and
   its images are gone.

   The toolkit reads the store's line before each
   paint, which also gives it a size the server set, a thing it never
   heard before. A remote window paints a copy and sends the rows that
   changed. `tests/mui` reads its checks off a canvas now. The faces stay
   flat until brick 5 gives them their materials.

   The brick found five things, each fixed where it lives:

   - **A toolkit window holds five descriptors**, and the store is the
     fifth. Workbench with a drawer open passed thirty-two, so `MAX_FDS`
     is sixty-four.
   - **A shared run walled in the heap.** `map_reserve` gave a store the
     first hole above the mapping base, just past a heap still at its
     first 64 KiB, and `segbrk` could not grow the heap. Workbench could
     not make one more io proc and ended. Shared runs map from
     `SHARED_BASE`, four gigabytes, now.
   - **A theme reload painted over the client.** The server's re-chrome
     laid the well's face over a client area the client had already
     repainted in its own process. `window_chrome` keeps the client area
     for a reload and a reframe.
   - **A proc made as its program ended stood on.** `threadexitsall`
     notes each proc by its pid, and passed one whose pid was not yet
     known. `proccreate` forks under `procs_lock` and refuses once the
     program is ending. The kernel's `notepg` passed a child still being
     forked the same way, and a note now waits in its record,
     `note_born`.
   - **A reload before the watcher's first read was lost.** The theme
     watcher took its first answer as the baseline. A reload between the
     window's first theme read and that answer moved the number past a
     look nobody loaded. Faster painting opened the gap. The first answer
     loads the files too.
4. **The faces. Done, September 2026.** `tools/genface.py` bakes the four
   OFL fonts into `.face` files, `sys/libfont` reads them, and the theme
   names one per role with its tracking and case. Labels and buttons wear
   them. In `tests/mui` a face is proportional, and capitals and tracking
   measure as they draw. A label's edge has pixels between its ink and its
   ground. On the glass, the demo's button label has a
   pixel between the amber and the magnesium, which the one-bit cells
   never drew. A control with no faces fails exactly those.
5. **The frame, A. Done, September 2026, but for the gadgets.** The theme
   line `frame.style metal` makes every bar brushed metal, `bar` to
   `bar.shade` with two hairline patterns. The front window's bar has a
   `focus` line along its foot. Its title is in the chrome face, `text` over
   a faint `focus` glow, and every other title is `dim`.
   `servers/intuition/effects.odin` paints them into each window's store
   with `sys/libraster`.

   The halo and the shadow of `docs/DRAW.md` section
   19 are the theme's `glow` and `shadow`. The three schemes of section 3
   turn all of it on with the study's metrics: a 24-pixel bar and a 1-pixel
   edge. `docs/chrome-neon-frame.png` is the demo under `use neon`.

   The checks are in `verify_muiwin`. With `glow 60`, a pixel beside the
   front window's frame turns toward the focus colour. With `frame.style
   metal`, the bar's foot is the focus line and its rows differ. With the
   file gone, the pixel is the desktop's again. A control that paints no
   effects fails the first.

   What is left: the gadgets are still the chassis's amber on magnesium.
   The chassis stays the default, `/lib/theme`, because the suite's glass
   checks read the chassis's colours by name. Moving the default to `neon`
   means those checks read the theme's roles first, which is a brick of its
   own.
6. **Menus, B to D.** The `menu` and `panel` kinds, the docked menu, and
   tear-off. Workbench moves its menus into its main menu. The check: the
   docked menu shows for the front program and hides for another, and a
   torn-off `Tools` panel stays after the popup closes. Medium.
7. **Icons, J.** The icon format, `libraster.path`, the kinds with the
   namespace as witness, the emblem, and the Recycler. The check: a union
   directory's icon has the emblem's colour in its corner, and a plain
   directory's does not. Medium.
8. **Readouts and LEDs, F**, with the `status` convention and
   `cmd/srvstat`. The check: `srvstat` names a posted server green and a
   removed one off. Small.
9. **The dock and the top bar, H and I.** `bar` with an edge, the dock
   file, and the tiles. The check: a tile's LED lights when its program's
   window opens and goes dark when it closes. Medium.
10. **Preferences, E**, with the pages, the new classes, and `overlay`. The
    check: `Use` of a changed face repaints a second program, and `Cancel`
    puts it back with no file written. Medium.
11. **The column viewer, G.** The check: a column for a union lists the
    members' entries in bind order and its tag names them. Medium.

Bricks 1 to 3 come first and in that order, because every other brick
paints through them. After brick 3, the order of the rest is the order a
reason arrives.

## See also

- `docs/WORKBENCH.md` -- the desktop this repaints, and its step 6 that
  points here.
- `docs/DRAW.md` section 19 -- what the compositor draws outside a
  window.
- `docs/DEVTOOLS.md` step 1 -- the window store the toolkit moves onto.
- `~/Development/c/pneo/docs/design/chrome-study.html` -- the study, with
  every token, material and icon drawn.
