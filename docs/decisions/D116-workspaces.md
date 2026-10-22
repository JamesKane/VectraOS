# D116. Workspaces: `space` is plain free placement, `tile` asks a layout process that holds no state, chords are a `shortcuts` holder writing `windows` verbs (2026-10-22, decided; built 2026-10-22; extends D9, D92, D107, D111, D113)

V5's step 4 part 5 builds D9's workspaces. This note settles what D9
left proposed, answers the roadmap's open question 5 against a
reference workflow, and defines the layout plug-in interface (D92) and
the `shortcuts` and `windows` services the roadmap names. todhchai's
Radharc has edge snapping and zoom only. Its `shortcuts` service and its
recorded approvals (M6k k6b, k6c) are lifted. Everything else here is
new. The owner chose (2026-10-22): plain placement for `space`, app
frames kept by Radharc, Super as the chords' modifier, and `shortcuts`
asking the user and recording the answer in this part.

## The reference workflow

Bring-up on one 1080p output, as this project works today:

- Workspace 1 is tiled: three rc terminals (a build, a QEMU console, a
  shell) and the Inspector.
- Workspace 2 is spatial: Tracker's home and two folders, a document,
  and Settings' preference apps.
- Workspaces 3 and 4 are spare. One is used for a game or a capture
  (V9) at full screen.
- The user flips workspace 1 to `space` to drag one terminal wide for a
  log, and back. Every window returns to its tile, and the spatial
  frames are there the next time.

Every window in this fits on its workspace's screen. Nothing in it is
easier on a canvas larger than the screen.

## Decided

- **`space` is plain free placement with spatial memory** (open
  question 5). There is no pannable, zoomable canvas. Workspaces
  already answer "more windows than fit", and todhchai's focus area is
  the answer for wide outputs if it earns its place later (principle
  1). So D9's first detail becomes **plain stacking is `space`**,
  without "at 1:1", since there is no zoom level.
