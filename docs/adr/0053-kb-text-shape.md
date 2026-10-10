# ADR-0053: kb_text_shape v2.28e, vendored unchanged, to segment and shape text

Status: proposed, 2026-10-09. The import's code review is still to be recorded (`VENDOR.ndb`, `reviewed.by=pending`).

## Context

Between UTF-8 and glyphs is shaping: kerning, ligatures, contextual forms, marks, and for most of the world's scripts much more (docs/21 §2 item 10, D13). HarfBuzz is the reference, at about 250 kLOC of C++. kb_text_shape is one C header (31.6 kLOC, most of it Unicode and OpenType tables) by Jimmy Lefevre, under the zlib licence, that segments text (direction, script, line, word and grapheme breaks) and shapes it with every OpenType shaper; it needs no C library.

## Decision

- **kb_text_shape v2.28e**, from `github.com/JimmyLefevre/kb` at commit `cc63806` (2026-10-02), is vendored unchanged under `third_party/kb_text_shape`: `kb_text_shape.h` and the repository's `LICENSE`. Licence: Zlib.
- **Provenance.** The repository publishes no releases or checksums; the files are from a fresh download at that commit over HTTPS (2026-10-09). When reviewing, compare them with a second fetch. (A copy in Odin's vendor tree is v2.21; upstream's is taken.)
- **The build** is the font port's (`ports/font`, ADR-0052): `kbts.c` defines `KB_TEXT_SHAPE_NO_CRT`, its memory functions to the compiler's builtins and its allocator to `lib/vx-font`'s, and includes the header unchanged.
- **What VectraOS uses**, through `lib/vx-font` only: a font from memory, one shaping context per font, and `kbts_ShapeUtf8` into runs of glyphs with advances and offsets. Mixed-direction paragraphs and line breaking come with `vxui`'s text layout.
- **Only the system's fonts**, as for stb_truetype: the library says it gives no security guarantee on untrusted fonts.

## Consequences

- Upgrading is replacing one header with a later commit's; its API has changed between minor versions (`kbts_ShapeContext` replaced older entry points), so an upgrade is a step of its own.
- The header's declarations are seen by programs that draw text as system headers; its implementation is compiled once, in the port.
- The code is not under the house rules; `./build check` does not lint it.
