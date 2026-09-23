# Workbench: a desktop, Amiga's way, on Plan 9's files

**Written before the code.** `docs/DRAW.md` ends with a window system that
has windows, chrome, a focus rule, `move`, `size` and `raise`. It has no
way for a person to use any of it. Every screen document stops at the same
sentence: there is no pointing device in this system yet. `docs/THREAD.md`
ends with a library built for `rio`'s shape, a keyboard proc and a mouse
proc feeding one proc of threads, and no mouse proc. This is the plan for
what those two were waiting for: a desktop a person sits at.

The draw server is called `intuition`, which is the name of the Amiga's
window library. That was a promise. Workbench was the desktop Intuition
carried. MUI was the toolkit the Amiga grew ten years later, in which
every pixel of the look was the user's to set.

This plan takes what those
two got right and keeps the chassis `docs/DRAW.md` section 12 built. All
of it goes on files a namespace can name. `docs/HANDOFF.md` section 6
points here.

## 1. What is taken, and from where

**From Intuition and Workbench.** Windows with system gadgets on the
frame. Close is at the top left, depth and zoom at the top right, and a
sizing corner at the bottom right. The bar is what a window drags by. A
screen bar across the top carries a title and, on the right button, the
menus.

The desktop is a backdrop window of icons. A drawer is a directory and
opens as a window of icons. A tool is a program and runs when opened. A
project is a file and opens with the tool that knows it. `Execute
Command...` and `Shell` are on the first menu.

Keyboard chords use the Amiga key, which is the Alt key here.
Commodities' idea comes with them: a chord is caught before the window in
front sees it.

**From MUI.** A toolkit whose objects lay themselves out. A group is
horizontal or vertical. A child says the least and the most it can be
and carries a weight, and the group divides what it has. Every gadget has
a hotkey, the letter underlined in its label, and the keyboard reaches
every gadget without a mouse.

And the lesson that made MUI: **the look is data.** Frames, colours, font, spacing and the pointer come from a
preferences file the user edits, and a program never names a colour.

**From `rio`.** A window is a directory of files: `cons`, `consctl`,
`mouse`, `wctl`, `winid`. A program that has one reads its keys and its
mouse from files in its own namespace. A window per program. The desktop
is a program like any other, not a mode of the server. A mouse is a text
line.

**From Mission Control, in place of the Amiga's screens.** The Amiga
had several screens because its hardware could show one mode at a time
and a program wanted its own. This glass has one mode and enough pixels.
What a person wants is not a second screen but a second *set of
windows*, which is a workspace.

There are nine, and a chord switches between them. A program's windows
land on the workspace a rule names. An overview shows every workspace at
once, scaled, to pick one. Section 4 has it.

**From Omarchy's Quattro.** A notice with a history, so a toast missed
is not a toast lost. One searchable line that finds a program, a tool, a
menu item or a chord by a few of its letters. A personal theme file
merged over the shipped one, so a tweak of two lines survives a change
of theme. And the agent's state as a lamp on the chrome, so a person
sees the machine wants a yes without finding the window.

**Not taken.** The Amiga's screens, for the reason above. AmigaDOS's
devices and assigns, which a namespace does better. The `.info` file,
which was a binary icon format with a position in it. The CLI, and
system requesters that stop the machine. A window's menus on the screen
bar, for a reason section 4 gives.

**Kept as it is, until `docs/CHROME.md`.** The chassis: heavy bevels,
brushed magnesium over deep slate, amber and cyan and phosphor, copper on
the bar in front. The theme file's defaults are `sys/libpal`'s table and
`docs/DRAW.md`'s chrome. A user who never edits the file sees the machine
the kernel painted at boot.

**From `plan-neo`'s chrome study, planned.** `docs/CHROME.md` adopts the
study's look. That is the neon scheme, surfaces as materials, four faces
and vector icons. It is also NeXT's docked main menu, a dock of live tiles,
a top bar of status, and a column viewer. The chassis becomes the `magnesium` scheme, one line
away. Step 6 is the order.

## 2. Who owns what

    kernel/drivers/mouse   the PS/2 mouse on the 8042's second port, IRQ 12,
                           served as `/dev/mouse` in `rio`'s text format
    servers/kbdfs          the scancode translation as a package both rings
                           call, and a `kbd` file in 9front's format, so a
                           reader sees the keys and the modifiers rather
                           than only the characters they made
            servers/intuition      the pointer and the cursor, the gadgets on the
                           frame, a `mouse` and a `wctl` per window, and
                           the chords a keys file names. The workspaces,
                           the overview, and the rules that place a
                           window on one. Also the kinds of window a
                           desktop needs: a backdrop, a bar, a popup with
                           no frame
    sys/libmui             the toolkit: objects, groups and layout, gadgets,
                           requesters, menus, hotkeys, the theme file
    sys/libraster          planned, `docs/CHROME.md`: gradients, noise,
                           bevels, blur, coverage and paths, painted into
                           a window's store
    apps/workbench         the desktop: the screen bar and its menus, the
                           backdrop and its icons, drawer windows, tools
                           and projects, `Execute Command...`, `Shell`
    cmd/window             `rio`'s `window`: open a window and run a command
                           in it, from any shell, the serial one included
    apps/view              a text viewer, the first tool a project opens with

Three files a person edits, all plain text with `#` comments, all looked
for in `$home/lib` and then in `/lib`:

    keys        one chord per line, and what it does
    theme       the look: which bevel a class of gadget wears, the palette
                roles, the font, the spacing, the pointer
    workspaces  one line per rule: a window's name, and the workspace it
                opens on
The theme is the exception. Both copies are read, and section 5 says
why.

## 3. Input, as files

### The mouse

`/dev/mouse` is `rio`'s line, and the kernel's driver writes it:

    m 312 200 1 48213

An `m`, the position in screen coordinates, the buttons as a bit per
button with 1 the left, and a millisecond count. A read parks until the
mouse moves or a button changes, and answers one line.

The driver is the keyboard's shape in `kernel/drivers/kbd`. A top half that may not park
takes the three bytes of a packet off the 8042's second port at IRQ 12.
A ring holds them. A bottom half assembles packets into lines. The
self-test injects packets the way `verify_scancode_reader` injects
scancodes, which is what lets a machine with no mouse check the desktop.

`/dev/mouse` is exclusive the way `/dev/fb` is: whoever holds it open owns
the pointer, and that is the draw server. A program never reads it. It
reads its window's.

### The keyboard, with its modifiers

`docs/KBD.md` says the layout is a table in a driver, which is the wrong
place, and `servers/kbdfs` carries a second copy of it. The scancode
state machine becomes `sys/libkbd`, one package, and both `kernel/drivers/kbd`
and `kbdfs` call it. The package answers a rune per key, including the
ones that have no character. `sys/libkey` grows `KALT`, `KCTL`, `KSHIFT`,
the function keys, the keypad, `KDEL`, `KINS`, `KPGUP` and `KPGDOWN`.

