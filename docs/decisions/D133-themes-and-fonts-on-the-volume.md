# D133. Themes, layers and fonts are files on the volume: `/data/lib/theme` and `/data/lib/fonts` in a union before bootfs's, the user's and each workspace's layer a file in `/data/lib/layer`, and Radharc following them through a watch; the legibility floor gates the themes we ship, not the user's (2026-10-25, proposed; the floor the owner's choice; for the owner's review; extends D91, D108, D109, D119; amends D91's and D108's floor)

D91 says installing a theme is copying a file (principle 24), and D108
says the user's changes are a layer, a file in the theme format, that
`ctl set` writes to. Neither is true yet:
- Radharc mounts `/lib/theme` and `/lib/fonts` from bootfs alone
  (`radharc.manifest`), and so does every Kit program for its fonts.
  A theme or a face that isn't in the image can't be used, and adding
  one means building the image again.
- The user's layer is only the knobs that Settings' `Appearance` area
  holds (D119). `ctl set` sets a role until the next `load` and keeps
  nothing. A workspace can name a theme, but it can't have a layer.

So the only way to change the look for good is to edit a shipped
theme in the tree. That's the copy D108 meant to avoid, and it doesn't
reach a device that is already installed. This entry puts the files
D91 and D108 promise on the volume. It adds no new mechanism: the
files are theme files read by the one parser and judged by `theme
check`, the directories are manifest unions, and Radharc learns of
changes through the Node watch that Settings already uses.

## Decided

- **Themes and fonts installed by the user live on the volume, in a
  union before bootfs's.** Radharc's manifest gains:

  ```text
  mount /lib/theme fs/volume/lib/theme before create optional
  mount /lib/fonts fs/volume/lib/fonts before create optional
  ```

  Each manifest that mounts `/lib/fonts` from bootfs gains the second
  line. Without a volume both are left out, and everything is as it
  is today.
  - Installing a theme is copying it to `/data/lib/theme/NAME`, and
    removing it is removing that file. Nothing else records it.
  - Installing a face is copying an OpenType file to
    `/data/lib/fonts`. A theme names it by family, as it names a
    shipped face (uicore(2)).
  - A file on the volume with a shipped file's name is the one seen,
    as in Plan 9's `bind -b`. That is how someone tries a fix to a
    shipped theme on a device without building an image. Theme pages
    and the Appearance panel steer people to layers and `inherits=`
    instead, because a copy stops taking its author's fixes.
  - If the theme in force fails to resolve after a change, the theme
    before it stays, as `load` already does. At start, a Platinum
    Indigo that doesn't resolve falls back to the base, which is built
    in and can't be overridden.
