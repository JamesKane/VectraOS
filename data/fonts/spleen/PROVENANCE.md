# Spleen 2.1.0

Data, not code (principle 29): the bitmap font of the framebuffer console
(M3j), chosen 2026-10-10. `fontgen` reads the BDF files and writes
`services/console/lib/generated/Spleen.swift`, which keeps Spleen's license, the
BSD 2-Clause license (`LICENSE`, copied from the release), and its
copyright notice; it is not relabelled BSD-3-Clause. The files are
unmodified.

| File | sha256 (first 16) | Used for |
|---|---|---|
| `spleen-8x16.bdf` | b2b05484ba4380c9 | the console's font (8×16 cells) |
| `spleen-16x32.bdf` | 3b6ae73ef1dd3c78 | the console's font on large framebuffers (16×32 cells) |
| `LICENSE` | 3cb3f3f5a795547d | — |

From the release tarball `spleen-2.1.0.tar.gz`
(https://github.com/fcambus/spleen/releases/tag/2.1.0, sha256
8b47c56f1a6eb858fbcf9e34530557404b02fbb3455e38e64fb84473fd0c372f), by
Frederic Cambus. Copied 2026-10-10. To update: copy the new BDF files and
LICENSE over, record their version and hashes here, and regenerate
(`CLAUDE.md`, "Generated outputs").