`kbdfs` then serves two files. `cons` is what it serves today: cooked
bytes, the keys that made a character and nothing else. Every reader
that wants a keyboard as a byte stream reads it. `kbd` is 9front's, one
message per read:

    c<runes>    the characters typed, as UTF-8
    k<runes>    every key held down, after a press
    K<runes>    every key held down, after a release

A reader of `kbd` sees the Alt key go down and the `n` go down beside it,
which is a chord, and sees the release. That is the whole of what a chord
needs, and it is why `/dev/cons` could never carry one. `intuition` reads
`kbd` from now on, and the window in front gets what `intuition` does not
keep.

### A window's files

A window's directory under `/srv/draw` grows from four files to seven:

    data      the command stream, as now
    ctl       the geometry out and the lines in, as now
    cons      the keyboard, cooked or raw, as now
    consctl   `rawon`, `rawoff`, as now
    mouse     `m x y b msec` in the window's own coordinates, a read
              parked until the mouse moves inside the window or a button
              changes while the pointer is in it
            wctl      `rio`'s, and one word more. A read answers `x y w h current
              visible workspace`. A write takes `move`, `size`, `raise`,
              `lower`, `close`, `zoom`, `current`, `hide`, `unhide`, and
              `workspace N`
    cursor    a write sets the pointer's image while it is over this
              window, an empty write restores the default

`ctl` stays for what `docs/DRAW.md` built on it and `wctl` is its
superset, so the terminal need not change to keep working. A client binds
its window's directory over `/dev` as the terminal does, and opens
`/dev/mouse` like any program on `rio`.

## 4. Intuition, with a pointer

**The cursor is the compositor's last layer.** The server draws the
pointer onto the glass after every composite, over whatever window it is
on, from a small image with a mask. It moves with every `/dev/mouse`
line, which the server reads from an io proc. The stack, top down, says
which window is under it. The line goes to that window's `mouse` file in
that window's coordinates, held for a read the way a `cons` line is.

**The gadgets are chrome, and chrome is rectangles.** `sys/libdraw` grows
`gadget`: a raised square of magnesium with a glyph of amber on it, and
a pressed state that is the same square sunk. `window_frame` places four
of them and the bar. The server decides a press on one from the pointer's
position against the frame it drew, and does what the `wctl` line would.

Close hangs up the session's `data` fid. Depth sends the window to the
back. Zoom toggles between the window's own geometry and the full
screen. The sizing corner starts a drag that ends in a `size`, and the
bar starts one that ends in a `move`. A press anywhere in a window
raises it and gives it the focus, which is the click-to-front rule
Workbench 2 had and `rio` has.

A hangup gives a program no chance to save. Step 5 plans the close gadget
as a request the program answers, with today's hangup kept as `Kill`
behind a grace period.

**Three kinds of window a desktop needs**, each a `wctl` word at open:

    backdrop   behind every other window, never raised, never framed, the
               size of the screen below the bar. Workbench's own.
    bar        the strip across the top, never covered, never focused,
               never framed. Workbench's own, and its menus hang off it.
    popup      no frame, closes when the button is released outside it or
               a key ends it. A menu, a cycle gadget's list, a tooltip.

Every menu in the system is a popup, drawn by the program that owns it
into a window the server never learns is a menu. That is why a window's
menus are not on the screen bar. On the Amiga, Intuition drew every
program's menus, and here the server draws nothing but chrome. A program
that wants a menu opens a popup where the pointer is on button 3, which
is `rio`'s way and MUI's `Popmenu`. The screen bar's menus are
Workbench's popups, opened from the bar.

`docs/CHROME.md` section 8 keeps this rule and moves where a menu shows.
One menu tree shows three ways. It is docked at the top left as NeXT's
main menu, a popup at the pointer, or torn off into a panel that stays.
That adds two kinds of window, `menu` and `panel`, and takes the menus off
the screen bar. It is planned.

**A window that wants a person says so on `wctl`.** `state working`,
`state waiting` and `state idle` are three words a program writes, and
the frame shows a lamp for them beside the title. Working is lit,
waiting is hot, and idle is no lamp. The workspace lamp on the screen
bar goes hot while any window on it is waiting, so a parked question
is seen from every workspace. The ghost writes the words,
`docs/GHOST.md` section 4, and a build script can write them too. The
server knows nothing of what the program waits for, which is why the
word is on the window and not on the program.

**The snarf buffer is the server's.** `/srv/draw/snarf` is `rio`'s
`/dev/snarf`: one clipboard the whole desktop shares. It is a file at the
server's root and a name in every window's directory too -- the same buffer
either way, with no window of its own -- so the bind that puts a window's
files over `/dev`, `cmd/window`'s and `sys/libmui`'s, makes `/dev/snarf` this
window's with no second bind. A write replaces it and pushes what was there
onto the history, ten deep, so a thing cut over is not lost; the history is
its own read-only file, `snarfhist`, since a file cannot also be the `snarf`
directory the plan first drew. An image is a write of a `sys/libdraw` image's
bytes, and a program that reads one gets pixels back. The buffer is capped,
small: static memory in a server whose whole image must fit the loader's
budget, so it holds a selection -- a line, a paragraph, a small image -- and a
write past the cap keeps what fits. See `servers/intuition/snarf.odin`.

**The chords are the server's, and a file says which.** `intuition` reads
`$home/lib/keys`, and `/lib/keys` when there is none, at start and on a
`reload` line to `/srv/draw/ctl`:

    # keys: a chord, and what it does. Alt is the Amiga key.
    alt-n        window rc -i          # a new shell
    alt-w        close                 # the window in front
    alt-tab      cycle                 # the focus to the next window
    alt-z        zoom
    alt-b        back
    alt-up       move 0 -16            # nudge the window in front
        alt-m        menu                  # Workbench's first menu
    alt-e        execute               # Execute Command...
    alt-1        workspace 1           # and so on to alt-9
    alt-right    next                  # the workspace after this one
    alt-left     prev
    alt-shift-2  send 2                # the window in front, to workspace 2
    alt-space    overview              # every workspace at once
    ctrl-alt-q   quit

A chord is a key with `alt`, `ctrl` and `shift` in front of it. A key is
a character or a name: `tab`, `esc`, `space`, `up`, `f1`, `del`. The
server recognises a chord from the `k` messages and swallows it. It acts
on the actions it knows: `close`, `cycle`, `zoom`, `back`, `move`,
`size`, `raise`, `workspace`, `next`, `prev`, `send` and `overview`. Any
other action goes out, verbatim, as a line on
`/srv/draw/hotkey`, which the desktop program holds open and reads:

    window rc -i

That is Commodities' Exchange in one file and one line of protocol. The
window manager does what a window manager does. The desktop does what a
desktop does. Neither knows the other's actions, and a person edits one
file for both. A chord the file does not name reaches the window in front
like any key.

**Workspaces, and the overview.** A workspace is a number on a window,
one to nine, and nothing else. The stack is one list, as now, and the
compositor paints the windows whose number is the current one. A switch
repaints the glass from the other set of windows. The focus goes to the
front one among them, which the stack already remembers.

A window is born on the current workspace, or on the one a rule names.
`wctl workspace N` moves it, and the `send` chord is that for the window
in front.

The bar shows a lamp per workspace, in the chassis's strip of lamps. A
lamp is lit for a workspace that has windows, hot for the current one,
and dark for an empty one. That strip stops being the lamp per window
slot `docs/DRAW.md` section 12 built, which said nothing a person
needed.

The overview is Mission Control's picture: every workspace at once. The
server paints the glass with nine tiles, three by three, over a dimmed
ground. Each tile is a workspace's windows scaled down by three from
their own stores, frames and titles and all. Scaling by an integer is a
row and a column skipped. The compositor does that from the stores it
already holds, so no program takes part and none is asked to redraw.

A click on a tile switches to it. Escape, or the chord again, returns. A
press on a window inside a tile and a release on another tile moves the
window to that workspace, the drag between workspaces, and the picture stays
up so the move is seen. See `overview_release` in `servers/intuition`.

**Rules put a program where it belongs.** A window gets its name from
the `name` line its program writes, `terminal` or `view` or `Home`, and
`$home/lib/workspaces` maps a name to a workspace:

    # workspaces: a window's name, and where it opens
    terminal   2
    view       3
    Home       1

The server reads the file at start and on `reload`, and applies a rule
when a window is named. A window with no rule stays where it was born.
The name is the only thing the server knows about a program, which is
why the rule is on the name. It is also what a person sees on the bar,
so the rule is written in the words on the screen.

**More windows.** `MAX_WINDOWS` is two because two is what the self-test
needed. A desktop with a drawer open and two shells is five, and nine
workspaces make more worth having. A window costs a segment the size of
its store, and `docs/DRAW.md` names the three numbers that move
together. They move to thirty-two, and a window's run is bought at its
own size rather than the screen's width, which is what `segbrk` was
for.

## 5. libmui: the toolkit, and the look as data

A MUI object is a record with a class, and a class is a table of
procedures: `min_max`, `layout`, `draw`, `handle`. The tree of them under
a window is laid out top down and drawn into the window's `data` stream
as `sys/libdraw` pieces and text. Nothing in the toolkit knows a colour or
a pixel width. It knows roles, and the theme names what a role is.

**Layout is MUI's.** Every object answers the least and the most it can
be in each direction, and a default. A group is horizontal or vertical.
It asks its children, adds them up along its axis and takes the largest
across it. Then it divides what it has by the children's weights, inside
their limits.

A window's size is its root group's default, and a `size` from the
server lays the tree out again. That is the whole of it, and it is why a
MUI program never places a gadget by a number.

**The classes for the first release:**

    Window      a `/srv/draw` window, its files, and the event loop
    Group       horizontal or vertical, with a frame and a title or none
    Text        a label, drawn as written
    Button      a raised panel with a label, pressed on click or hotkey,
                which `_` before a letter of the label names
    Checkmark   a lamp, lit or not
    Cycle       a button whose label is one of a list, and a popup of them
    String      one line of text, `sys/libedit` wearing a well
    Slider      a knob in a well, horizontal or vertical
    List        rows of text in a well, one selected, a scrollbar beside
                (built for the debugger's window: rows, a top row, a
                selected row on a bar of the face, a press selects; the
                scrollbar waits)
    Scrollbar   a knob in a trough, with arrows
    Image       pixels, loaded once
    Space       nothing, with a weight
    Requester   a window of a text and some buttons that answers which
    Menu        a popup of items with hotkeys, and submenus

**Events are `rio`'s.** A window's event loop is a `libthread` thread
that `alt`s over three channels. The mouse comes from an io proc reading
the window's `mouse` file. The keys come from an io proc reading its
`cons` in raw mode. The third channel is the program's own.

A mouse line is hit-tested down the tree. A key goes to the focused
gadget, or, with Alt, to the gadget whose hotkey it is. Tab moves the
focus, Return presses the default button, Escape presses the cancel. So
every
requester in the system is usable from a keyboard alone. MUI insisted on
that, and it matters on a machine where the mouse may be a self-test
injecting packets.

**A gadget that acts plays a relay click**, `docs/HANDOFF.md` section 1's
"tracker-synthesised relay clicks": a short burst of noise under a fast fall,
made once and written to `/dev/audio`, the tick of a 1994 workstation's relay.
`activate` is the one place a gadget acts and so the one place it plays, and
every program on the toolkit gets it. A machine with no sound card is silent;
the device is shared, so several MUI programs each play their own. See
`sys/libmui/sound.odin`.

**The theme is a file, and the palette is its default:**

    # theme: the look. A role, and what it is.
    font        /lib/font/8x16          # the only font there is, for now
    face        magnesium               # a raised control
    ground      slate_deep              # the desktop, a window's well
    text        amber
    text.hot    amber_hot               # the focused gadget's label
    text.dim    amber_dim               # a gadget that cannot be pressed
    value       cyan                    # a string gadget's contents
    ok          phosphor
    bar         copper                  # the title bar of the window in front
    bar.lit     copper_lit              #   its highlight edge
    bar.shade   copper_dark             #   its shadow, and every other bar's face
    plinth.lit  magnesium_hot           # the raised border's highlight
    plinth.shade magnesium_dark         #   its shadow
    bevel       2                       # the depth of a raised edge
    well        2                       # the depth of a sunken one
    pad         4                       # inside a group
    gap         6                       # between children
    pointer     arrow                   # or a file of pixels

A name on the right is one of `sys/libpal`'s, or six hex digits.

**A theme is merged, not chosen.** `/lib/theme` is read first and
`$home/lib/theme` after it, and the later line for a role wins. So a
personal file of two lines, a font and a `gap`, keeps them under every
theme the shipped file becomes. The first line of the personal file may
be `use phosphor`, which reads `/lib/themes/phosphor` in place of
`/lib/theme` and merges the rest over it. `Workbench > Theme...` is a
`List` of the names under `/lib/themes`, with the well repainted as the
selection moves, and choosing writes the `use` line.

Both files are read at start and on a note or a chord, and every window
lays itself out again. `intuition` reads the same two files for the
frame it draws -- the `bar.*` roles for the copper title bar, `plinth.*`
for the raised border, the rest being the toolkit's -- so a window's
chrome and the gadgets inside it are one look. The unfocused bar is not
its own role: it is the focused bar one step down its own table, the
lamp's rule. A theme that names nothing is the chassis.

**Schemes and job roles are done**, `docs/CHROME.md` section 3. A theme
may define colours with `colour` lines, and a scheme is a file of them.
Four ship: `neon`, `neon-hc`, `daylight`, and `magnesium` for the chassis.
Roles name a job, `accent`, `focus`, `warn`, `ok`, `fault`, and the
toolkit's older names read as other names for them.

The rest is planned. The effects, `glow`, `shadow`, `scan`, `bloom` and `motion`, are roles
with numbers. The toolkit paints its window's store, section 2 of that
document, and grows `Knob`, `Readout`, `Led` and `PageList`.

**The toolkit is not the window manager and not the desktop.** It draws
inside a window it was given. What a program on it looks like is the
theme's business, where its window goes is `intuition`'s, and what it
does is its own.

## 6. Workbench: the desktop program

`apps/workbench` is what `init` starts after `intuition` now, in the
terminal's place. It opens a `bar` window and a `backdrop` window, holds
`/srv/draw/hotkey` open, reads the keys file's launch actions, and draws
the desktop.

**The screen bar** says `Vectra Workbench` on the left and the machine's
memory on the right, which is what the Amiga's said. The workspace lamps
sit between them. The numbers come from a `/dev/sysstat` this step
adds to `#c`, the frame counts the boot line already prints. The lamps
are the server's, painted into the bar's strip on every switch. When a
ghost is on, its spend for the day sits beside the memory, read off
`/mnt/model/N/usage`, so a budget is never a surprise. Button 3 on the
bar opens the menus, one popup per title:

        Workbench   About..., Execute Command..., Shell, Overview, Reload,
                Quit
    Window      New Drawer, Open Parent, Close, Update, Select All,
                Clean Up
    Icons       Open, Copy, Rename..., Information..., Delete...
    Tools       every file in /lib/wb/tools, by name

