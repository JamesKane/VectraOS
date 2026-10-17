# D89. Crypto is todhchai's whole library, checked against 9front's libsec on the host (2026-10-17, decided; extends D70)

V3's network lifts todhchai's crypto (N1, D77) for Noise IK, factotum's
key and Taisce's checksums. todhchai checked it against OpenSSL on the
host, a third-party library that D4 leaves no place for: it is no
compiler, and its output is no artifact of ours. D70 already gives the
pattern for an oracle: 9front's own code, vendored unchanged on the host,
whose output is a verdict.

- **The whole library is lifted** (`TDCrypto` at todhchai `527ff94`):
  BLAKE3, MD5, SHA-256, SHA-512, ChaCha20 and Poly1305 (both nonce
  forms), ChaCha20-Poly1305, OpenSSH's ChaCha-Poly, X25519, Ed25519, HMAC-SHA-256, PBKDF2 and
  `constantTimeEqual`, with their published test vectors and provenance.
- **The oracle is 9front's libsec**, the files those primitives need,
  vendored unchanged from 9front's `front` at `228167f32` with its
  licence and IMPORTS.tsv rows, and a header of ours mapping Plan 9's
  types to Linux's in place of libsec's `os.h`. It is a SwiftPM C target
  that only the crypto tests link; it never reaches the device (D4).
- **The tests are differential:** seeded random inputs through both,
  which must give the same bytes, beside the published vectors. The
  oracle's own known answers are checked first, so a wrong shim fails
  as the oracle, not as ours.
- **Without a libsec counterpart,** Ed25519 and BLAKE3 (libsec has
  BLAKE2s) are judged by their published vectors alone: RFC 8032 and
  Wycheproof, and BLAKE3's own.

Rejected: OpenSSL (D4); the 9front VM, as D70 rejected it for rc (a serial
console to drive, slow and single-client); and vectors alone, which
miss what no vector exercises.
