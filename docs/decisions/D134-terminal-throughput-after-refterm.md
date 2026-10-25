# D134. Terminal output is measured as throughput as well as latency, and vt keeps its scrollback as encoded bytes laid out when shown, after Casey Muratori's refterm: a throughput budget first, then the reader, the scrollback with reflow and an ASCII fast path, each step kept only if the budget shows it was needed (2026-10-25, proposed; for the owner's review; extends D46, D97, D123)

D123 judges the terminal by latency: a key's draw (`terminal.key_draw`,
< 1 ms) and the frames until it is on the glass. Nothing judges how fast
a terminal takes in a program's output, which is what `cat` of a large
file, a build's log or a test run's output costs. That is the problem
refterm was written about.

refterm (github.com/cmuratori/refterm, read at 8a560d4) is Casey
Muratori's reference terminal renderer, written in 2021 after he found
Windows Terminal slow and Microsoft answered that a faster one would be
a research project. Its README calls it the *minimum* speed a reasonable
terminal should reach, not a goal: unoptimized, it took about 6 s to
show a 1 GB file, and after one optimization about 0.6 s; Windows
Terminal took about 330 s. Its FAQ (`faq.md`) explains where the time
went. refterm is GPL-2, so we take ideas only; no code is lifted, and
nothing goes in `IMPORTS.tsv`.

## What refterm does

- **No man in the middle.** Windows puts conhost between a console
  program and its terminal. Measured, conhost cost about 10× through
  stdio's small text-mode writes, and only about 10% when a program
  made large writes. What cost was the number of times a write crossed
  over, not how many bytes it carried.
- **The scrollback is the bytes the program wrote.** Output is read
  straight into a circular buffer, which is mapped twice in a row so
  that a wrap reads as one span. A line is only its first and last
  offsets in that buffer, the text attributes in force at its start,
  and a bit that says it holds bytes ≥ 0x80. Each frame re-parses only
  the lines on the screen into cells. Reflowing on a resize therefore
  costs nothing: the next frame lays the same bytes out at the new
  width.
- **Reads drain everything waiting.** The pending count is read once,
  and all of it is read into the scrollback in one read.
- **A 16-byte scan finds what matters.** Before parsing, each 16-byte
  block is compared against `\n` and ESC, and against the high bit. A
  line with no byte ≥ 0x80 skips Unicode segmentation.
- **ASCII is direct; everything else is hashed.** Printable ASCII goes
  straight to fixed glyph tiles. Any other run is hashed by its input
  bytes (before shaping) and looked up in an LRU table of tiles, so the
  slow shaper and rasterizer (Uniscribe and DirectWrite) run once for
  each new cluster.
- **The screen is one grid drawn in one pass.** Each cell is a glyph
  tile, a foreground and a background. A pixel shader draws the whole
  grid, so a change of colour costs nothing. Windows Terminal was
  slowest with many colours because it called DirectWrite once for
  each run of one style, which could be once a character.

## Where we stand

What we already do:
- **No middleman.** There is no pty (D77). rc opens `/dev/cons` itself
  (D97). vt reads the program's stdout ring directly.
- **A write crosses only when the reader sleeps.** A byte-stream ring
  (D46) rings its doorbell only for a sleeping reader. While both sides
  are busy, a write is a copy and a store.
- **An escape sequence split across reads is safe.** TerminalCore's
  parser is a state machine that keeps its state between reads.
  refterm has a known bug here (its TODO in `ParseLines`).
- **Parsing and drawing are separate.** vt feeds what it read to the
  screen before each frame, and builds a frame only when something
  changed.

Where we differ, and might pay for it:
- **Every line of stdout is a ring write.** The floor's stdout
  (`system/sys/floor/Stdout.swift`) flushes at each newline, and at 216
  bytes, whatever stdout is. It cannot tell a terminal from a file or a
  pipe. A slow producer and a fast reader can therefore cost a doorbell
  and a thread wake for each line. Nobody has counted them.
- **Each read allocates twice.** vt's reader gets each read back as a
  new `[UInt8]` (`shell/vt/Main.swift:123`). `deliver` then appends it
  to `incoming` under a lock (`shell/vt/app/Terminal.swift:64`), and
  the screen copies it again into cells.
- **The scrollback is laid-out cells.** It is `[[Cell]]`
  (`shell/vt/core/Screen.swift:69`). A `Cell` holds two scalars, a
  width, two `TerminalColor`s and its attributes, about 28 bytes by its
  layout. Each row is an array of its own, and the oldest rows go
  through `removeFirst`. At the 10,000-line limit, a 200-column window
  keeps about 56 MB, where refterm would keep about 2 MB. Rows are kept
  at the width they had when they scrolled away, which is vt(1)'s BUGS
  entry: "no reflow of wrapped lines on a resize".
- **Text is shaped each time it is drawn.** The glyph atlas
  (`text/atlas/lib/Atlas.swift`) caches rasterized glyphs by font,
  glyph ID and size, after shaping. vt's snapshot keeps the runs of rows
  that didn't change (M6m). A changed row is shaped again, even when
  its clusters were seen a moment ago.
- **The screen is drawn as runs of one style.** vt draws through Kit as
  runs of one style, row by row. A screen full of colour changes means
  many short runs.
- **rio's window keeps its text as scalars.** It is UICore's
  `TextDocument`: four bytes a character, 10,000 lines. Everything
  before the output point is only ever appended to, which is the case
  refterm's model is for.

None of these has been measured as a cost. So the first step is the
measurement, and each later step is kept only if the measurement shows
it is needed.

## Proposed

