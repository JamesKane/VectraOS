# ADR-0054: Inter 4.1, the system's font, vendored unchanged

Status: accepted, 2026-10-10, after review by James Kane (proposed 2026-10-09).

## Context

docs/21 §2 item 10 names one font family for M7: Inter, under the SIL Open Font License. It is designed for screens, has wide language coverage, kerning and OpenType features, and comes as static TrueType files that stb_truetype reads (ADR-0052).

## Decision

- **Inter 4.1** (2024-11-16), the latest release, from `github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip`, sha256 `9883fdd4…b11e`, is vendored unchanged under `third_party/inter`: `LICENSE.txt` and, of the release's static TrueType files, `extras/ttf/Inter-Regular.ttf` and `Inter-Bold.ttf` (`subset=`). Licence: OFL-1.1.
- **Provenance.** GitHub publishes no digest for the asset; the sha256 is from a fresh download over HTTPS (2026-10-09). When reviewing, confirm it against a second fetch.
- **In the image** at `/lib/font/Inter-Regular.ttf` and `/lib/font/Inter-Bold.ttf`, put there by `make_bootfs`. winsrv draws titles in Regular and the prompt's heading in Bold, at 13 pixels to the em.
- **Not the terminal's.** Inter is proportional; a monospaced font for the terminal is chosen at step 7f, with its own record.

## Consequences

- Other weights or Inter's variable font are added to the subset when something needs them; the variable font waits for a rasterizer that reads variations.
- The OFL allows bundling and redistribution with the system; the fonts may not be sold alone, which the system never does.
