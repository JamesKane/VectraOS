# D112. The clipboard: Radharc holds one entry of typed representations; `/dev/snarf` is its text; reads only from the focused window on input; drag and drop carries an entry of its own (2026-10-18, decided; details proposed; the entry, snarf and the read rule built 2026-10-19; extends D75, D85, D107)

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

## Built (2026-10-19)

The entry, `snarf`, `clip` and `clip/new`, and the read rule, as
proposed, with these settled in the building:

- **Where the files are.** No window has a namespace of its own until
  the SDK and rio (step 3), so the files are in every client's tree,
  `/svc/windows/snarf` and `/svc/windows/clip`, and the read rule is
  the client's: a read succeeds for the client that owns the focused
  window, once that window has been given a key or a press since it
  was focused. The scene keeps the rule (`given`, cleared whenever
  focus moves). The SDK and rio will bind these files at `/dev`.
- **A refused read fails with `denied`.** Node's per-channel streams
  could only answer a read with bytes, nothing yet, or the end, so a
  channel's `take` may now throw (one change to the stream mechanism,
  not a new one). `clip`'s listing, which can't fail, holds only `new`
  for a client that may not read, so a walk to a representation isn't
  found.
- **A copy, in Radharc's memory.** The entry's bytes are held in
  Radharc's heap rather than a VMO: nothing maps them yet, and reads
  are by the read rule, which a mapped file couldn't apply.
- **Committing.** `clip/new` checks each line as it comes, so a bad
  line fails its write; the entry commits on close only if it ends
  where a representation does. Node can't tell a close from a writer
  killed, so a writer killed between two representations commits the
  ones it finished. `snarf` closed without a write changes nothing
  (Node has no open modes to say it was opened for writing), so
  nothing empties the clipboard. At most 16 representations an entry,
  and a line at most 1 KiB.
- **Names.** A representation's file is its type without parameters,
  lower case, `/` as `.`; two of one name in an entry are refused.
- **The secret entry's 30 seconds** run on a thread of their own,
  started at the commit; the clipboard is also checked at each read.

Not yet: drag and drop, which needs the window's `drag` file and the
`dragOver` and `drop` events, both the SDK's (step 3); the shell's
`clipboard` service and its history (step 4).

## Built in step 3 (2026-10-19)

- **The SDK's `Snarf`** reads and writes the text and the entry. It
  doesn't bind Radharc's files at /dev: a bind opens a file once and
  shares that channel, and `snarf` keeps its state per channel. It uses
  /dev's where the namespace has them (rio's, in a rio window) and
  Radharc's at /svc/windows otherwise.
- **UICore's fields and text areas** cut, copy and paste
  (Control-X, C and V) through a clipboard the platform gives the UI;
  KitPlatform gives the SDK's. A secure field never gives its text, so
  no secret entry comes from it yet.
- **rio passes the files to its windows.** Each window's `snarf` is read
  under the rule for that window (focused, and given a key or a press
  since), and its writes commit on close; its `clip` is Radharc's,
  mounted, so it follows Radharc's rule for rio as a whole. rio's menu
  has Plan 9's Cut, Paste, Snarf and Send beside the Route.
- **Drag and drop, as proposed.** A client's `drag` file takes the
  entry, and starts the drag when it closes, from the client's window
  whose content the left button pressed and still holds. Radharc's
  Window protocol (version 5) has `dragOver`, `dragLeft`, `drop` and
  `dragEnded`, and `acceptDrag` for the answer; the SDK's names are the
  same, with `Drag.start` and `Drag.read`. What is dropped is read from
  the client's `drop` files until the window's next key or press (a
  release isn't one: the drop's own release would end it). Escape
  cancels. The badge beside the cursor is filled in the focused tab's
  colour where the drag would be taken. Kit's views don't use it yet.