**Icons are kinds, not files.** `docs/CHROME.md` sections 6, 11 and 12
plan the next shape of this section. The icons become vector files that
repaint with the scheme, with more kinds and an emblem. A drawer gains a
column view. The screen bar becomes a top bar of status, beside a dock on
the right edge. The rules below hold until then.

**Today, a kind is what a `stat` answers.** A directory is a drawer, a file under
`/bin` or with its execute bit is a tool, anything else is a project. Each
kind has one image, drawn in the chassis's vocabulary. A drawer is a
plinth with a bar and a tool is a plinth with a lamp. A project is a well
with lines in it. A name is drawn under it in amber.

There is no `.info` file, because a kind a `stat` can answer is not worth a file beside every
file. A picture a user chose is the day a `$home/lib/wb/icons` tree
exists.

**The backdrop** carries one icon per thing a person starts from: `Home`
for `$home`, `System` for `/`, `Tools` for `/bin`, and one per disk under
`/n`. A double click opens a drawer window.

**A drawer window** is a MUI `Window` whose root is a `List` of icons in
a well, with a scrollbar. An icon dragged within its window is placed there
freely; `Snapshot` keeps the placement in `$home/lib/wb/snapshot` and the
window loads it when it opens; `Clean Up` drops the placement and lays the
icons out in rows again. The backdrop's icons snapshot the same way, from the
`Workbench` menu. A double click on a drawer opens it. On a tool it runs
`window <path>`. On a project it runs `window view <path>`, or the tool a
line in `/lib/wb/types` names for the file's suffix.

