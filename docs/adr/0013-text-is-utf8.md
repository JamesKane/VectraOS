# ADR-0013: Text is UTF-8, handled in runes

Status: accepted, 2026-10-02. Makes explicit what 00 §1's "Plan 9 evolved" assumed. Changes how exit strings and notes are cut (ADR-0010), the names 9P servers and vx-ns accept, and the line editors in `ptyd` and `lib/vx-driver/cons.c`.

## Context

In Plan 9, all text is UTF-8, and code that looks inside text steps through it a rune at a time. libc has `Rune`, `UTFmax`, `Runeerror`, `chartorune`, `runetochar`, `fullrune`, `utflen`, `utfrune` and `utfecpy`. The kernel cuts strings only at rune boundaries (`kstrcpy`). `validname` decodes every path the kernel is given, and refuses control characters in it. Erasing a character in the console removes a whole rune.

VectraOS never wrote this down. The pieces that exist do not agree:

- **Validation.** `lib/vx-ndb` validates UTF-8 strictly, and writes anything else as `x"hex"`. That validator is private to ndb, and no other code in the OS can step through UTF-8. `rune.c` exists only in the host-side u9fs (ADR-0006).
- **Exit strings and notes.** ADR-0010 says they are UTF-8. But the kernel's `task_kill`, vx-rt's `vx_exit_str`, `vx_note_put` and `gsh` cut them at 128 bytes, wherever that falls. A reason cut in the middle of a rune becomes invalid UTF-8, and `/proc/N/wait` then shows it as hex.
- **Line editing.** `ptyd` and the serial console erase and kill a byte at a time. Typing `é` and erasing it leaves the byte `0xC3` in the line, for the program to read, and the echo moves the cursor back two columns for one character.
- **Names.** vx-9p's server refuses only empty names, `.`, `..`, `/` and NUL. A file can be created whose name holds a newline or invalid UTF-8. namespace(6) text is one line per entry, so a path holding a newline can neither be printed nor replayed. That text is what `vx_ns_print` writes and `nsd` publishes (ADR-0009).
- **Undefined terms.** 03 §5.1 gives a key event "the unmodified rune" without defining a rune.
- **The POSIX side.** musl has multibyte support, but no locale has been chosen for VectraOS and nothing tests one.

Byte streams are not the problem: pipes, files, 9P data, `cat` and `echo` pass bytes through unchanged, and should go on doing so.

## Decision

- **Text is UTF-8.** Text means every string that crosses a kernel, 9P or file boundary as text: names, paths, exit strings, notes, `ctl` messages, ndb, namespace(6) and the console. File contents and pipe data are bytes, and are never checked.
- **The rune.**
  - `vx_rune` is C23's `char32_t`.
  - The constants keep Plan 9's names, with the house prefix: `VX_UTFMAX` 4, `VX_RUNESELF` 0x80, `VX_RUNEERROR` U+FFFD and `VX_RUNEMAX` 0x10FFFF.
- **Decoding is strict, and never fails.** These are invalid: an overlong form, a surrogate (U+D800–U+DFFF), anything above U+10FFFF, and a truncated sequence. Each decodes to `VX_RUNEERROR` and uses up exactly one byte, as Plan 9's `chartorune` does. So a decoder always makes progress, and valid text after a bad byte still decodes. Code that has to *refuse* bad text calls the validator instead. These are ndb's rules today, and they become everyone's.
- **`lib/vx-utf/utf.h`.**
  - Header-only, defining no external symbol, so the kernel, vx-rt, the servers and `cmd/` can all include it, as they do `lib/vx-note`.
  - Plan 9's set: `vx_chartorune`, `vx_runetochar`, `vx_runelen`, `vx_fullrune`, `vx_utflen`, `vx_utfrune` and `vx_utfrrune`.
  - What VectraOS needs as well:
    - `vx_utf_valid`.
    - `vx_utf_cut`: the longest prefix of at most n bytes that ends at a rune boundary.
    - `vx_utf_back`: where the rune before an offset starts.
  - ndb drops its own validator for this one.
  - Rune classes (`isalpharune` and the rest) and case mapping are left out, because nothing needs them yet. They come with the first program that does, generated from a pinned copy of the Unicode Character Database.
