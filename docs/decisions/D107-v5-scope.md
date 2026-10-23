# D107. V5's scope: todhchai's APIs ported first, then Radharc on the boot framebuffer, rio, the shell, the themes, the GPU last; amd64 and arm64 (2026-10-18, decided; extends D9, D24, D75, D76, D91, D92)

V5 is "Desktop". todhchai has all of it, done and measured on croi
(its M4, M5 and M6, closed 2026-10-14, at 527ff94, the commit every
todhchai row in IMPORTS.tsv already points to). Its stack:

- the text stack (OpenType, Shape, Raster, MSDF, GlyphAtlas,
  TextLayout), checked against HarfBuzz and FreeType as host oracles;
- UICore (tier 0: theme, display list, CPU renderer, widgets) and Kit
  (tier 1);
- Radharc (CPU composition, nesting, present credits, view tokens,
  secure surfaces);
- the SDK (Loop, Window) and its examples;
- Terminal, Tracker, Deskbar and Preferences;
- the display and GPU classes, virtio-gpu, Venus, our Vulkan loader
  and Loinnir.

Here there is none of it. Only TDUnicode, fontgen and Spleen, the
framebuffer console, a keys-only virtio-input, the plumber, rc and
FsIPC with its queries came across.

Most of it can't be lifted as it stands, because it is written against
todhchai's system, and V1 to V4 replaced much of that system:

