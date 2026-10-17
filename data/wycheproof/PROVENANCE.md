# Wycheproof test vectors: HMAC-SHA-256, PBKDF2-HMAC-SHA-256, ChaCha20-Poly1305, X25519, Ed25519

Data, not code (principle 29): Project Wycheproof's vectors, which
`crypto/tests` checks our algorithms against, valid and invalid
cases alike (truncated tags, edge-case keys and lengths). They keep their
own license (`LICENSE`, Apache 2.0, copied from the same commit) and are
unmodified.

| File | From | sha256 (first 16) |
|---|---|---|
| `hmac_sha256_test.json` | github.com/C2SP/wycheproof, commit 7a325932231bd7a724c791c8b0d65ea4d6d2f435, `testvectors_v1/hmac_sha256_test.json` | 2d201cfa61d1bf95 |
| `pbkdf2_hmacsha256_test.json` | the same commit, `testvectors_v1/pbkdf2_hmacsha256_test.json` | 1bf37af2cefe40c8 |
| `chacha20_poly1305_test.json` | the same commit, `testvectors_v1/chacha20_poly1305_test.json` (fetched 2026-10-14, N1a) | fe61d25f90e1bde4 |
| `x25519_test.json` | the same commit, `testvectors_v1/x25519_test.json` (fetched 2026-10-14, N1a) | 35c3f5231cf25cc6 |
| `ed25519_test.json` | the same commit, `testvectors_v1/ed25519_test.json` (fetched 2026-10-14, N1a) | 752d2ea7d7c6cf47 |
| `LICENSE` | the same commit, `LICENSE` | 58d1e17ffe5109a7 |

Fetched 2026-10-13. The implementations (`crypto/lib/HMAC.swift`,
`crypto/lib/PBKDF2.swift`, `crypto/lib/ChaCha20.swift`,
`crypto/lib/X25519.swift`, `crypto/lib/Ed25519.swift`) are ours, from
RFC 2104, RFC 8018, RFC 8439, RFC 7748 and RFC 8032; no code was taken
from the repository.