A single click selects, and the `Icons` menu acts on the selection. `Information...` is a requester of the file's `stat`.
`Rename...` and `Delete...` are requesters that ask first.

**`Execute Command...`** is a requester with a `String` gadget and a
`List` above it, and runs what is typed in a window. The list matches
what is typed against `/bin`, `/lib/wb/tools`, the menu items and the
chords' actions, by letters in order or by initials. So `ec` finds
`Execute Command...` and `wrc` finds `window rc -i`. Return runs the
selected line, and a line that matches nothing runs as typed. It is
Spotlight's line for a person who knows a name, and the menus stay for
a person who does not.

**`Shell`** is `window rc -i`. Both are also chords in the keys file,
and both are what a person who never touches the mouse will use.

**A notice is a line written to a file.** Workbench serves `/mnt/wb`,
and `notice` is a file in it:

    tracker   Song finished: aurora.mod
    window    pong faulted: addr=0 pc=0x4021c0	ask -c debug -p 41

The first word is the source, the text follows, and a tab and a verb
after that is the action. A notice draws as a toast in the bar's corner
for five seconds, with the machine's frame around it, and a click runs
the action. `notice/history` is the last ten, and `notice/ctl` takes
`quiet` and `loud`, so a person giving a talk sees none and reads them
after. Two notices with one source and one text inside a minute are one
notice with a count. A build that fails ten times says so once.

The action is a verb Workbench's own `ctl` knows, `open`, `run`, `ask`
and `workspace`, with the rest of the line as its argument. It is never
a shell string, and the notice's text is never in it. Omarchy's notices
were a bash string, and a video's title reached a shell that way. A verb
whose argument is the rest of the line cannot be made to.

**A fault is a notice, and the process waits for the answer.** `window`
runs every program the desktop starts, so `window` is what sees one
die. When its child dies by an uncaught trap -- `await` answers the word
`fault` -- `window` posts `window <prog> faulted` to `/mnt/wb/notice`. A
typed `exit`, a `^C` or a `kill` is not a fault and posts nothing. That
half is built. The trap's `addr` and `pc` are not in the await word on
the ending path, so the notice names the program but not yet the place.

When the ghost is on, `window` writes `startstop` to its command's
`ctl`, and a fault parks the process before the note lands,
`docs/DEVTOOLS.md` section 7; the notice then carries `ask -c debug -p N`
as its action. The parking and the action wait on `docs/GHOST.md` step 3.

A click hands the parked process to the ghost, which attaches the
debugger and reads `bt`. A
notice dismissed, or ten more behind it, lets the note through and the
program ends as it always did. With the ghost off, the notice says the
program faulted, and nothing waits.

**Drag and drop moves an icon between drawers**, step 5's. It is a `cp` and
an `rm`, but the pointer crosses from one window to another mid-press, so the
server hands the drag between windows: a client press grabs the pointer, and
every line until the button is up goes to the window the press began in,
wherever it roams (`servers/intuition/pointer.odin`). The window hears the
pointer leave its bounds and the release with the point it landed on.
`sys/libmui` turns a press on an icon that releases elsewhere into `on_drop`,
the cell and the release point; `apps/workbench` maps that point to the drawer
under it and moves the file there. A directory is left where it is -- a
recursive move is a later day -- and a drop on no drawer does nothing.

## 7. The order

Each step ends with a boot line, and each is usable before the next
starts. Input comes first because everything after it reads a file
input writes. The server's pointer comes second because the toolkit's
events are its lines. The toolkit comes third because the desktop is
written in it. The desktop is last because it is what the first three
were for.

### Step 1: input, as files

`kernel/drivers/mouse`, `sys/libkbd`, `sys/libkey`, `servers/kbdfs`,
about 900 lines, half of them moved.

- **The mouse driver**, on the 8042's second port, at IRQ 12 through the
  I/O APIC line `docs/KBD.md` assumes rather than reads. Three-byte
  packets, a ring, `/dev/mouse` in `rio`'s format, a read that parks. A
  packet injected by the self-test the way a scancode is.
- **The scancode package.** The state machine out of `kernel/drivers/kbd`
  and out of `servers/kbdfs` into `sys/libkbd`, called by both. Every
  extended key answers a rune from `sys/libkey`, the modifiers included.