- **Strings are cut only at rune boundaries.** Every bounded copy of text uses `vx_utf_cut`: exit strings, notes, `$status` and names copied into fixed buffers. The kernel cuts, as `kstrcpy` does, but does not validate. Readers already handle bad bytes: `procfs` writes the exit string through ndb, and `x"…"` shows them. So the kernel does no more work than it must.
- **Names are UTF-8 with no control characters.** A path component must be valid UTF-8, holding no byte 0x01–0x1f or 0x7f. This is Plan 9's `validname`, made strict about UTF-8. Two places enforce it:
  - **vx-ns**, on every path a program gives it, before any walk, as Plan 9's kernel checks every path it is given. A refused name is `VX_ERR_INVALID`. The musl back end checks a path with the same rule first and reports `EILSEQ`, because it cannot tell this `VX_ERR_INVALID` from the others.
  - **vx-9p's server**, on every name in `Twalk`, `Tcreate` and `Trenameat`, so a server is safe from clients that do not use vx-ns. `vx-tar` applies the same rule to the boot image's paths.

  A server that presents a foreign file system, such as u9fs serving a Linux tree, can hand back names that break the rule. Such a name cannot be walked through vx-ns. It can be listed, because a directory's contents are data. So a namespace never holds a control character, and namespace(6) text needs no escape for one.
- **Line editors work in runes.**
  - `ptyd` gains Linux's `IUTF8` input flag (`0040000`), on by default as it is on Linux terminals today. With it set, erase removes one whole rune, and echoes one `\b \b`. Kill does the same rune by rune.
  - The serial console behaves as if `IUTF8` were always set, as Plan 9's console does.
  - Neither ever splits a rune when its line buffer is full: the last whole rune that fits ends the line.
  - Display width, such as two columns for wide CJK characters, is not handled. It belongs to the desktop's text layout (03), and a terminal counts one column per rune until then.
- **`gsh` reads names as rc does.** A variable name may hold any byte from 0x80 up, as well as `[A-Za-z0-9_]`. A line longer than the buffer is refused whole, and never run in pieces.
- **POSIX programs get C.UTF-8.** Where `LANG` and `LC_*` are unset, `setlocale(LC_CTYPE, "")` gives musl's C.UTF-8, with `MB_CUR_MAX` 4. VectraOS sets no locale variable of its own. A program that never calls `setlocale` keeps the byte-based `"C"` locale that POSIX requires.
- **Source and literals.** Source files are UTF-8, and clang's execution character set is UTF-8, so a plain `"é"` is already UTF-8 bytes. House code never uses `u8"…"`. In C23 its type is `char8_t[]`, and it does not pass as `char *`. ADR-0005's subset gains this rule.

## Consequences

- One rune library serves the kernel, the native userland and ndb. POSIX programs keep musl's own.
- ADR-0010's promise holds: an exit string or a note is valid UTF-8 whenever what its writer gave was. And `/proc/N/wait` shows `x"…"` only for bytes that were bad before any cut.
- `nsd` and `vx_ns_print` can rely on paths holding no newline. A namespace's text replays exactly.
- POSIX `open` and `mkdir` refuse a name with a control character or invalid UTF-8 (`EILSEQ`). Linux allows such names, so a ported program that makes them will fail here, by design, as it would on Plan 9.
- Tests:
  - `tests/host/utf_test.c`, covering every boundary of the encoding.
  - A fuzz target for the decoder and validator.
  - vx-9p server tests for refused names.
  - A `cons.ndb` case: type `é`, erase it, press return, and check what the program reads.
  - A ptyd case under ctest.
  - ctest checks of `setlocale`, `mbrtowc`, `mbrtoc32` and `EILSEQ`.
- Docs:
  - 00 §1 states that text is UTF-8 and points here.
  - 03 §5.1's rune is a `vx_rune`.
  - ADR-0005 gains the `u8""` rule.
