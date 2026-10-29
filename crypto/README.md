# Crypto

Our cryptography, from published specifications (principle 28, D4,
D89), lifted from todhchai.

## What there is

`TDCrypto` (`crypto/lib`, tier 0, compiled `-O` in every build):

| | From | Used by |
|---|---|---|
| `BLAKE3` | the BLAKE3 specification | Taisce's block checksums (first 128 bits) |
| `SHA256` | FIPS 180-4 | HMAC, PBKDF2 |
| `SHA512` | FIPS 180-4 | Ed25519 |
| `ChaCha20`, `Poly1305` | RFC 8439 (ChaCha20 four blocks at a time in SIMD4's lanes, as BLAKE3's chunks) | the AEAD below |
| `ChaCha20Poly1305` | RFC 8439 §2.8 | Noise IK's cipher (cpu's transport, D77) |
| `X25519` | RFC 7748 §5 (the ladder, swaps by mask), over `Field25519` | Noise IK's exchange; factotum's `proto=noise-ik` key |
| `Ed25519` | RFC 8032 §5.1 (cofactorless verify, S < L enforced), over `Edwards25519` and `Scalar25519` | (signing, later) |
| `HMACSHA256` | RFC 2104 | Noise IK's HKDF; PBKDF2 |
| `PBKDF2.sha256` | RFC 8018 §5.2 | (passwords, later) |
| `constantTimeEqual` | | comparing tags and proofs: never compare secrets with `==` |

A primitive comes with its first user, in that change, checked as D89 says (D138).

## Testing

Test vectors are data with provenance, unmodified: `data/blake3`,
`data/nist-cavp` (CAVP's SHA-256 and SHA-512 short and long messages and
the Monte Carlo tests), `data/wycheproof` (Wycheproof's HMAC-SHA-256,
PBKDF2-HMAC-SHA-256, ChaCha20-Poly1305, X25519 and Ed25519, valid and
invalid cases). `crypto/tests` runs all of
them, computes the algorithms' constants again from their definitions,
feeds inputs in pieces across the padding's boundaries, and compares with
9front's libsec on random inputs: every primitive but Ed25519 and BLAKE3,
which libsec lacks (D89). The oracle is `crypto/oracles/9front`: libsec's
files unchanged (9front `228167f32`, MIT), `os.h` (Plan 9's types on
Linux) and `oracle.c`, linked only into the tests, never the device.
`OracleTests.swift` puts libsec through the same published vectors
first, so a fault in the shim fails there. `TODHCHAI_CRYPTO_CASES=N` runs
N random cases instead of 300. `user/test/swift/CryptoSuite.swift`
checks one vector of each in the Embedded build, on each arch (boot-smoke).

`Field25519` (mod 2^255 - 19, X25519's and Ed25519's) is five 51-bit
limbs whose 128-bit products come from `multipliedFullWidth`: tier 0
links no compiler-rt, and a 128-bit multiply could become a call to
`__multi3` (checked: no `*ti3` symbol in the objects on any arch).
Ed25519's points are extended coordinates with the complete addition;
a scalar multiple reads its 4-bit windows' table by masks over all 16
entries. Its scalars mod L are 64-bit words reduced by Barrett's method;
`crypto/tests` checks them against a long division.

Still to come for the riskiest code: a timing harness for constant
time in CI, and an external review before anything ships TLS.
