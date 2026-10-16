# D13. Host tools under SwiftPM, images under CMake (2026-10-15, decided in V0)

This settles D11's open question. SwiftPM (`Package.swift`) builds `vx`,
the host libraries (Bench, TraceFormat, TraceReader) and their tests.
CMake builds the loader, kernel and user images, one tree per arch. The
two never build the same target, and `vx` drives both, so this is still
one way to build.

- **`tools/bench.py` is removed.** `vx bench` replaces it, judged by
  todhchai's `Judge`. The two duplicated each other (principle 1).
- **History units.** `bench/history/brimstone.tsv` was converted from
  nanoseconds to seconds, the unit Judge uses.
- **Limits.** The kernel's exclusive `limit=L` is read as Judge's inclusive
  `L - 1` (in ns or the count).