- **Workspaces are Radharc's.** Each output has a number of them, 4 by
  default (Be's default), and one output exists until the GPU (step 6).
  - Each workspace has a mode, `tile` or `space`, and, in `tile`, a
    layout's name and its parameters.
  - A window is on one workspace. Panels (Deskbar), the desktop window
    (Tracker's) and popups follow their owner or show on every
    workspace.
  - Switching workspaces hides one set of windows and shows another.
    Focus returns to the window last focused there.
  - A window sent to another workspace takes that workspace's mode.
- **Both arrangements are kept.** Every window has a spatial frame. A
  `tile` workspace also places it where its layout says.
  - Switching a workspace to `tile` keeps each window's spatial frame
    and asks the layout. Switching back restores the spatial frames.
    Nothing is recomputed from the tiles.
  - Inside `tile`, a drag doesn't move a window and the zoom box makes
    it the master. Fullscreen windows, views and popups are not tiled.
- **What persists, as Taisce attributes on Settings areas (D113):**
  - `Workspaces`: `Workspaces:Count`, and for each workspace N
    `Workspaces:N:Mode`, `Workspaces:N:Layout` and `Workspaces:N:Params`.
  - `Frames`: one string attribute an app, `Frames:APP` = `WORKSPACE X Y W H`,
    the spatial frame of the app's last window closed. Radharc places
    the app's next window there. An app whose windows are documents
    keeps their frames on the documents, as Tracker already does
    (`Tracker:Frame`, after Be's `_trk/windframe`), and asks for that
    place with `move`.
  - Radharc's manifest gains `mount /data fs/volume optional`.
  - Settings gains `store(area, name, value)`, for areas whose
    attributes aren't declared settings.
- **A layout is a process that holds no state** (D92's first plug-in
  point). Its interface is `Layout` in RadharcIPC version 9
  (`todhchai.radharc.Layout`, radharc-layout(5)):
  - `arrange(area, windows, focused, params) -> [Area]`. The windows
    come in the workspace's order, and it returns a frame for each.
  - `act(verb, windows, focused, params) -> (order, focused, params)`.
    A verb is the layout's own word, such as `focus next`, `swap`,
    `grow` or `masters +1`. Radharc then calls `arrange`.
  - `name() -> String`.

  Radharc keeps each workspace's order and parameters, and persists the
  parameters. So:
  - Replacing a layout loses nothing: the new process registers the
    same name and is called next (`plugin.replace`: no frames dropped).
  - Radharc calls layouts on one worker thread, never under its lock,
    which also writes Settings. A layout that crashes, or answers after
    50 ms, is dropped and leaves the frames as they are. Radharc's status
    stops listing it (`layouts ... refused N failed N`), and Radharc
    arranges again when one registers.
  - A layout sees window ids and sizes, never titles or pixels.
- **Registering a layout** follows the chooser's pattern. A manifest
  with `grant windows layout` gets a `layout` service in its tree, and
  `LayoutProvider.register(Handle)` hands Radharc the layout's channel.
  The grant comes from the manifest alone, with no prompt, as
  `chooser`'s does: a layout sees less than `windows` already shows.
- **Master-stack is the first layout** (`shell/layouts/master-stack`,
  dwm's). A new window becomes the master. The parameters are `ratio`
  (55 by default, in percent) and `masters` (1).
- **`shortcuts` is lifted from todhchai** (`Shortcuts`: `register`,
  `unregister`, `pressed`).
  - A chord registered by one holder is matched before focus and
    consumed, with its key-up and repeats. The focused window never sees
    it.
  - It is D111's first gated service. A manifest's `grant windows
    shortcuts` makes the node, and the first open asks the user on
    Radharc's own prompt ("chords wants to take keys before every
    window"). The answer is recorded in `Grants:APP.shortcuts`.
  - Revoking the grant in Settings closes the channel: Radharc follows
    `Grants` through the Settings watch. This is the "revoking closes
    the channels" that D111 promised.
- **Chords are a program, `chords`, holding `shortcuts`.**
  - It reads the chord map from the Settings area `Chords`, one
    attribute a chord: `super-1` = `workspace 1`.
  - On a press it writes the action to `/svc/windows/ctl`, so a script
    does whatever a chord does (todhchai `docs/desktop.md` §2).
  - It follows the Settings watch: when the map really changes, it
    ends, and the launcher starts it on the new map. A watch event that
    names no area touches every area, so it compares the maps first.
  - The modifier is Super (the logo key): Control's chords belong to
    apps (Kit's Control-Q and Control-W) and to programs in terminals.
    The storyboard's ⌘⇧T is Super-Shift-T.
  - With no map, these defaults apply:

    | Chord | Action |
    |---|---|
    | Super-1 to Super-4 | `workspace N` |
    | Super-Shift-1 to Super-Shift-4 | `send N` (the focused window) |
    | Super-Shift-T | `mode toggle` |
    | Super-J, Super-K | `act focus next`, `act focus prev` |
    | Super-Return | `act swap` |
    | Super-H, Super-L | `act shrink`, `act grow` |
- **`windows` gains the verbs.**
  - The Windows protocol, version 9, adds `workspaces()`,
    `workspace(n)`, `send(id:to:)`, `setMode(n, mode)` and `act(verb)`.
    `changed` is also sent when the workspaces change, and a subscriber
    reads them with `workspaces()`.
  - `act` is answered at once: `invalid` only if the shown workspace
    isn't tiled. A verb the layout refuses is counted in `status`.
  - `/svc/windows/ctl` is the same verbs as text for rc and `chords`,
    one handler behind both, as the launcher's `ctl` is.
  - The verbs are open to every client with `use windows`, as `move`
    and `top` already are. The roadmap's "control handle" for a layout
    isn't needed: Radharc calls the layout, and the layout calls nothing.
- **Deskbar shows the workspaces** as the storyboard draws them: a
  button each, with its mode's letter (T or S). A click switches.
- **The budget.** "Workspace mode switch, tile ↔ space, 20 windows,
  within 2 frames of input" (`docs/performance.md`) lands with its
  check, `desktop.mode_switch`. Radharc counts the latches from the
  verb to the first frame composed with the new frames. The boot test
  reports it with 20 windows. Animation waits on motion, which is
  `docs/theming.md`'s open question.

## Tests

- RadharcTests: workspaces, modes, and keeping both arrangements, in
  Scene.
- MasterStackTests: the layout as a pure function.
- ChordMapTests: chord names and the map over the defaults.
- DeskbarAppTests: the workspace buttons.
- `boot-workspaces`:
  - It opens 20 windows, presses chords with QEMU's `sendkey`, and reads
    `list` and `status`.
  - It answers the `shortcuts` prompt.
  - It kills the layout process and checks that the frames stay and are
    arranged again after the restart.
  - It revokes the grant and checks that chords stop.
  - It reports `desktop.mode_switch`.
  - It keeps an app's frame for its next window.

Built 2026-10-22: boot-workspaces passes on amd64 and arm64, with the switch on
screen 1 frame after the verb.

## Not chosen

- **A pannable canvas for `space`.** It would be a second answer to too
  many windows, beside workspaces.
- **A layout driving `windows` itself, as tiling scripts do on X11.** A
  layout would then need a control handle, and two programs could each
  move windows. Here Radharc owns placement and only asks.
- **Chords built into Radharc.** The map would then be Radharc's code,
  not a file the user edits, and a script couldn't bind what a chord
  does.
- **Control as the modifier.** It collides with apps' own chords.

## Not yet

- Tab stacking, stashing and the focus area (architecture §7). Each
  must still earn its place.
- A workspace's own resolution and wallpaper (Be's). A theme for each
  workspace comes with step 5.
- More than one output (step 6).
- Animated switches.
- The other gated services (`capture`, `inject`, `observe`, `secure`).
  They take the same path as `shortcuts` when something needs them.