- **`kbdfs` serves `kbd`**, 9front's messages, beside the `cons` it serves
  now.

Proves, in three checks. `cat /dev/mouse` on the serial line prints a
line per movement under `--gfx`. The self-test injects three packets and
reads three lines with the positions it sent. `kbd` answers `k` with
`KALT` and `n` in it for an injected Alt-n, and `cons` answers nothing
for the same keys.

**Where it stands.** Done. `kernel/drivers/mouse` is the keyboard's
shape on the 8042's second port, and `docs/MOUSE.md` is its document. A
packet decoder is checked on its own. An injection through command 0xD3
takes the whole interrupt path. `/dev/mouse` is in `rio`'s widths, with
one reader and a read parked until a movement.

`sys/libkbd` is the state machine, called by `kernel/drivers/kbd` and by
`servers/kbdfs`. It answers a position and what the position means
apart, so a `kbd` file can report the keys held under the modifiers of
the moment. Every key answers a rune, and a key pressed with alt held
makes no character. `kbdfs` serves `cons` and `kbd`, and `init` points
the draw server at `cons`.

The suite injects alt, `n` and their releases and reads four messages
off `kbd`. Then it reads one `x` off `cons`, with none of the chord in
front of it. The mouse's line is checked from the file's side in the
kernel, because no program reads it until step 2.

### Step 2: a pointer, gadgets, and chords

`servers/intuition`, `sys/libdraw`, about 1,500 lines.

- **The cursor**, from an io proc on `/dev/mouse`, drawn last.
- **`mouse`, `wctl` and `cursor` per window**, with `ctl` kept.
- **Gadgets on the frame**, `libdraw.gadget`, and the four presses plus
  the two drags. Click to front.
- **Backdrop, bar and popup** as `wctl` words at open.
- **Workspaces**: the number on a window, the switch, `send`, the
  lamps, the rules file, and the overview as a scaled composite.
- **The keys file**, the chords the server acts on, and `/srv/draw/hotkey`
  for the ones it does not.
- **Thirty-two windows**, each buying a run of its own size.

Proves, in five checks. The self-test moves an injected pointer onto a
window's bar, presses, moves and releases, and reads the new position
off `ctl`. It presses the close gadget and sees the session's `data` fid
answer a hang up. It reads a window's `mouse` and gets the line in the
window's coordinates. It binds `alt-w` to `close` in a keys file and
sees the window in front close on the injected chord. It binds `alt-n`
to `window rc -i` and reads that line off `hotkey`.

And three for the workspaces. A rule that names the test's window puts
it on workspace 2, and the glass on workspace 1 shows ground where the
window was. The `workspace 2` chord brings it back, with the focus on
it. The overview shows the window's bar scaled by three at the second
tile's place, and a click there switches.

**Where it stands.** Done. `servers/intuition` grew a `pointer.odin`, a
`workspace.odin`, a `files.odin`, a `keys.odin` and an `overview.odin`,
and `sys/libdraw` grew `gadget` and two-digit window names.

The pointer is an io proc on `/dev/mouse`, drawn as the compositor's
last layer. A press on a gadget closes, lowers or zooms the window under
it. A press on the bar or the corner is a drag that ends in a `move` or
a `size`. A press in a window raises it. Each window serves `mouse`,
`wctl` and `cursor` beside the files it had. A window is `Normal` or one
of the three kinds a `wctl` word makes: `backdrop`, `bar`, `popup`.

Workspaces are a number on a window, nine of them, with a lamp each on
the desktop. The overview is the compositor painting every third pixel
of the stores it holds. The chords come from `$home/lib/keys` or
`/lib/keys` through the `kbd` file. The window manager's the server acts
on, the rest it forwards on `/srv/draw/hotkey`, and a `workspaces` file
places a window by its name.

The server reads the `kbd` file now rather than cooked `cons`, so `init`
names `/n/kbd/kbd`. A window's run is bought at its own size, the stride
is the run's, and a wider window buys a new run. `MAX_WINDOWS` is
thirty-two, and `MAX_PROC_SEGS` moved with it. The image pool is on the
heap, because sixty-four images in the bss put the program past the
loader's frame budget.

The checks read the glass and the files. `verify_pointer` drives an
injected pointer onto a window and reads its `mouse`, its bar drag off
`wctl`, and its close off `cons`. `verify_chords` wires `kbdfs` and the
draw server as `init` does, and injects `alt-n`, `alt-w` and `alt-space`
for the hotkey, the close and the overview. `verify_draw` sends a window
to another workspace and switches back. Green on amd64, arm64 and
riscv64 at user 973.

### Step 3: libmui, and `window`

`sys/libmui`, `cmd/window`, `tests/mui`, about 3,000 lines.

- **`window`** first, because it needs no toolkit and every later proof
  uses it: claim a window, bind its directory over `/dev`, run the command
  with the window's `cons` as its console. The terminal becomes `window`
  and a drawing loop, which is what `rio`'s terminal is.
- **The classes**, the layout, the events, the theme.
- **`tests/mui`**: a program that builds a tree, lays it out at three
  sizes, and says the geometry it computed. The suite checks the numbers
  against the weights. Then it draws into a window and the suite reads
  the pixels, as `verify_draw` does.

Proves, in three checks. The geometry a vertical group of three weighted
buttons computes at two window sizes is the arithmetic in the document.
A requester the test builds goes away on an injected Return and on an
injected click on its button, and answers which. A theme file that names
`face` as `copper` changes the pixel under a button and nothing else.

### Step 4: Workbench

`apps/workbench`, `apps/view`, `init`, about 2,000 lines.

- **The bar and its menus**, the backdrop and its icons, drawer windows.
- **Tools and projects**, `Execute Command...`, `Shell`, the `Icons` menu
  and its requesters.
- **`view`**, so a project has somewhere to open.
- **`init` starts Workbench**, and the terminal as a program stays for
  `window`.
- **Notices**, the list in `Execute Command...`, and the spend on the
  bar.

Proves, in the suite. The suite starts the desktop and opens `Home` by an
injected double click, and sees a drawer window with the icons `verify_kfs`
left there. It presses button three on the first title and sees the menu
open, a popup with `Shell` among its items. It presses the bound chord,
which opens a shell in a window, and types at it as `verify_terminal`
types; a second chord opens one more, counted in `ps`, and an `alt-w` each
closes them. It writes a line to `notice`, reads it back off `history`,
and sees the toast's pixels in the bar's corner.

**What the suite drives, and what a person does.** Choosing an item off an
open menu is a click on a popup that opened a moment earlier, whose reader
may not have run yet. That was a race the suite could not drive while the
draw server kept one mouse line per window, since the release wrote over
the press. Step 5's mouse queue retired it, September 2026: the suite now
opens the first menu, clicks `Shell` on the fresh popup, sees one more
window, and closes it with an alt-w. The shell the suite types at is
still the one the bound chord opens.

From the serial line, `window ls` opens a window with a listing in it.
Then `ps` shows the desktop as one proc of threads and its io procs.

