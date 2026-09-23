# Edit: sam's language, acme's files, and a rope behind them

**Written before the code.** Nothing in this document is built. The
tree has no editor, and three plans wait for one: the `edit` class of
`docs/GHOST.md`, the plumber's `edit` port, and the debugger's source
panel. This is the editor all three wait for.

The program is `edit`, in the manner of `window`, `view` and `ask`. It
is one program in three layers. At the bottom is a text that never
changes in place. In the middle is `sam`'s command language over that
text. On top are a window a person types into and a tree the ghost and
a script drive.

**What a person sees.** `plumb pong.odin:31` opens a window on the file
with line 31 selected. The window has sam's command pane on top and a
pane per file under it. `,x/TODO/c/DONE/` in the command pane changes
every TODO in the file, and `u` puts them back. The ghost's `find` and
`replace` land in the same window while the person watches. A keystroke
between the ghost's plan and its edit makes the edit stale.

## 1. What is taken, and from where

**From `sam`, the language.** Rob Pike's structural regular expressions,
with addresses that name a range of text and commands that act on it.
`x/re/` loops over every match, `y/re/` over the text between, and
`g` and `v` guard a command on a match. That is a small language that
says more than any set of named verbs. It is the editor's `dict` in one
line, and a model that knows sam writes it well.

From sam also the split between the half that holds the text and the
half that draws it, which here is procs, section 6.

**From `acme`, the files.** Every window is a directory under
`/mnt/acme`, with `body`, `addr`, `data`, `tag`, `ctl` and `event`. A
program that writes them drives the editor, and `win`, `Mail` and
`acme-lsp` are all programs of that kind. Here that tree is
`docs/GHOST.md` section 5's contract, and a window's directory sits
under it.

**From plan-neo's `docs/editor.md`, the engine.** plan-neo is a sibling
project, a Plan 9 in C, and its editor plan costs a modern editor
honestly. Five of its ideas are taken whole. A B-tree rope with a
summary in each node, and edits that leave the old version whole. Undo
as a stack of roots, and workers that get a snapshot and tag their
results with its version. And the rule that only input and drawing run
between a key and its glyph.

Its `cmd/agentedit` is the contract in 399 lines of C. It gives `seq`
on every reply, `if_seq` on a change, and a reply with the new dot. Its order of tree-sitter first and LSP second is section 7.

**From this tree.** `sys/libmui` for the panes, the scrollbar, the
command line and the requesters, and `sys/libthread` for the procs and
channels. `sys/libedit` for the erase keys, so `^W` means one thing in
every text field. `sys/libfont` for the glyphs. `sys/libregex` for the
patterns, with the captures `docs/GHOST.md` step 2 gave it. And the
window store of `docs/DEVTOOLS.md` section 4, a run of shared pixels
the editor paints and flushes one rectangle at a time.

**Not taken.** sam's and acme's C, because both sit on `libframe` and
Plan 9's `/dev/draw`, and the draw server here is `intuition`. acme's
executed text in the tag, for now. A plugin host, modal keys, and
collaboration through CRDTs. plan-neo's GPU renderer seam, which waits
for `docs/HARDWARE.md`'s GPU, section 9.

## 2. The models this refuses, and what each got wrong

**The editor as a plugin host.** An extension API is a second surface
beside the one for people, and the two drift, `docs/GHOST.md` section 2.
Here a script and the ghost reach the editor through files.

**Highlight by regular expression.** A syntax file of patterns colours
most of a file and fails on a string with a quote in it or a comment
inside code. A parser knows where a string ends. Tree-sitter parses an
edit in the time a pattern file takes to rescan a line.

**A language server on the same machine, or nothing.** The servers that
exist are large programs on another system's runtime. None runs here
today, and waiting for one would leave the client unwritten. So the
client is written first, and it reaches a server on another machine.

**A frame rate from a GPU.** A typing frame changes one line, 1920
pixels by 16, which is 123 KB and 7 MB a second at sixty frames. What
makes an editor slow is work on the key's path, and section 6 keeps the
path clear.

## 3. The text: a rope that never changes in place

