# ADR-0055: JetBrains Mono 2.304, the terminal's font, vendored unchanged

Status: accepted, 2026-10-10, after review by James Kane (proposed 2026-10-10).

## Context

Inter (ADR-0054) is proportional; the terminal (M7 step 7f) needs a monospaced font, which ADR-0054 left to this step. It must be free to bundle, cover what a terminal draws (ASCII, Latin, box drawing, block elements), read well at 12 to 16 pixels without hinting (stb_truetype hints nothing, ADR-0052), and come as static TrueType.

Candidates: JetBrains Mono (OFL-1.1), Go Mono (BSD-3-Clause, by Bigelow & Holmes, Lucida's designers, whose Lucida was Plan 9's font), IBM Plex Mono (OFL-1.1), DejaVu Sans Mono (Bitstream Vera licence).

## Decision

- **JetBrains Mono 2.304** (2023-01-14), the latest release, from `github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip`, sha256 `6f6376c6…7bbf`, is vendored unchanged under `third_party/jetbrains_mono`: `OFL.txt` and `fonts/ttf/JetBrainsMono-Regular.ttf` and `-Bold.ttf` (`subset=`). Licence: OFL-1.1, as Inter's.
- **Why it.** Drawn for code at small sizes: a tall x-height, open shapes and distinct `0O`, `1lI`; full box drawing and block elements; static TrueType. 03's 1x check (font1x(8), 2026-10-10): within 2.3% to 3.3% of unhinted FreeType at 11 to 16 pixels, Inter's range. Go Mono's licence and lineage are the better story, but it is a slab serif, wider and lighter at small sizes, and further from the desktop's NeXT and SGI look than a grotesque mono beside Inter.
- **Provenance.** GitHub publishes no digest for the asset; the sha256 is from a fresh download over HTTPS (2026-10-10). When reviewing, confirm it against a second fetch.
- **In the image** at `/lib/font/JetBrainsMono-Regular.ttf` and `-Bold.ttf`, put there by `make_bootfs`; the terminal draws in Regular, bold text in Bold.

## Consequences

- Swapping the terminal's font is this record and two files: the terminal names it in one place.
- The OFL allows bundling and redistribution with the system; the fonts may not be sold alone, which the system never does.