**Where it stands.** Built and screenshot-verified, September 2026.
`apps/workbench` opens a `bar` window and a `backdrop`. The bar draws the
four menu titles and the machine's memory off a new `/dev/sysstat`. The
backdrop lays `Home`, `System`, `Tools` and one icon per disk as a grid.

Button 3 on a title opens that title's menu as a `libmui` popup. A double
click on `Home` opens a drawer window of icons. `Execute Command...`
matches what is typed against `/bin`, the tools and the chords.

Notices are a served `/srv/wb`, mounted at `/mnt/wb`. Its `notice` file
draws a toast, and its `history` keeps the last ten. `apps/view` opens a
project in a window.

The toolkit grew what the desktop needs, all proven in `tests/mui`.
Several windows per program, the three window kinds, a `Menu` popup, an
`Icons` grid, and a `String` gadget that takes typing.

`init` starts Workbench in the terminal's place, September 2026, and the
suite drives it: `verify_workbench` in `kernel/user/verify.odin` is the
five checks above, fifty lines of them on the glass. It waited on the
stale-wake reaper race, which the desktop's many short-lived threads -- a
drawer, a toast, a menu each a thread that opens and closes -- reliably
tripped, faulting the boot with `a wake of a reaped thread`. `docs/SYNC.md`
records the fix. A shell in a window is `Shell` on the first menu, and
`terminal` stays in `/bin` for `window`. `docs/workbench-step4-desktop.png`
is the desktop under `init`: the bar's menu titles, the backdrop's icons,
a shell opened from the menu, and a notice's toast in the bar's corner.

Driving it found two things the screenshot never had. **A menu item chosen
by the mouse was never acted on.** The choice set the popup's `done` from
the toolkit's mouse thread, and `window_run` was parked in the key read,
which a popup, never focused, never gets; so the menu stayed open and the
item undone until a key came. Closing the files under that read ends
nothing, because a read in flight outlives its descriptor. So the server
took a `close` word on `wctl`, alt-w's own hangup, and the mouse thread
asks for it: the key read answers nothing, and `window_run` takes it from
there. The server kept one mouse line per window, the latest, so a press
and release a tick apart reached a slow client as the release alone, and
the suite held each injected click 120 ticks either side. Step 5's mouse
queue fixed that, and a click is two ticks now. And the notice service is posted and served before the
first window opens, mounted at `/mnt/wb` by the desktop itself through an
io proc (`libthread.iomount`, since the server it waits on is a thread of
the same proc) and by `init` for the console's shell.

### Step 5: the rest of the platform

Each its own document, in whatever order a reason arrives.

- **The fault notice's ghost half**, the day `docs/GHOST.md` step 3
  gives the click somewhere to go. `window` already posts the notice
  when a child faults (section 6); what waits on the ghost is parking
  the process on the fault and the `ask -c debug -p N` action.
- **A font past 128 glyphs**, deferred in `docs/HANDOFF.md` with its
  reason. The theme names a font file so that the day has somewhere to
  land.

**Planned from a review, September 2026. None of what follows is built.**
A review of a sibling desktop, `plan-neo`, found the gaps below in this
one. Each item names its size and where it lands. The first is the
priority, because the suite works around it today. The compositor's half
of the review, a frame clock and a `stats` file, is `docs/DRAW.md`
section 18.

- **A mouse queue, so no click is lost. Done, September 2026.** Each
  window holds a ring of sixteen unread lines,
  `servers/intuition/files.odin`, with `mseq` and `mread` its head and
  tail, instead of one line, the latest. The rule for what goes is
  `plan-neo`'s (`docs/desktop-protocol.md`, the delivery rules). A motion
  line, whose buttons are the line before's, replaces the newest unread
  line when that is motion too. A line that changes the buttons is never
  coalesced. When the ring is full a new motion line is dropped, and a
  button change pushes out the oldest motion line, or the oldest line when
  every line is a change. A ring full of changes belongs to a client that
  no longer reads, and the close request's grace period below is the
  answer to that. Keys are not in this file, because they queue in `cons`.

  The line stays `rio`'s `m x y b msec`, so no reader changed. The check,
  in `verify_pointer`, injects a press and a release a tick apart with no
  read in flight, and reads the press and then the release. A mutation
  that coalesces every line fails it. The suite's click hold went from
  120 ticks either side to a two-tick gap, and step 4's menu choice is
  driven now: a click on `Shell` on a popup that just opened. The
  grab check reads the queue in order to the line past the window's edge,
  which is where a queue and a single line differ.

- **Close as a request. Done, September 2026.** The close gadget and the
  `close` chord ask now, `window_close_request` in
  `servers/intuition/pointer.odin`. A window whose `mouse` somebody has
  open gets a `c` line on its mouse queue, a line of the `m` line's width
  that a reader knowing only `m` skips by its first byte. A window nobody
  reads the pointer of could never hear the question, so it is hung up at
  once, as before, and a shell in a `window` is one of those. `sys/libmui`
  gained `on_close`: a program with work to keep keeps it there and
  answers whether to end now, and unset the window ends at once.
  `sys/libapp` hears the line as `quit`. A second close of a window
  already asked asks nothing more.

  The grace period is the theme's `closegrace`, in seconds, five by
  default, read by `intuition` beside the frame's roles. A window asked
  and still up past it is listed on the server's `ctl` report as
  `closing N title`. Workbench's Window menu reads that when it opens and
  grows a `Kill title` for each, which writes `kill N`, a hangup, the
  close gadget's old answer. The check is in `verify_pointer`: with the
  window's `mouse` held, the gadget puts a `c` line on it and the window
  stays; past the grace `ctl` lists it; and `kill 1` hangs it up. The
  alt-w on a Workbench drawer, a toolkit window, goes through the request
  and still closes it.

  The clock under the grace found a bug on the way. `libdraw.scan_int`
  refuses a number past 2^24, and `/dev/time`'s every field is past it, so
  the uptime read as zero. `libapp`'s `read_uptime` read it the same way,
  and a frame's `dt` was zero for every game. `libdraw.scan_u64` is the
  scanner a clock's fields take now, in both.

- **Theme reload for every `libmui` program. Done, September 2026.** The
  reading moved into `sys/libmui/theme.odin`: `theme_load` reads
  `/lib/theme` or the `use`d `/lib/themes/<name>` and `$home/lib/theme`
  over it, and `window_open` calls it the first time, so every window
  opens in the person's theme. `intuition` serves `theme` at its root, a
  generation number a `reload` bumps. A read at offset N answers once the
  number passes N and is held until then, so a client keeps the last
  number it read and waits with one pread, with no state in the server.
  The first window a program opens starts `theme_watch`, a thread on an io
  proc of its own, which on a new generation loads the files again and
  lays out every window that follows the shared theme. A window whose
  program set its own theme, and a popup, do not follow.

  Workbench's `Theme...` writes `use` and then `reload`, and its own
  windows follow by the same watcher as every other program's. The check
  is in `verify_muiwin`: a personal theme that names `face copper` and a
  `reload`, and the demo's button face, a program that is not Workbench,
  is copper; the file removed and a second reload, and it is magnesium
  again. A program a `cpu` runs watches `theme` under `$wsys`, so it
  follows the terminal's theme.

