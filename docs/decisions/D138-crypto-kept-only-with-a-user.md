# D138. A crypto primitive is kept only with a user: MD5 and OpenSSH's ChaCha-Poly go (2026-10-25, decided; amends D89)

D89 lifted todhchai's whole crypto library, each primitive checked
against 9front's libsec. Two have no user, and none planned: **MD5**
(`crypto/lib/MD5.swift`, with libsec's `md5.c` and `md5block.c` as its
oracle) and **OpenSSH's chacha20-poly1305** (`OpenSSHChaChaPoly`, and
the original 64-bit-nonce ChaCha20 it alone needs). The crypto README
says as much: SSH isn't lifted (D77). Only the crypto tests and
CryptoSuite call them. The owner's stance is crypto on demand
(2026-10-17).

- **MD5 and OpenSSH's ChaCha-Poly go,** with their tests, CryptoSuite's
  checks of them, the 64-bit-nonce `xor` if nothing else calls it, and
  the oracle files only they use (their IMPORTS.tsv rows go too).
  ChaCha20 with RFC 8439's 96-bit nonce, Poly1305 and the AEAD stay.
- **A primitive is lifted with its first user,** in that change, with
  its oracle or published vectors as D89 requires. MD5 comes back only
  for a protocol that mandates it, never for a new design.
- D89's list of what was lifted becomes what is kept: BLAKE3, SHA-256,
  SHA-512, ChaCha20 and Poly1305, ChaCha20-Poly1305, X25519, Ed25519,
  HMAC-SHA-256, PBKDF2 and `constantTimeEqual`. Its oracle and its
  differential tests are unchanged.

Rejected: keeping the whole library as lifted (about 750 lines of code,
oracle and tests that are kept right for nothing); dropping the oracle's
files but keeping the primitives (D89: nothing ships unchecked).

Covers: crypto/lib, crypto/oracles/9front, crypto/tests, crypto/README.md,
user/test/swift/CryptoSuite.swift, IMPORTS.tsv, D89's list. Tests: the
crypto host tests and the boot that runs CryptoSuite.