The text is a B-tree of chunks. A leaf holds up to 1,024 bytes of UTF-8,
and an inner node up to sixteen children. Each node carries the summary
of its subtree.

    Summary.bytes     bytes under this node
    Summary.lines     newlines under this node
    Summary.runes     code points under this node
    Summary.maxcol    the longest line, for a horizontal scrollbar

A parent's summary is the sum of its children's. So a line number, a
rune offset and a byte offset are each a descent from the root. `goto
400000` in a large file costs a walk of four or five nodes, not a scan.
An insert or a delete rewrites one path from the root to a leaf.

**An edit makes a new root and keeps the old one.** The new path shares
every other node with the old tree. So a version of the text is a root,
and it is never changed after it exists. Undo is a stack of roots, and
`u` pops one. A snapshot for a worker is a root and a version number,
and the worker needs no lock.

**A node is freed when nothing holds it.** Each node has a count of the
parents and snapshots that hold it, changed with atomic operations,
because workers are procs under `RFMEM`. A root that leaves the undo
stack drops its path, and a node whose count reaches zero drops its
children. The undo stack has a depth in the file's `ctl`, 1,000 by
default.

**Offsets are runes.** sam's `#n` and acme's `addr` count runes, and
the rune summary makes a rune offset a descent. The contract's `q0` and
`q1` are runes for the same reason. A byte offset is one more descent,
for a worker that needs one.

**The dot is a pair of marks.** A mark is a rune offset that an edit
before it moves and an edit after it does not. sam's dot, and the mark
a `k` command sets, are marks.

Proves: a file of 64 MB loads from `kfs`, and `goto` to its last line
answers in under a millisecond. A hundred scripted edits and a hundred
`u` give back the file's bytes. A snapshot taken before the edits still
reads the old text after them.

## 4. The command language

The language is sam's, over `sys/libregex`. An address names a range,
and a command acts on it.

    #n  n  /re/  ?re?  $  .  'm     one address
    a1,a2   a1+a2   a1-a2           two addresses, and a range
    a/text/  i/text/  c/text/  d    append, insert, change, delete
    s/re/text/  m a  t a            substitute, move, copy
    x/re/ cmd   y/re/ cmd           loop over matches, or between them
    g/re/ cmd   v/re/ cmd           run if the dot matches, or not
    { cmd ... }                     a group, in one pass
    p  =  k  u  e  r  w  f  q       print, where, mark, undo, files
    < cmd   > cmd   | cmd   ! cmd   a program's output, input, filter

A command that changes text builds a list of changes against one root.
The list applies at the end of the command, in order, as sam's does. So
`,x/a/c/b/` sees every match in the text as it was, and one `u` undoes
the whole loop.

**`<`, `>`, `|` and `!` run `rc`.** The command runs in the editor's
own namespace, section 8, with the dot's text on its input where the
command wants one. Its output replaces the dot or goes to the command
pane.

Proves: a script of sam commands over a known file gives known text.
The script includes a nested `x` and `y`, a `g` guard, a `{}` group
with two changes, and a `|` through `tr`.

## 5. The tree, and the contract

`edit` serves `/mnt/app/editor` through `libmui`, and adds the verbs of
its own that `docs/GHOST.md` section 5 asks an application for. A
second instance is `editor.2` in `/mnt/app/index`.

    /mnt/app/editor/ctl        the verbs below, a reply per fid
    /mnt/app/editor/dict       the verbs, as the ghost reads them
    /mnt/app/editor/event      open, insert, delete, select, save, done
    /mnt/app/editor/state      the files, the current one, each dot, dirty
                               flags, and seq, one snapshot per open
    /mnt/app/editor/text       the current file's text, one snapshot
    /mnt/app/editor/N/body     file N's text, one snapshot per open
    /mnt/app/editor/N/addr     write an address, read its q0 and q1
    /mnt/app/editor/N/data     the text at addr, and a write replaces it
    /mnt/app/editor/N/tag      the file's name and its dirty flag