1. **A throughput budget, with its check.** vt-test's child, run by
   boot-vt, gains a phase that writes 16 MB through stdout in thirds:
   - plain ASCII lines;
   - lines that change SGR every few characters;
   - lines of wide (CJK) characters and combining marks.

   vt reports:

   ```text
   budget name=terminal.throughput.ascii value=... unit=MB/s
   budget name=terminal.throughput.sgr value=... unit=MB/s
   budget name=terminal.throughput.unicode value=... unit=MB/s
   budget name=terminal.wakes_per_mb value=... unit=count
   ```

   The time runs from the first byte read to the frame that shows the
   last one. rio-test does the same for a plain window
   (`terminal.throughput.window`, the plain ASCII third only, through
   rc's `cat`).

   Times are judged under KVM in the profile that D123's budgets use,
   with no new bench profile. Under TCG they are reported, not judged.
   The target is refterm's unoptimized floor: about 170 MB/s of plain
   ASCII (1 GB in 6 s). The limits are set from the first recorded run
   on a quiet machine. They are never set in the change that would fail
   them.

2. **Wakes are counted before stdout's buffering changes.** If
   `terminal.wakes_per_mb` shows a wake per line, the fix is in the
   reader: vt's reader thread waits for the next frame instead of the
   doorbell while the program is writing, and drains the ring then. The
   screen is fed only at a frame anyway. The writer
   keeps its line flushes, because interactive output must show at
   once. Full buffering when stdout isn't a terminal waits until there
   is a way to tell (no `isatty` over a ring today). That would be a
   design of its own.

3. **vt reads into one buffer.** The reader reads into a buffer it
   owns, not a new array each time. The screen is fed from a span of
   that buffer, under the lock that `incoming` holds today. No new
   mechanism is added: this is the ring's `read_bytes` into memory
   that already exists.

4. **vt's scrollback is encoded rows, laid out when shown.** When a row
   leaves the top of the primary screen, it is encoded once:
   - its text as UTF-8;
   - its SGR changes as runs (offset and attributes);
   - a *wrapped* bit, which autowrap sets on a row that continues on the
     next, as xterm tracks it.

   The rows go in one growable byte store with an index of offsets.
   Like refterm's lines, an index entry is an offset, a length, the
   attributes at the start and a has-non-ASCII bit. The oldest rows go
   by advancing a start offset, and the store is compacted when half of
   it has gone. It is not a circular buffer mapped twice, which would
   need a VMAR mapped at a fixed address for a gain we haven't
   measured.

   Rows with the wrapped bit are joined into logical lines and wrapped
   again at the view's width when shown. That is the reflow vt(1)'s
   BUGS lacks.

   This departs from refterm in one place. vt is an xterm, and a row is
   built by cursor moves, not by appending. So the scrollback keeps
   each row as it was when it left the screen, not the bytes the
   program wrote. The live screen stays a grid of cells.

   The limit becomes bytes (8 MB) instead of 10,000 lines. The page
   changes in the same change: its BUGS entry goes, and its
   DESCRIPTION gives the limit.

5. **An ASCII fast path in TerminalCore.** Before parsing, a pass over
   16-byte blocks (`SIMD16<UInt8>` over a span, in the parser's own
   file, because generic SIMD conversions don't inline across files)
   finds the next control byte (< 0x20 or 0x7F) and the high bit. The
   bytes before it go to `putASCII` in one call. This is the screen's
   own input, not pixel work, so it is not a D129 kernel and has no
   tiers. On rv64, which has no vector extension at RVA22, it is the
   scalar loop.

Steps 3 to 5 each land with the throughput figures before and after,
compared interleaved (`vx bench --compare`). A step that doesn't move
its budget is dropped, not merged.

## Tests

- TerminalCore's host tests (`shell/vt/tests/`):
  - scrollback encoding round-trips text, attributes, wide characters
    and combining marks;
  - reflow joins wrapped rows and only those, and re-wraps them at a
    narrower and a wider width;
  - the byte limit drops whole rows, oldest first;
  - the ASCII scan gives the same screen as the byte-at-a-time parser
    on random input with escapes split at every offset.
- boot-vt: the throughput phase's output appears in full, and its last
  line is on the screen. It is a mechanism check, not a timing one.
- `docs/risk.tsv` gains no row: these tests are in the targets vt's
  paths already map to.

## Budgets

The five in step 1. Their check is vt-test's and rio-test's phase. They
belong to V5's open items in `docs/roadmap.md`, judged when those items
close.

## Pages

None in this entry. Step 4 changes vt(1) (its scrollback limit and its
BUGS), and step 2 would change rc(1) or the floor's page if stdout's
buffering ever changes.

## Not chosen

- **A tile renderer for vt**, drawing the grid in one GPU pass as
  refterm's shader does. It would be a second way to draw text beside
  Kit's and the composer's (principle 1). It is reopened only if
  `terminal.throughput.sgr` misses its limit and a profile puts the
  cost in the runs.
- **Keeping the program's raw bytes as scrollback**, as refterm does.
  It is right for output that only appends, and wrong for an xterm
  whose rows are built by cursor moves. refterm itself only
  approximates cursor addressing.
- **A cache of shaped clusters keyed by input bytes.** The atlas
  already saves rasterizing. Shaping again is cheap for the scripts we
  ship, and a second cache needs a reason in a measurement first.
- **Full stdout buffering now.** Without a way to tell a terminal from a
  ring, it would delay interactive output.

## Not yet

- **rio's window text as bytes before the output point.** It is the
  case refterm's model fits exactly, and would make the window's 10,000
  lines about a quarter of their size. It waits for
  `terminal.throughput.window` to show that the window, and not the
  program, is the bound.
- **Telling the program of a resize** (vt(1)'s other BUGS entry). It is
  unrelated to throughput, and noted here only because reflow makes a
  resize more common.
