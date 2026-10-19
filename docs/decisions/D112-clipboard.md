# D112. The clipboard: Radharc holds one entry of typed representations; `/dev/snarf` is its text; reads only from the focused window on input; drag and drop carries an entry of its own (2026-10-18, decided; details proposed; extends D75, D85, D107)

D107 settled the shape: the clipboard is Radharc's `snarf`. It is one
file of text in each window's namespace, as rio has it, plus typed
entries after NeoVectra's typed snarf. Radharc holds a copy, so the
clipboard outlives its source, and drag and drop rides the same
entries. The plumber, not the clipboard, carries anything meant to be
acted on. None of the three donors has clipboard code. rio holds the
text, replaces it when the writer's file closes, and caps it at 100
KiB (`MAXSNARF`). NeoVectra's design types the snarf and lets only
the focused window read it. todhchai's desktop.md and the shell
storyboard keep a history in the shell's drawer.

## Decided

- **Only the focused window reads the clipboard, and only on input.**
  The owner chose this (2026-10-18) over rio's rule, in which anything
  with `snarf` in its namespace reads it whenever it likes. Writes
  come from any window.

## Proposed

- **The clipboard is one entry: representations of one thing, each a
  MIME type and its bytes** (`text/plain;charset=utf-8`, `image/png`,
  `text/uri-list` for files). A new entry replaces the old one whole.
  Radharc copies an entry's bytes into a VMO of its own when the entry
  is committed, so the entry outlives the program that wrote it. It
  doesn't survive Radharc's restart.
- **Each window's namespace has `/dev/snarf` and `/dev/clip`.** For an
  SDK window, Radharc serves them; for a rio window, rio serves them
  and passes them on to its own window's, as a nested rio uses its
  parent's.
  - **`/dev/snarf`** is rio's file. A read returns the entry's text.
    Writes are collected, and the collected text replaces the entry
    when the file is closed, as rio's xfid.c does.
  - **`/dev/clip`** is a directory with one file per representation,
    named by its type with `/` written as `.` (`text.plain`,
    `image.png`). Listing it is how a reader learns the types, and the
    reader reads the one it wants. Radharc converts nothing, except
    that `snarf` is the `text.plain` file under another name.
  - **`/dev/clip/new`** takes a whole entry in one write channel. Each
    representation is an ndb(6) line, `type=image/png length=N`,
    followed by its N bytes. The entry replaces the clipboard when the
    channel closes; a channel that fails or is killed commits nothing.
  - An entry is at most 16 MiB in all, and text in `snarf` at most 1
    MiB. Past either, a write fails as too long.
- **The read rule.** A read of `snarf` or of a representation succeeds
  only on a channel from the client of the focused window, after
  Radharc has delivered that window a key or a button press, and
  until focus leaves it. That's long enough for a paste and for rc's
  `cat /dev/snarf` typed in a rio window, but a background app
  watching the clipboard is refused. rio applies the same rule to its
  own windows. A listing of `/dev/clip` follows the same rule, since
  the types say something about the contents.
- **A secret entry.** An entry written from a field the SDK marks
  secret (a password field), with `secret=1` on its first line, is
  cleared 30 seconds after it is committed. It is never recorded in a
  history.
- **Drag and drop is an entry of its own,** so dragging never
  overwrites the clipboard. A window starts a drag by writing an entry
  to its window's `drag` file, in `clip/new`'s format, while a button
  is held. Radharc draws the drag, and the window under the pointer
  hears `dragOver` with the types and answers what it would take. On
  release, the target gets `drop` with the types, and may read the
  drag entry until its next input event. A drop counts as the input
  event the read rule asks for. The events are Radharc's typed protocol
  (D82), with the SDK's names chosen in step 3.
- **History is the shell's,** not Radharc's: the drawer of the shell
  storyboard (frame 07), whose entries are files with `Clip:Source`,
  `Clip:Origin` and `Clip:Time` attributes, with limits on size and
  age per user. Radharc offers a `clipboard` service, granted only to
  the shell, that hears each committed entry that isn't secret
  (step 4).
- **The plumber is not the clipboard.** Pasting moves bytes; plumbing
  (`/mnt/plumb`, D85) asks for something to be done with them. A
  window that wants both sends both.

## Left out

- Primary selection (X11's middle-button paste): one clipboard.
- Lazy representations, where the source is asked for a type only when
  it is read. A copy the source doesn't need to keep alive is what
  "outlives its source" asks for, and 16 MiB is generous for V5.
- A clipboard across machines: the cpu session's `/mnt/term` can carry
  the terminal's later (V3's files), without a design here.