A snapshot file is a root, so a read of `body` costs no copy and never
tears. `addr` and `data` are acme's pair, and a program that knows acme
knows them.

    # /mnt/app/editor/dict
    open path               -> win:int          open a file in a new pane
    win n:int               -> path q0 q1       make a pane current
    goto line:int           -> q0:int q1:int    select a line
    select q0:int q1:int    -> text             select a range
    find ?all:bool pattern  -> q0:int q1:int    select the next match
    replace from to         -> count:int        replace in the dot
    insert ?at:int text     -> q0:int q1:int    insert text at the dot
    delete                  -> q0:int q1:int    delete the dot
    sam command             -> q0 q1 output     run a sam command
    undo ?n:int             -> seq:int          undo n changes
    save ?path              -> path             write the current file
    text                    read: the current file's text
    state                   read: the files, the dots, and seq

`sam` is the verb with the reach. Its argument is the rest of the line,
so `sam ,x/TODO/c/DONE/` needs no quotes. The named verbs are the ones a
person would say, and each one is a sam command underneath. `find
pattern` is `/pattern/`, and `replace from to` is `s/from/to/g` over
the dot. So there is one engine, and the named verbs are a vocabulary
over it.

**Every change carries `seq`.** A verb that changes text takes
`if_seq=N`, and the editor refuses it as `stale` when a keystroke, a
command or another script moved `seq`. The verb runs on the window's
event thread, the thread that takes the keys, so nothing lands between
the check and the change.

**The tests are scripts over the tree.** A check opens a file, drives
verbs, and compares `text`, `state` and `event` with the answers it
knows. The same script runs from `rc`, from the ghost, or
through `mcpserve`, so the conformance suite and the automation
contract are one set of files.

Proves: `tests/edit.rc` opens a file from `memfs`, runs a `goto`, a
`find`, a `replace` and a `sam` loop, and reads the text it expects.
A `replace` with the `seq` from before a scripted `insert` answers
`stale` and changes nothing. An `event` reader sees `insert` with the
range the script wrote. And one control, the check of `if_seq` removed,
so the stale `replace` lands and the check fails.

## 6. Procs, and the path from a key to a glyph

**Only input and drawing run between a key and its glyph.** A key
arrives on the window's `cons` in raw mode, through `libmui`'s io proc,
to the event thread. The thread applies the key to the rope, lays out
the changed lines, paints them, and flushes. Parsing, loading, saving,
searching and every language server run in other procs. That is the
one rule in this document that takes no exception.

    ui       keys, the mouse, layout, painting, the flush, the contract's
             verbs, all on libmui's event thread
    io       open, read, save, and a file changed under the editor
    find     a search over a whole file, or over a tree of files
    syntax   an incremental parse of a snapshot, section 7
    lsp      one per language server, JSON-RPC over two descriptors

Each worker is a `libthread` proc under `RFMEM` with a channel to the
ui thread, which `alt`s over the keys, the mouse, and the results.

**A result carries the version it was computed against.** The ui thread
hands a worker a root and its version. The worker answers highlight
spans, matches or diagnostics, tagged with that version. If the text
has not moved, the ui thread uses the result. If it has, the ui thread
maps the result across the edits since, or drops it and asks again.
Highlighting that is one frame stale is the correct failure.

**Painting is the window store.** A text pane paints its lines straight
into the window's shared store, `docs/DEVTOOLS.md` section 4. It then
flushes the rectangle it changed with `intuition`'s `flush x y w h`.
`libfont`'s glyphs are opaque bitmaps today, so a glyph is a copy and
not a blend. The panes' chrome, the scrollbar and the command line are
`libmui` gadgets that draw through the data stream.

Step 0 checks that one window can take both. If it cannot, a text pane
draws through `libdraw`'s verbs, and section 2's numbers say that a
typing frame still fits.

**A long search is a job.** `find all=true` over a large file answers
a job number and posts `done` on `event`, `docs/GHOST.md` section 5.

Proves: an injected key reaches the glass with a flush one line tall,
and `/dev/time` puts the key-to-flush time under one frame. A search of
the 64 MB file runs while the test injects keys, and no key waits more
than one frame. A syntax result for an old version is dropped, and a
control that applies it anyway paints the wrong span.

## 7. Syntax and language servers, in the order they arrive