- **More `wctl` words. Done, September 2026.**

      snap left|right|full    half or all of the screen below the bar
      snap grid C R I         cell I of a grid C wide and R high
      minsize W H             the least the sizing corner and `size` give
      maxsize W H             the most
      parent N                a transient of window N; -1 is none

  A snap keeps the window's own geometry the way `zoom` does, so `zoom`
  after a snap puts it back, and a second snap keeps the first place.
  `window_size` clamps every resize to the bounds, the sizing corner's and
  a `size` line's alike. `sys/libmui` writes `minsize` from its root's
  least and `maxsize` from its most when the tree has one, so a person
  cannot size a toolkit window past its layout. A transient is raised over
  its parent whenever the parent comes to the front, and hidden, shown and
  sent to a workspace with it. A parent is one level deep, never itself a
  transient, and a slot reused forgets the transients the old window had.
  `sys/libmui`'s `Window.parent` writes the word for a window a program
  opens from another; the programs that open requesters do not set it yet.

  The check is in `verify_pointer`, on window 1: a snap left is the left
  half and a zoom puts it back, a grid's last cell is the bottom right and
  a cell past the grid is refused, a size under `minsize` and one over
  `maxsize` stop at them, and as window 0's transient it comes to the
  front with window 0 and hides and returns with it. It ends where it
  began.

- **Rules that do more than place. Done, September 2026.** The
  `workspaces` file is a rules file, `servers/intuition/workspace.odin`.
  A line is a match and `wctl` lines separated by commas, applied when a
  window is named and again when it says what program it is:

      # rules: a match, and the wctl lines it applies
      name=terminal       workspace 2
      title=Debugger*     workspace 3, snap right
      app=view first      snap grid 2 1 0
      transient           raise

  A match is terms that must all hold: `name=` exactly, `title=` a pattern
  where `*` is any run, `app=` the program, `first` no other window of its
  kind up, and `transient` a window with a parent. The program arrives as
  `app` on `wctl`, which `cmd/window` writes from the command's name and
  `sys/libmui` from the process's name in its `/proc/N/status`; the
  window's `ctl` report says it, after the geometry. A line in the old form, a name
  and a number, still reads as `name=` and `workspace`. A rule's own lines
  never apply rules again. The check is in `verify_pointer`: the kernel
  gives the server a `home`, writes a rules file there and a `reload`, and
  a title pattern snaps the window right, the program's first window snaps
  it left and makes it current, and a zoom puts it back.

- **Chords whose action is any `wctl` word. Done, September 2026.**
  `chord_act` in `servers/intuition/keys.odin` keeps the chord-only words,
  `close`, `cycle`, `zoom`, `back`, `workspace`, `next`, `prev`, `send`,
  `overview` and now `mode`, and gives anything else to `run_wctl` on the
  window in front. So `alt-s snap left` works, and a word added to `wctl`
  is bindable the day it exists. What `wctl` refuses still goes to the
  desktop on `hotkey`. The move and size grammar is settled by sign: a
  number with a sign is relative and a bare one absolute, axis by axis,
  so the shipped nudges read `move +0 -16`.

  The four shapes are in the keys file:

      mode resize alt-r 1500      # alt-r enters, 1.5 s of no key leaves
      [resize] left  size -16 +0  # a key in the mode, no modifier
      repeat alt-equal  size +32 +0   # again on the keyboard's repeat
      release alt  menu           # a modifier tapped alone, on release
      alt-button1  drag move      # a mouse bind; `drag size` too

  A key typed in a mode reaches no window: `kbdfs` sends a key's `c`
  message before its `k`, so the mode takes the characters in the `c`
  path, `mode_key`. Escape, or a key the mode does not bind, leaves it,
  and so does the timeout, measured at the next key. The mode lamp, a
  tenth under the nine workspace lamps, is copper and lit while a mode is
  on, and the server's `ctl` names it. `alt-button1 drag move` ships. A
  `reload` now reads the keys file again too, which its header always
  said it did.

  The check is in `verify_workbench`, with a shell in front: the kernel
  gives the server a `home` and a keys file with three lines more, and a
  reload reads it. A chord bound to `snap left` snaps the shell and alt-z
  puts it back; alt-r enters a mode the `ctl` names, two plain `l` keys in
  it each move the window eight, and Escape leaves it; and alt with a
  drag in the window's well moves it. `repeat` and `release` are read and
  wired but not yet driven by a check.

- **A screen lock. Done, September 2026.** `lock` on the server's `ctl`,
  Workbench's `Lock` item in its first menu, and the chord `alt-l` put
  `intuition` in a mode, `servers/intuition/lock.odin`, that takes the
  keyboard and the mouse and paints a lock over the whole glass: the void,
  a copper plate, and an amber dot on it for each character typed. No
  window gets a key or a line, no chord acts, and no window's pixels
  show, because `paint_window` and `desk_paint` both answer to the lock.

  Return asks `factotum`, through a new `check user= dom=
  !passphrase=` on its `ctl`. It derives the key and compares its public
  half with the one `factotum` holds for the person, or with their line in
  `/adm/keys` when it holds none, and stores nothing, so a wrong passphrase
  replaces no key. The server takes the person from its `/env/user` and
  `/env/dom`, holds no key and links no crypto, and asks from a thread on
  an io proc of its own while the derivation runs. It mounts
  `/srv/factotum` at `/mnt/factotum` when its namespace lacks it.

  The check is in `verify_pointer`: `factotum` holds Glenda's key and the
  server is told she is the person. `lock` covers the window's well, a `q`
  and a wrong passphrase leave the lock standing, hers takes it down and
  the window comes back, and the window's next line is `z` alone, so the
  `q` never reached it.

