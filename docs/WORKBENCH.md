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

**Kept as it is.** The chassis: heavy bevels, brushed magnesium over deep
slate, amber and cyan and phosphor, copper on the bar in front. The theme
file's defaults are `sys/libpal`'s table and `docs/DRAW.md`'s chrome. A
user who never edits the file sees the machine the kernel painted at
boot.

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
`/dev/snarf`, and `window` binds it there. A write replaces it and
pushes what was there onto `snarf/history`, ten deep, so a thing cut
over is not lost. An image is a write of a `sys/libdraw` image's bytes,
and a program that reads one gets pixels back.

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
press on a window inside a tile and a release on another tile is the
drag between workspaces. That comes with drag and drop in step 5.

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
    Text        a label, with `_` before the hotkey letter
    Button      a raised panel with a label, pressed on click or hotkey
    Checkmark   a lamp, lit or not
    Cycle       a button whose label is one of a list, and a popup of them
    String      one line of text, `sys/libedit` wearing a well
    Slider      a knob in a well, horizontal or vertical
    List        rows of text in a well, one selected, a scrollbar beside
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
    bar         copper                  # the bar of the window in front
    bar.back    magnesium_dark          # the bar of every other window
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
frame it draws, so a window's chrome and the gadgets inside it are one
look. A theme that names nothing is the chassis.

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

**Icons are kinds, not files.** A directory is a drawer, a file under
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
a well, with a scrollbar. `Clean Up` lays the icons out in rows. A double
click on a drawer opens it. On a tool it runs `window <path>`. On a
project it runs `window view <path>`, or the tool a line in
`/lib/wb/types` names for the file's suffix.

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
die. When the ghost is on, `window` writes `startstop` to its command's
`ctl`, and a fault parks the process before the note lands,
`docs/DEVTOOLS.md` section 7. `window` posts the notice with the trap's
text and `ask -c debug -p N` as the action.

A click hands the parked process to the ghost, which attaches the
debugger and reads `bt`. A
notice dismissed, or ten more behind it, lets the note through and the
program ends as it always did. With the ghost off, the notice says the
program faulted, and nothing waits.

**Drag and drop is deferred.** Moving an icon from one drawer to another
is a `cp` and an `rm`. But the pointer crosses from one window to another
mid-press, and that needs the server to hand a drag between windows. The
server owns the pointer and can. It is a step after this one, with its
own document.

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

Proves, in five checks. The suite starts the desktop and opens `Home` by
an injected double click. It sees a drawer window with the icons
`verify_kfs` left there. It opens a Shell from the menu and types at it
as `verify_terminal` types. It presses the bound chord and counts one
more shell in `ps`. It writes a line to `notice`, reads it back off
`history`, and sees the toast's pixels in the bar's corner.

From the serial line, `window ls` opens a window with a listing in it.
Then `ps` shows the desktop as one proc of threads and its io procs.

### Step 5: the rest of the platform

Each its own document, in whatever order a reason arrives.

- **`virtio-input`** on the `virt` boards, a keyboard and a mouse both, so
  the two ports get the desktop amd64 has. The tree already speaks
  virtio over PCI for the disk.
- **Drag and drop**, with the server handing a drag between windows,
  and a window dragged between tiles in the overview.
- **Snapshot**, an icon's position kept in `$home/lib/wb`.
- **Menus on MUI programs**, with the toolkit's `Menu` on button 3.
- **`state` on `wctl` and the snarf history**, section 4's two late
  additions to a step that is done.
- **A theme switcher** over `/lib/themes`, and the `use` line, section 5.
- **The fault notice**, the day `docs/GHOST.md` step 3 gives the click
  somewhere to go.
- **The relay clicks.** `docs/HANDOFF.md` section 1 promises them, and
  there is no audio device in this system. A `virtio-sound` or an AC97
  is the day.
- **A font past 128 glyphs**, deferred in `docs/HANDOFF.md` with its
  reason. The theme names a font file so that the day has somewhere to
  land.

## 8. Decisions taken here, and what would reverse them

- **A window per program, `rio`'s way, not a toolkit that owns the
  screen.** A MUI program is a client of `/srv/draw` like the terminal.
  A desktop that drew every program's gadgets itself would be one
  process holding every program's state. That is the shape three
  documents of this tree left behind.
- **Menus are popups the program draws**, not a strip the server
  draws. The server draws chrome and nothing else, and a menu is not
  chrome. The reversal is a server that takes a menu description, which
  is a seventh verb's worth of protocol.
- **One keys file, three readers, one grammar.** The server acts on the
  window manager's words and forwards the rest on `hotkey`. A toolkit
  program's hotkeys are its labels'. A second grammar for launches
  would be a second file to teach.
- **The look is a file, and the default is the chassis.** A theme that
  names nothing is `docs/DRAW.md` section 12. A program that named a
  colour would be the bug.
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
  which is a field on `new` that nothing else wants.
- **The overview is the compositor's, and scales by skipping.** A
  smoother picture is a filter over the stores, which is a day's work
  the day someone minds. No program redraws for it, which is the point.
- **The desktop is amd64's until `virtio-input`.** The `virt` boards have
  no keyboard and no mouse, and a desktop nobody can type at is a
  picture. `window` from the serial line works on all three.
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