**Tree-sitter is C, and C is on the build.** The runtime is C99 in about
twelve thousand lines, and a grammar compiles to C source. It enters
through `docs/DEVTOOLS.md` step 0's `c_programs` table, as a library
the editor links. It wants `malloc`, `realloc` and `free` that give
memory back. `sys/libc`'s allocator is a bump today, so the port brings
a free list or links `sys/libposix`'s allocator. The grammars first are
C and Odin.

From one parse tree the editor gets highlighting that knows the
language, a selection that grows by syntax node, an outline, and
bracket matching. The syntax proc holds the tree, applies each edit
from the ui thread to it, and parses again from the new root. None of it
needs a server or a network.

**The LSP client is written first and talks to another machine.** No
language server runs on this system today. `ols`, the Odin server, is
Odin and needs the `vectra` target of `docs/DEVTOOLS.md` section 9 to
run here. So the lsp proc speaks JSON-RPC over two descriptors, and a
line in `$home/lib/edit/lsp` says how to get them.

    # $home/lib/edit/lsp: a language, and the command that gives a server
    odin    cpu -h big -c ols
    c       dial tcp!builder!7658

`cpu` runs the server on another machine in the fleet,
`docs/FLEET.md` section 7, and the server sees the editor's files under
`/mnt/term`. The lsp proc rewrites a `file:` URI across that prefix
each way. The `dial` line reaches a host outside the fleet, where a
bridge runs the server on a socket. Go to definition then works on the
day a server is reachable, and not before, and the plan says so here
rather than later.

Proves: an edit to a 10,000-line Odin file parses again in under a
millisecond on QEMU. The highlighted span for a new string is the
string. An LSP stub, a script that answers `initialize` and one
`definition`, runs over a pipe, and a `goto` to the answer lands. A live
server is a manual check.

## 8. The editor the ghost drives

`docs/GHOST.md` section 4 builds the sandbox with a class file, and the
`edit` class binds `/mnt/app/editor`. The editor that tree names runs
inside the session's namespace, not in the person's. So its `e` and `w`
reach `/n/work` and nothing else, and its `|` runs `rc` with no `/net`.
The ghost cannot leave its sandbox through the editor.

The ghost starts that editor when the session starts. It builds the
class namespace, binds a window's files from its own namespace, and
forks the editor under `RFNOMNT`. The editor serves its tree on a pipe
the ghost holds. The ghost mounts the other end at `/mnt/app/editor`,
which the class then binds into each tool's child.

A person types into that editor's window too, and `if_seq` is the
rule between the keys and the verbs. The person's own editor, outside
any session, is one the ghost never reaches.

## 9. The order

Each step ends with a boot line of scripts over the tree. Each step is
an editor a person can use before the next starts. Step 0 is the
sam-shaped editor, and each step after it replaces a part underneath
without a change to the tree.

### Step 0: sam, on the contract

`apps/edit` with a flat buffer of runes per file, and sam's command
language. A window of one command pane and a column of file panes. The
tree of section 5, the plumber's `edit` port, snarf through
`/dev/snarf`, and `tests/edit.rc`. About 3,600 lines, a medium step.
Needs `docs/GHOST.md` step 2 for `libmui`'s contract, and
`docs/WORKBENCH.md` step 3.

Undo is a list of inverse changes, sam's own design. A pane draws
through `libdraw`'s verbs, and nothing here is a worker.

Boot line: section 4's sam script and section 5's contract checks, with
the `if_seq` control. `plumb pong.odin:31` opens the file with line 31
as the dot.

### Step 1: the rope

`sys/librope`, with the summaries, persistent edits, marks, the
reference counts, and undo as a stack of roots. `apps/edit` moves onto
it. About 1,500 lines. Needs step 0.

Boot line: section 3's checks on the 64 MB file.

### Step 2: the key path and the workers

The store painting and the one-line flush, the io and find procs, the
version tag on a result, and long verbs as jobs. About 1,300 lines.
Needs step 1 and `docs/DEVTOOLS.md` step 1's store.

Boot line: section 6's key-to-flush and search-while-typing checks, and
the stale-result control.

