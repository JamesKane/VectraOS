# BLAKE3 test vectors

Data, not code (principle 29): the official test vectors `tests/crypto`
checks our BLAKE3 against. They keep their own license (`LICENSE`, CC0 1.0
or Apache 2.0, copied from the same tag) and are unmodified.

| File | From | sha256 (first 16) |
|---|---|---|
| `test_vectors.json` | github.com/BLAKE3-team/BLAKE3, tag 1.5.0, `test_vectors/test_vectors.json` | dcb91ea8accc77e6 |
| `LICENSE` | the same tag, `LICENSE` | — |

Fetched 2026-10-09. The implementation (`crypto/lib/BLAKE3.swift`) is ours,
from the BLAKE3 specification (O'Connor, Aumasson, Neves, Wilcox-O'Hearn,
2020); no code was taken from the repository.
