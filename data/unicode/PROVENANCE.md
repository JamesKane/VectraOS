# Unicode Character Database (part)

Data, not code (principle 29): the files `ucdgen` reads to generate
`text/unicode/lib/generated/Tables.swift`, and the conformance test data. They
keep their own license, the Unicode License v3 (`LICENSE.txt`, copied
from the package), and are unmodified.

| File | sha256 (first 16) | Used for |
|---|---|---|
| `UnicodeData.txt` | 0736451de439ae7b | canonical combining classes and decompositions |
| `CompositionExclusions.txt` | c759b100e9ae8960 | the script-specific and post-composition-version exclusions (UAX #15 §5) |
| `CaseFolding.txt` | a004797658a457be | full case folding (statuses C and F) |
| `NormalizationTest.txt` | 25a50d816764b04a | the conformance test (`tests/unicode`) |
| `GraphemeBreakProperty.txt` | 0839dcb79e4ac639 | grapheme clusters (UAX #29) |
| `WordBreakProperty.txt` | 8dbfa17063e11084 | words (UAX #29) |
| `LineBreak.txt` | ae8cf1970c73f3f1 | line breaking (UAX #14) |
| `DerivedCoreProperties.txt` | 09c928886a178fca | Indic_Conjunct_Break (UAX #29's GB9c) |
| `EastAsianWidth.txt` | a0cf29eacd00cfca | line breaking's East Asian width conditions (UAX #14) |
| `emoji-data.txt` | 80d00f8e616a0ef2 | Extended_Pictographic (UAX #29, UAX #14) |
| `SpecialCasing.txt` | 8538dea57c184f1e | full uppercasing (the UI Kit's uppercase labels: its unconditional mappings) |
| `GraphemeBreakTest.txt` | b0cf047ee94485bb | the conformance test (`text/unicode/tests`) |
| `WordBreakTest.txt` | 3dd70c0717812760 | the conformance test |
| `LineBreakTest.txt` | fd9ff9eca4110800 | the conformance test |
| `LICENSE.txt` | e7a93b009565cfce | — |

From Fedora 44's `unicode-ucd-18.0.0-2.fc44` (`/usr/share/unicode/ucd`), which
packages Unicode 18.0.0 from unicode.org (the break properties and tests from its
`auxiliary/`, `emoji-data.txt` from its `emoji/`). Copied 2026-10-09; the
segmentation files and `SpecialCasing.txt` 2026-10-12. To update:
copy the new files over, record their version and hashes here, regenerate
(`CLAUDE.md`, "Generated outputs"), and run the conformance test.
