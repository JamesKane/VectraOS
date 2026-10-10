# ADR-0052: stb_truetype v1.26, vendored unchanged, to rasterize glyphs

Status: accepted, 2026-10-10, after review by James Kane (proposed 2026-10-09).

## Context

M7 draws text: window titles and the trusted prompt now, `vxui` and the terminal next (docs/21 §2 item 10, D13). A glyph's outline has to become pixels. The candidates are FreeType (about 100 kLOC for what is needed, with an autohinter and many formats), and stb_truetype (one 5 kLOC public-domain header, TrueType outlines, antialiased rasterization at any scale and subpixel offset, no hinting). 03 asked for a 1x check before the choice is final: small text at terminal sizes against a reference rendering.

## Decision

- **stb_truetype v1.26** (its latest release, 2021), from `github.com/nothings/stb` at commit `2c980bb` (2026-08-02), is vendored unchanged under `third_party/stb_truetype`: `stb_truetype.h` and the repository's `LICENSE`. Licence: MIT or public domain (the Unlicense); VectraOS takes it under MIT.
- **Provenance.** stb publishes no releases or checksums; the files are from a fresh download at that commit over HTTPS (2026-10-09). When reviewing, compare them with a second fetch of the same commit.
- **The build** is the font port's (`ports/font`, shared with kb_text_shape, ADR-0053): `stbtt.c` defines the header's hooks to `lib/vx-font`'s (its heap; floor, ceil and sqrt exactly; pow, fmod, cos and acos well enough for the signed-distance-field functions, which nothing calls) and includes it unchanged, compiled with the native programs' freestanding flags into `libfont.a`. The host's tests build it the same way under the sanitizers (`// host-links: font`).
- **What VectraOS uses**, through `lib/vx-font` only: `stbtt_InitFont`, the scale for a size, and `stbtt_MakeGlyphBitmapSubpixel` at quarter-pixel offsets into the glyph atlas.
- **Only the system's fonts.** stb_truetype does not defend against a malformed font (a junk file crashes it, which the host test found), so only fonts from the boot image's `/lib/font` are loaded. A font an application supplies waits for a loader that validates it first.

## The 1x check (2026-10-09)

`host/font1x` (font1x(8)) rasterizes the same glyphs at the same pen positions and quarter-pixel offsets with stb_truetype and with FreeType 2.13 (the host's), at 11 to 16 pixels to the em, Inter 4.1 (ADR-0054). The mean coverage difference against unhinted FreeType is 2.0% to 2.9%; against light-hinted FreeType (most Linux desktops' setting), 4% to 12%, because hinting snaps the x-height and stems to whole pixels. By eye stb_truetype and unhinted FreeType cannot be told apart; light hinting is a little crisper vertically. Unhinted rendering is accepted for proportional UI text. The terminal's font, which must be monospaced (Inter is not), is chosen at its step (7f), with the check run again on it.

## Consequences

- Upgrading is replacing one header with the next commit's.
- Text is unhinted. If a terminal font needs hinting at 1x, that is a question for 7f, not a reason to take FreeType now.
- The code is not under the house rules; `./build check` does not lint it.