### Step 3: tree-sitter

The runtime and the C and Odin grammars through `c_programs`, an
allocator that frees, the syntax proc, highlighting, selection by node,
and the outline. About 900 lines of this tree's own, beside some
twelve thousand of tree-sitter's C and the generated grammars. Needs
step 2 and `docs/DEVTOOLS.md` step 0.

Boot line: section 7's reparse check.

### Step 4: language servers

The lsp proc, `$home/lib/edit/lsp`, the URI rewrite across `/mnt/term`,
diagnostics in the margin, and go to definition. About 1,400 lines.
Needs step 2 and `docs/FLEET.md` step 4 for `cpu`.

Boot line: section 7's LSP stub. By hand: `ols` on another machine.

### Step 5: the ghost's editor

The session's editor of section 8, started in the class namespace and
mounted from a pipe. About 300 lines across `edit` and
`servers/ghost`. Needs step 0 and `docs/GHOST.md` step 3.

Boot line: a scripted ghost session opens a file in `/n/work` through
the editor and changes it. A `sam e /lib/namespace` through the
same editor answers no such file.

### Deferred, with the reason written down

- **Antialiased text.** `libfont` is bitmap fonts. A scalable font
  makes a glyph a blend, and the blend budget waits for that font.
- **A GPU renderer.** A typing frame at 1920 by 1080 does not need one.
  At 4K a full repaint is two gigabytes a second, and `docs/HARDWARE.md`
  step 5's GPU is the place for it.

## 10. Decisions taken here, and what would reverse them

- **sam's language is the editor's vocabulary, and the named verbs are
  over it.** One engine, so a named verb and a `sam` line cannot
  disagree. The reversal is a verb sam's language cannot say.
- **The tree is `docs/GHOST.md` section 5's contract, with acme's
  window files under it.** So a script, the ghost and a test are one
  client. The reversal is none.
- **The text is a persistent rope.** Undo, snapshots and workers with
  no lock all come from one property. The reversal is a file too large
  for memory. Then the leaves page from the disk, and the tree does
  not change.
- **Offsets are runes.** sam and acme agree, and the rope makes it a
  descent. The reversal is a client that needs bytes, and it asks for
  one more field in the reply.
- **Nothing but input and drawing runs on the key's path, and a
  worker's result may be dropped.** A frame of stale colour is cheaper
  than a lock. The reversal is none.
- **The LSP client reaches another machine first.** Because no server
  runs here. The reversal is `ols` on the `vectra` target, and then the
  line in the lsp file names a local command.
- **The ghost's editor runs in the ghost's namespace.** An editor in the
  person's namespace would be a hole in the sandbox. The reversal is
  none.
- **The first step is sam, not the rope.** A usable editor first, and
  the engine under it after. The reversal is a first step that cannot
  hold a file the bench needs, and then step 1 moves up.

## 11. Sizes and order of dependence

    step 0  sam            edit 2,400, language 800, tests 400        GHOST 2, WORKBENCH 3
    step 1  the rope       librope 1,200, edit 300                    step 0
    step 2  the key path   store 400, procs 600, jobs 300             step 1, DEVTOOLS 1
    step 3  tree-sitter    syntax 600, allocator 300, C ported        step 2, DEVTOOLS 0
    step 4  lsp            client 1,100, config 300                   step 2, FLEET 4
    step 5  ghost's editor edit 150, ghost 150                        step 0, GHOST 3

Steps 1 to 4 change what is under the tree and never the tree.

## See also

- `docs/GHOST.md` -- the contract this editor serves, the `edit` class
  that binds it, and the sandbox its ghost instance runs in.
- `docs/WORKBENCH.md` -- `libmui`, `intuition`'s window files, the snarf
  buffer, and the theme the panes wear.
- `docs/DEVTOOLS.md` -- C on the build for tree-sitter, the window store
  the panes paint, and the debugger that plumbs a source line here.
- `docs/FLEET.md` -- `cpu`, which runs a language server on another
  machine.
- `docs/THREAD.md` -- the procs and channels the workers are.
- `docs/TESTING.md` -- why every check has a control.