| todhchai uses | Here | So |
|---|---|---|
| display timelines (`Timeline`) | cut (D27): a counter for a driven vblank, a deadline thread for a synthetic one | Radharc's latch thread and the SDK's frame estimate move to them |
| event pairs (view tokens) | cut (D23) | a view token is a channel end: its peer's close is the signal |
| `VMO.read`/`write` (about 23 call sites) | cut (D37) | mappings |
| RouterIPC | the plumber (D85) | the SDK's `Route` and Kit's Route item send to `/mnt/plumb` |
| PtyIPC, sockets | gone (D77) | rio serves `/dev/cons` (below) |
| InputIPC, InputDeviceIPC | kbdfs's `/dev/kbd` and `/dev/cons` (D83) | Radharc reads `/dev/kbd` and `/dev/mouse` |
| KeyringIPC (approvals) | factotum (D75) | Radharc's approver asks factotum |
| `system/settings` | nothing | ported onto Taisce attributes, which V4 put on disk |
| Synchronization `Mutex` | tier 1 has it; tier 0 user code has it (only the kernel's targets lack it) | unchanged |

This decision settles V5's order and the choices the roadmap left open.

## The order

Each step closes with its tests and its pages (D86). The donor design
for each placeholder in the roadmap is written as its own decision just
before the step that needs it, not all at the start.

- **First, the APIs (port, not lift).**
  - **The text stack, lifted whole.** It imports nothing from the
    system. Fonts come with it as data (choices, below).
  - **UICore, ported:** `Tokens` and `Theme` become D91's roles,
    materials and parts, with the system's base theme, the theme
    file's parser and `theme check`. Do this before any app is ported
    onto UICore's styles, because every consumer of the hue-named
    tokens has to change once (Images, Chrome, the terminal's palette,
    Kit's background, the tests). AccessTree is lifted as is.
  - **The system shims.** The frame clock on a counter and the port's
    deadline (D27), view tokens on channels, mappings in place of VMO
    reads, Settings on Taisce attributes ("Preferences are Be's", its
    design written here), the plumber in place of the router, and
    factotum in place of the keyring.
  - **The mouse service (D83):** `/dev/mouse` and `/dev/mousectl` after
    9front's mouse(3), fed by virtio-input's pointer events, with
    todhchai's Normalizer as the donor for the pointer's handling.
- **Then Radharc on the boot framebuffer.** The console hands its
  framebuffer over (its `handoff`, deferred to V5 in
  `services/console`). That framebuffer is GOP on amd64 and edk2's GOP
  over ramfb on arm64: no ramfb driver is needed, since edk2 is
  already the one, as the console's `framebuffer-pixels` test shows on
  both. Then:
  - CPU composition, with input from `/dev/kbd` and `/dev/mouse`;
  - decorations drawn from the theme, where todhchai's Radharc
    hardcodes its colours (`Scene.swift`);
  - the theme tree at `/svc/windows/theme` and the resolved theme in a
    shared VMO (D91);
  - Platinum Indigo as the default from this step on.
  
  Three designs come first: colour (sRGB unless tagged, blended in
  linear light), the trusted prompt (before the privileged services and
  their approvals) and the clipboard (below). The kit frame and the
  decorations are pixel-tested at 100%, 150%, 200% and 300% by `vx
  check-pixels`.
- **Then the SDK and Kit, then rio.**
  - The SDK's native half (Loop, Window, Route to the plumber), with
    the reference app in ≤ 12 calls. todhchai's minimal app takes 13,
    so one call goes.
  - Kit on tier 1 (KitPlatform), without its scripting (below).
  - rio, the first whole app, as it was todhchai's (choices, below);
    `terminal key → draw` is rebased onto it.
- **Then the shell.**
  - Tracker, spatial, with its 100k-entry budget on V4's `wholeListing`.
  - Deskbar, its gauges brought to zero wakeups at idle. todhchai's
    wake 15.4 times a second, which `idle.wakeups` refuses.
  - Settings, the app `docs/apps.md` §2 places here, from todhchai's
    Preferences and Inspector.
  - Notifications and the lock screen, each after its design.
  - `tile` and `space`, switchable live with both arrangements kept,
    `space` settled against a reference workflow (open question 5).
    `tile`'s layout policies are plug-in processes (D92) from the start.
  
  Tracker's icons need the codecs index and PNG, which are lifted here;
  the translators and previews are not (below).
- **Then the themes whole (D91, D108).**
  - High contrast and Neon Tab beside Platinum Indigo, each a reference
    file.
  - The customisation layers and knobs of D108.
  - The Appearance panel, with Edit and a theme per workspace.
  - `vx theme check` in `vx ci`.
  
  Graphite, Indigo Magic and NeXT follow if time allows, or with V6's
  board.
- **Then the GPU (D55-D62 on the way in).**
  - Two designs first: several outputs (arrangement, hotplug, the n/120
    scale, EDID names) and device suspend in devmgr's protocol, before
    more drivers are written against it.
  - The display class under devmgr. It is typed, as todhchai's is:
    D82 makes display no device directory.
  - virtio-gpu's 2D scanout, and direct scanout.
  - Then Venus, the Vulkan loader, Loinnir, Radharc's GPU composer and
    UIGPU. `theme.compose.4k` is measured here.
  - The colour matrix from each output's EDID comes with the class.
- **Then the manual as hypertext and hot reload.**
  - The guide viewer with the plumber's `name(N)` rule (D86).
  - `system/ld`'s fresh copies with TLS, the SDK's host template and
    `@HotState` (D92).
  - The reference app reloaded from the dev machine through `/mnt/term`.

## The choices

- **V5's desktop is amd64's and arm64's.** Kit, rio and the shell are
  tier 1, full Swift (D47), which rv64 lacks until its LLVM has Swift's
  calling conventions. rv64 builds Radharc and the tier 0 layers, and
  its desktop follows tier 1 there, as V3's cpu server did.
- **Fonts are data under D4,** as the Unicode tables are: each face is
  carried with its licence and its source recorded, in IMPORTS.tsv's
  form, and only openly licensed faces are allowed (D24's Archivo and
  IBM Plex Sans and Mono; Plex is in todhchai's `data/fonts`, Archivo
  comes from its upstream). tzdata is the same question and gets the
  same answer when local time is taken up, which is not in V5's exit.
- **rio's files are the subset that needs no `/dev/draw`** (D75, D82).
  Each window serves `cons`, `consctl` (`rawon`, `rawoff`, `holdon`,
  `holdoff`, reset on close), `kbd` (cons's input off while it is
  open), `label`, `text`, `wctl` (rio's verbs, with a read that waits
  on a change, D84), `wdir` and `winid`. Not served: `mouse`, `cursor`,
  `window`, `winname` and `screen`, which are `/dev/draw`'s world. The
  window's text model is UICore's `TextDocument`, edited after the
  output point as rio's is. The pty's line discipline isn't carried.
- **vt takes over its window.** A program in a rio window that wants
  graphics (`vt`, and later anything else) asks the window's `wctl` for
  its surface and gets the window's view token. It draws in the window
  through the SDK until it exits, when rio takes the window back. This
  is Plan 9's `winname`, done with a typed handoff in place of
  `/dev/draw`. So `vt` has no second window, and TerminalCore's parser,
  screen and key encoder move into it unchanged.
  - As built (2026-10-19): the handoff runs the other way. The program
    must hold the view's channel to draw in it, so it opens the view and
    lends its token to the window's `surface`, a file of its own beside
    `wctl` (RioIPC.Surface, rio-surface(5)), and the window embeds it.
    A token can't be duplicated, so the window can't embed it again to
    size it: Radharc's Window protocol gained `placeEmbedding`. The
    screen moved in with one fix, to a resize under the alternate
    screen.
- **The clipboard is Radharc's `snarf`.** It is one file of text in
  each window's namespace, as rio has it, plus a directory of typed
  entries (NeoVectra's typed snarf). Radharc holds a copy, so the
  clipboard outlives its source. Drag and drop rides the same entries.
  Its design is written before Radharc's step, and the plumber, not the
  clipboard, carries anything meant to be acted on.
- **Budgets that measure later milestones move.** These moves are not
  loosenings; each budget's limit stays as it is (principle 15):
  - `game-loop frame error` and `synth at 128 frames` go to V9, which
    has the reference game and audio. V5 has no audio driver.
  - `editor steady state` goes to V11, which has the editor.
  
  V5 keeps the Tracker listing, the minimal app, cold start to first
  frame, terminal key to draw, the mode switch, the idle desktop's
  wakeups and RSS, and D91's and D92's own.
- **The composition budget is judged under Venus on the dev machine's
  GPU,** reported as `theme.compose.4k`, as KVM's numbers are judged on
  this machine; `theme.compose.board` judges each board's (V6).
- **Kit's scripting isn't carried in V5.** ScriptIPC's verbs are what
  the Ghost's tools would be (D90, `docs/ghost.md`), so they are
  designed there, once, rather than lifted now and replaced.
- **Line counts land with each lift.** `vx loc` gains a row for text,
  ui, radharc, the shell's apps and graphics as each arrives. Generated
  Vulkan and Venus bindings (about 20k of graphics' 31k lines) are
  counted as generated, apart from what a person writes, as idlc's
  output is.

## Left out

- todhchai's translators, previews and Player (V14).
- Audio (V9, V14).
- Edit, which becomes the editor (V11).
- The hosted SDK over Wayland and PipeWire: a way to run apps on
  Linux, not needed for V5's exit.
- The touchpad, whose design waits for a device that has one (QEMU and
  the first board have none). Touchscreens and pens remain out of
  scope.
- Local time over D48's UTC.

D75 places rio in "Radharc (V6)". That was before D76 renumbered the
milestones, and this entry puts it in V5.

## Exit

V5's exit in the roadmap, on amd64 and arm64:

- The desktop budgets are green on QEMU, under Platinum Indigo and
  under Neon Tab.
- The mode-switch budget is green, and so is `theme.switch` between
  those two themes and between a theme's knobs (D108).
- The kit frame's pixel tests pass for each shipped theme at 100%,
  150%, 200% and 300%, and every shipped theme passes `theme check`.
- rc runs in a rio window with no pty and no escape sequences. `vt`,
  taking over a rio window, runs a tier 1 program that wants xterm.
- The SDK's reference app hot reloads from the dev machine, through the
  cpu session's `/mnt/term`, within `reload.module_10k`. A layout
  policy is replaced live with no frame missed (`plugin.replace`).

Amended by the owner at V5's close (2026-10-22, D122, D123):
- The desktop budgets' times are judged under KVM, which this machine
  has for amd64 only. arm64's cold start and key → draw are judged on
  the board in V6, as the file budgets are (D105); its key → glass, a
  frame count, is judged here (1 frame).
- `reload.module_10k` is missed and accepted: 1.5 s against 1 s, bound
  by swiftc's front end. The limit stands.
- `theme.compose.4k` stays an open target.
- Deskbar's idle wakeups are no longer tested: the check flaked and was
  removed (no arch's run over 5 minutes, and flaky checks go).

The owner decided this scope (2026-10-18), naming three of its choices:
vt taking over its rio window, fonts as data under D4, and the budgets
moved to V9 and V11.
