# Crypto

Our cryptography, from published specifications (architecture §17,
principle 29).

## What there is

`TDCrypto` (`crypto/lib`, tier 0, compiled `-O` in every build):

| | From | Used by |
|---|---|---|
| `BLAKE3` | the BLAKE3 specification | Taisce's block checksums (first 128 bits) |
| `MD5` | RFC 1321 | FLAC's STREAMINFO signature (integrity only, never security) |
| `SHA256` | FIPS 180-4 | HMAC, PBKDF2 |
| `SHA512` | FIPS 180-4 | Ed25519, SSH's exchange hash (N1a) |
| `ChaCha20`, `Poly1305` | RFC 8439 (both nonce forms: the RFC's, and the original 64-bit one SSH uses) | the AEADs below |
| `ChaCha20Poly1305` | RFC 8439 §2.8 | (TLS, later) |
| `OpenSSHChaChaPoly` | OpenSSH's `PROTOCOL.chacha20poly1305` | sshd's cipher (N1c) |
| `X25519` | RFC 7748 §5 (the ladder, swaps by mask), over `Field25519` | SSH's key exchange (RFC 8731) |
| `Ed25519` | RFC 8032 §5.1 (cofactorless verify, S < L enforced), over `Edwards25519` and `Scalar25519` | SSH's host and user keys (RFC 8709), the keyring's signing (N1c) |
| `HMACSHA256` | RFC 2104 | SCRAM (the keyring, M6k) |
| `PBKDF2.sha256` | RFC 8018 §5.2 | SCRAM's Hi |
| `constantTimeEqual` | | comparing tags and proofs: never compare secrets with `==` |

## Testing

Test vectors are data with provenance, unmodified: `data/blake3`,
`data/nist-cavp` (CAVP's SHA-256 and SHA-512 short and long messages and
the Monte Carlo tests), `data/wycheproof` (Wycheproof's HMAC-SHA-256,
PBKDF2-HMAC-SHA-256, ChaCha20-Poly1305, X25519 and Ed25519, valid and
invalid cases). `crypto/tests` runs all of
them, computes the algorithms' constants again from their definitions,
feeds inputs in pieces across the padding's boundaries, and compares with
the host's OpenSSL on random inputs (`crypto/oracles/openssl`, a C shim
linked only into the tests; `TODHCHAI_CRYPTO_CASES=N` runs N cases
instead of 300). `tests/embedded/CryptoSmoke.swift` checks one vector of
each in the Embedded build.

`Field25519` (mod 2^255 - 19, X25519's and Ed25519's) is five 51-bit
limbs whose 128-bit products come from `multipliedFullWidth`: tier 0
links no compiler-rt, and a 128-bit multiply could become a call to
`__multi3` (checked: no `*ti3` symbol in the objects on any arch).
Ed25519's points are extended coordinates with the complete addition;
a scalar multiple reads its 4-bit windows' table by masks over all 16
entries. Its scalars mod L are 64-bit words reduced by Barrett's method;
`crypto/tests` checks them against a long division.

Still to come for the riskiest code (§17): a timing harness for constant
time in CI, and an external review before anything ships TLS.