- **Theme scopes, and a way to ask. Done, September 2026, the program
  scope.** A role may carry a program's name, `muidemo/face cyan`, and
  that line wins in that program over every unscoped one whatever their
  order: `parse_theme` applies the unscoped lines, then the ones scoped to
  `app_name()`, the same name a window gives the server's rules. The class
  scope, `button.face`, waits for a `Theme` with a value per class; today
  a role is one value for every gadget.

  `libmui.theme_explain` says which line set a role: every line that names
  it in the two files, in the order read, with its file and line, marked
  `wins`, `beaten`, or `another program's`, or `chassis` for a role no file
  names. `THEME_ROLES` is every role the parser knows, and three that had
  a value and no role got one: `hot`, `link` and `dim`. `cmd/style` is the
  query: `style` prints each role's winning line, and `style explain ROLE
  [APP]` every line, as that program sees it.

- **A preferences window generated from the theme's keys. Done,
  September 2026.** `apps/prefs` is a toolkit window of every role in
  `THEME_ROLES`, each with its value now and the line that set it, so a
  role added to the parser is a row with no line of `prefs` changed.
  `Reload` reloads the draw server and reads the rows again. It shows,
  and the files are edited by hand; `style explain` says the rest.

  The checks are in `verify_muiwin`: a theme with `face copper` and
  `muidemo/face cyan` paints the demo's face cyan; `tests/style.rc` reads
  `style explain face` as the demo, where the scoped line wins and the
  other two are beaten, and as `style`, where it is another program's and
  copper wins; and `prefs` opens a toolkit window of its own.

- **Frames and backgrounds by name. Done, September 2026.** The theme file names a desktop ground once and
  picks one, `servers/intuition/theme.odin`:

      desk grid   grid  slate_deep void 32   # pattern, ground, line, step
      desk plain  plain slate_deep
      desk dots   dots  slate_deep slate 16
      desk.ground grid

  `desk_paint` lays the pattern the theme picked, grid, plain or dots, and
  the overview's tiles wear its ground. A `reload` lays it again under
  every window. `/lib/theme` ships the three and picks the grid, which is
  the look the chassis always had. The check, in `verify_muiwin`: a theme
  that defines `desk flat plain copper` and picks it turns the desktop
  copper, and with the file gone the grid comes back.

  A frame's metrics are the theme's too, `frame.edge`, `frame.title` and
  `frame.well`, which is brick 1 of step 6. `sys/libmui` placed its client
  area by the server's inset constants, copied. So the window's `wctl` line
  now ends with the frame's four insets: left, top, right and bottom.
  `libmui.window_locate` reads them when a program turns a point in its
  window into one on the screen, for a popup or a drop. A reload that
  changes the frame keeps every client area's size and pixels, and the
  window grows round it, `window_reframe` in `servers/intuition`. The
  check is in `verify_muiwin`. The chassis says `5 25 5 5`. A theme with
  `frame.title 30` makes the top inset 35 and the window ten rows taller.
  The client area keeps its size, and the demo's face sits ten rows lower
  under a copper bar. With the file gone the chassis frame comes back.

### Step 6: the chrome study

`docs/CHROME.md` is the plan, and its section 14 is the order. The first
three bricks come first and in that order, because the rest paint through
them:

1. The server says a window's frame insets on `wctl`, and the copied
   `FRAME_INSET` constants go. This is step 5's "frames by name". Done,
   September 2026.
2. Schemes: `colour` lines, the job roles, four scheme files, and a
   contrast check in `lint`. Done, September 2026.
3. `sys/libraster`, and the toolkit painting its window's store in place
   of the per-face atlas.

After those come the four faces and the frame with its halo,
`docs/DRAW.md` section 19. Then the menus, the icons, readouts and LEDs,
the dock and the top bar, the preferences pages, and the column viewer.
None of it is built.

## 8. Decisions taken here, and what would reverse them

- **A window per program, `rio`'s way, not a toolkit that owns the
  screen.** A MUI program is a client of `/srv/draw` like the terminal.
  A desktop that drew every program's gadgets itself would be one
  process holding every program's state. That is the shape three
  documents of this tree left behind.
- **Menus are popups the program draws**, not a strip the server
  draws. The server draws chrome and nothing else, and a menu is not
  chrome. The reversal is a server that takes a menu description, which
  is a seventh verb's worth of protocol. `docs/CHROME.md`'s docked
  main menu keeps the rule: the program draws it, and the server only
  places a window of the kind `menu`.
- **One keys file, three readers, one grammar.** The server acts on the
  window manager's words and forwards the rest on `hotkey`. A toolkit
  program's hotkeys are its labels'. A second grammar for launches
  would be a second file to teach.
- **The look is a file, and the default is the chassis.** A theme that
  names nothing is `docs/DRAW.md` section 12. A program that named a
  colour would be the bug. Step 6 moves the default to the study's neon
  scheme, and the chassis stays as `use magnesium`.
- **Icons by kind, not by file.** A `stat` says what a thing is. The day
  a person wants a picture of their own is the day a `$home/lib/wb/icons`
  tree exists, and it does not change the kind rule.
- **Workspaces, not screens.** The Amiga's screens were a way to have
  several modes at once on hardware that could show one. This glass has
  one mode and enough pixels. What a second screen gave is a second set
  of windows, and that is a number on a window. The reversal is a
  second glass, which is a second framebuffer and a compositor that
  paints two, and nothing here forecloses it.
- **A rule is on a window's name.** The server knows nothing else about
  a program, and the name is what a person reads on the bar. A rule on
  a program's path would need the server told who claimed a window,
  which is a field on `new` that nothing else wants. Step 5's richer
  rules plan that reversal, as an `app` word on `wctl` rather than a
  field on `new`. A rule on the program is now something a person asks
  for.
- **Only plain motion may be coalesced (planned, step 5).** A mouse line
  that changes the buttons is an event, and a line that only moves the
  pointer is a sample. A client that misses a sample loses nothing,
  because the next one says where the pointer is. A client that misses a
  press loses a click. The reversal is none.
- **The overview is the compositor's, and scales by skipping.** A
  smoother picture is a filter over the stores, which is a day's work
  the day someone minds. No program redraws for it, which is the point.
- **The desktop is on all three now.** The `virt` boards have no 8042, so
  their keyboard and mouse are virtio-input devices a driver turns into the
  scancodes and packets the `kbd` and `mouse` drivers already take; see
  `docs/PORTS.md`. `window` from the serial line still works too.
- **No drag and drop in step 4**, for section 6's reason.
- **A notice's action is a verb, not a shell.** The text a notice
  carries came from somewhere the desktop does not control. A verb
  whose argument is the rest of the line cannot be made to run it. The
  reversal is none.
- **The theme is merged, not chosen.** A personal file that replaced
  the shipped one wholesale would lose every role the next theme adds.
  The reversal is a role that must not be overridden, and there is not
  one.
- **A state is a word on a window, not a fact about a program.** The
  server lights a lamp for a word and knows nothing else. A server that
  knew what a ghost was would be a server that knew what a program
  was, and `rio` never did.

## 9. Sizes and order of dependence

    step 1  input        kernel 300, libkbd 300 moved, kbdfs 200       nothing before it
        step 2  pointer      intuition 1,600, libdraw 150                  step 1
    step 3  libmui       libmui 2,500, window 150, tests 400           step 2
    step 4  workbench    workbench 1,900, view 400, init               step 3
    step 5  the rest     each its own                                  step 4
    step 6  chrome       libraster 1,500, intuition 900, libmui 2,000,  step 5's insets
                         workbench 1,500, prefs 600, faces and icons

Step 1's three parts are independent and can proceed at once. Step 3's
`window` needs only step 2 and can come before the toolkit.

## See also

- `docs/DRAW.md` -- the draw server, its windows, its chrome, and the
  keyboard in front, which this builds on and does not change.
- `docs/THREAD.md` -- the library every program here is written on.
- `docs/KBD.md` -- the keyboard driver, and the translation this moves.
- `docs/DEVFS.md` -- the taps, the console device, and the `ctl`
  convention `wctl` keeps.
- `docs/INIT.md` -- what the boot starts, which step 4 changes.
