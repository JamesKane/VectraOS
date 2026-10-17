# Noise test vectors: cacophony's and snow's

Data, not code (principle 29): the Noise Protocol Framework's shared
vectors, which `services/9gate/tests` replays through our
`Noise_IK_25519_ChaChaPoly_SHA256` (each side's static, ephemeral and
prologue, both handshake messages, then transport messages each way).
Only that protocol's entries are used; the files are unmodified, and
keep their own licences.

| File | From | sha256 (first 16) |
|---|---|---|
| `cacophony.txt` | github.com/mcginty/snow, commit 8ac60f51cfe3e010c84f0a454cc575ad9204fa12, `tests/vectors/cacophony.txt` (Haskell cacophony's vectors) | 3bde7c09a6f349ee |
| `snow.txt` | the same commit, `tests/vectors/snow.txt` | 69da433305fd045f |
| `UNLICENSE-cacophony` | github.com/haskell-cryptography/cacophony, commit 8ee9d41e34a1a596cfa3ab12aa4069ff87dc1247, `LICENSE` (public domain) | 88d9b4eb60579c19 |
| `LICENSE-snow` | snow's commit above, `LICENSE-MIT` | dd6a6177e441f98b |

Fetched 2026-10-17. The implementation (`services/9gate/noise`) is
ours, from the framework's specification (revision 34); no code was
taken from either repository.
