# D113. Settings are files with typed Taisce attributes under `/data/Settings`: one file an area, rc's `attr` on them, and D111's recorded grants in `Grants` (2026-10-21, decided; built 2026-10-21; extends D8, D107, D111)

Step 1's Settings shim was listed in V5's scope (D107) and left unbuilt
until the shell needed it. Tracker (`Recent`), Deskbar (`Deskbar:Clock24`,
`Deskbar:Gauges`, `Recent`), D111's recorded grants (`Grants:APP.SERVICE`)
and the Settings app all read and write it, so it lands first in step 4.

## Decided

- **Settings are Be's: one file per area in `/data/Settings`, each
  setting a typed Taisce attribute on its area's file** (principle 18,
  "Preferences are Be's"; principle 1, one mechanism per concern). A
  file or attribute that isn't there, or holds a value outside the
  setting's type or range, means its default.
  - `Appearance`: `Appearance:Theme` (`string`, default
    `platinum-indigo`, choices `platinum-indigo` and `neon-tab`). In
    todhchai, `Accessible` was a second theme choice; here high contrast
    is a variant in the theme stack (D91, D108, D109), and themes are
    named by their files in `/lib/theme`.
  - `Keyboard`: `Keyboard:RepeatDelay` (`int64`, default 500 ms,
    150..2000) and `Keyboard:RepeatRate` (`int64`, default 30/s, 2..60).
  - `Mouse`: `Mouse:Speed` (`int64`, default 5, 1..10).
  - `Deskbar`: `Deskbar:Clock24` (`bool`, default true) and
    `Deskbar:Gauges` (`bool`, default true).
  - `Grants`: `Grants:APP.SERVICE` (`bool`), D111's recorded answers for
    gated services.
  - `Recent`: `Recent:Documents`, `Recent:Folders` and `Recent:Apps`
    (`string`, a line an item, newest first, ten kept), Deskbar's and
    Tracker's recent lists.
- **No second settings format.** NeoVectra planned ndb files in
  `/data/settings`, while Taisce already stores typed attributes on
  files (`Tracker:Frame` on folders) and reports attribute changes on a
  directory's Node watch. Using Taisce attributes for settings too keeps
  one mechanism for structured metadata on the volume.
- **`rc`'s `attr` is the command-line interface.** Because each area is a
  file on `/data` and each setting is a typed attribute (`string` kind
  1, `int64` kind 2, `bool` kind 6), `attr /data/Settings/Keyboard`
  lists an area, `attr /data/Settings/Keyboard Keyboard:RepeatDelay 250`
  sets one, and `attr -d /data/Settings/Grants Grants:tile.shortcuts`
  revokes a grant, with no separate settings command.
- **Following changes is a Node watch on `/data/Settings`.** A service or
  app that follows an area opens `/data/Settings` with `watch(since: 0)`
  (`Settings.watch`). When an area's file is created or removed, or an
  attribute on it is set or removed, fs(4)'s journal wakes the watch with
  the file's name (`Mouse`) or the attribute's (`Mouse:Speed`), which
  `Settings.touches` matches to the area.
- **D111's recorded grants live in `/data/Settings/Grants`.** `Grants`
  reads a recorded answer (`Grants.recorded`), records one
  (`Grants.record`), lists all recorded grants in attribute order
  (`Grants.list`), and revokes one by removing its attribute
  (`Grants.revoke`, or `attr -d`), which wakes any watcher on `Grants` so
  a service holding channels opened under that grant can close them.
- **One tier 0 library, `Settings` (`system/settings`, `settings(2)`).**
  Lifted from todhchai's `system/settings`, with byte comparisons so tier
  0 services link it without Unicode tables, and built for tier 1 as
  well.