- **The user's layer is a file: `/data/lib/layer/user`.** A workspace's
  layer is `/data/lib/layer/workspace.N`. Both are in the theme format
  and have no `theme=` record (theme(6)). Radharc mounts
  `/lib/layer fs/volume/lib/layer create optional`; there is nothing in
  bootfs to merge, so it is not a union.
  - The stack is D108's: base, chain, variant, the user's layer, then
    the shown workspace's layer. An output's layer and app rules stay
    out, as D119 has it.
  - The knobs that Settings holds (D119) are a layer just above the
    user's file. A knob the Appearance panel has set wins; one it has
    never set (no `Appearance:Accent` attribute) leaves the file's
    value standing. The panel then always shows what is in force.
  - **`ctl set ROLE COLOUR` writes the user's layer file,** as D108
    decided, replacing that role's line if there is one. `set ROLE
    default` removes the line. A new `ws N` before a command (`ws 2 set
    selection 0x6f4ab8`) aims it at a workspace's layer instead. The
    layer now outlives `load`. A layer that fails over the new theme is
    refused with its file and line, and the stack beneath it stands
    (D108). Editing the file by hand does the same thing.
- **Radharc follows the three directories through a Node watch**
  (node(5)), one each, as Settings follows `/data/Settings`.
  - When a layer, or the file of the theme in force or of a theme in
    its chain, is made, written or removed, the stack is resolved
    again, checked and served. That is a theme change: the generation
    rises, `events` hears it, and `theme.switch` judges it.
  - When `/lib/fonts` changes, the generation rises too, so every
    Kit program chooses its faces again on its next `.themeChanged`.
    No second notice is needed.
  - A change to a theme that isn't in force only updates `themes/`.
  - Writes that come close together are resolved once: Radharc
    resolves at most once a frame, at the latch, so saving a file
    from an editor that writes it in pieces never shows a half-written
    one. A file that fails to parse is refused with its line, as above.
- **Faces are mapped, not read whole.** A volume of faces can't be
  read whole into Radharc and every Kit program at start, as they are
  today (radharc(4)'s BUGS). Each face is opened when a theme's
  typeface or a fallback first needs it, and read through its mapped
  file (D131's page cache), so a face nobody draws costs only its
  directory entry. This lands in the same change, before the union,
  so the shared-RSS budget is judged on a volume with faces on it.
- **A face from the volume is untrusted input.** It is the first time
  the OpenType parser (text(2)) reads a file the image didn't ship. A
  face that fails to parse, or whose tables point outside the file, is
  skipped and logged, and the family's other faces still answer.
  OpenTypeTests gain malformed faces (truncated tables, offsets past
  the end, loops in composite glyphs) that the parser must refuse
  without a fault.
- **The legibility floor gates the themes we ship, not the user's.**
  The owner's choice (2026-10-25): users own their machines, and may
  have whatever colours they like. This amends D91 and D108, which
  refused any theme or layer under the floor (theming.md §6).
  - `vx theme check` in `vx ci` still fails a shipped theme under the
    floor, in every variant and at every knob's extremes. Every
    suggestion a shipped knob offers still passes, so the Appearance
    panel only offers legible choices.
  - On the device, nothing is refused for the floor. Radharc still
    runs the check on every change, logs each finding, and lists them
    in `theme/active` as `finding <text>` lines, so an editor or the
    Appearance panel can show them. A file that doesn't parse or
    resolve is still refused, since there is nothing to draw.
  - **High contrast is the way back.** It stays one switch over every
    layer, and it is always legible: if the chain's `high-contrast`
    variant, with the layers over it, fails the floor, the base's
    high-contrast variant is drawn instead. So someone who has made
    their screen unreadable can always read it again with one switch.
  - The trusted prompt is unchanged: Radharc draws it in colours of its
    own, and no theme reaches it.
- **A user's faces and themes need no recorded licence.** D24's rule,
  that every face carries its licence and provenance, holds for what
  the tree ships. What a user copies to their own volume is their
  business. `theme check` doesn't judge licences. This answers
  theming.md §12's fourth question.

## Tests

- ThemesTests: a stack with the user's file and a workspace's, the
  Settings knob layer over a file's knob, and a file's knob standing
  when no knob attribute is set.
- RadharcTests: `set` and `set ROLE default` written into the layer
  file and kept across `load`; `ws N` aimed at a workspace's layer.
- OpenTypeTests: the malformed faces above.
- `boot-theme-files`, on a disk:
  - It copies a theme that inherits from Platinum Indigo to
    `/data/lib/theme` and loads it.
  - It writes a user's layer and a workspace's, and reads `active` and
    `status` for each change, with `theme.switch` reported.
  - It writes a layer that fails the floor and checks that it is
    drawn, with its findings in `active`; then turns high contrast on
    and checks that the base's high-contrast variant is drawn.
  - It writes a layer that doesn't parse and checks that it is refused
    with its line, and the stack stays.
  - It copies a face to `/data/lib/fonts` and checks that a layer
    naming it draws in it.
  - It reboots and checks that the theme and both layers are still in
    force.

  Its row in `docs/risk.tsv` sits beside `ui/theme/`'s and
  `services/radharc/`'s, and both of those rows gain it.

## Budgets

None new. A file change is a theme change, and `theme.switch` judges
it. The shared-RSS budget is judged with faces on the volume that no
theme names, which checks that unused faces cost nothing.

## Pages

theme(6) (FILES, layers, the union, the check refusing only what
doesn't resolve on the device), radharc(4) (the manifest, `ctl`'s
`set`, `ws`, the watches, the BUGS line about faces read whole), kit(2)
and uicore(2) (faces mapped when first needed), and text(2) (untrusted
faces).

## Not chosen

- **Themes and layers as Taisce attributes on Settings.** A theme is
  a file a person reads and edits on the device (D91), and a layer is
  the same format (D108). Attributes would be a second way to keep
  the same thing, and couldn't be copied as a file.
- **A theme installer, or a registry of installed themes.** Copying
  the file is installing it (principle 24). A list beside the
  directory would be a second record of the same fact.
- **The volume's directory after bootfs's in the union.** A user's
  theme with a shipped name would then be hidden without a word.
- **Converting faces on the host into a format of our own.** The text
  stack already reads OpenType. A conversion step would mean that
  installing a face isn't copying a file.
- **Reading the volume's faces whole, as bootfs's are today.** Every
  Kit program would pay for every face installed.
- **Keeping the floor for the user's themes, or an override for it.**
  The machine is the user's. An override switch would be a second
  answer to a question that high contrast already answers.

## Not yet

- Edit and Save as theme (theming.md §10, §13.4; D119 left them out).
  Save as theme becomes flattening the stack into a file in
  `/data/lib/theme`.
- An output's layer and app rules (D119).
- Themes arriving over 9gate: they are copied into `/data/lib/theme`
  and checked when they load, as D108 says, but nothing fetches them
  yet.
