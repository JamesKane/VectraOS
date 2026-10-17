# NIST CAVP test vectors: SHA-256 and SHA-512

Data, not code (principle 29): the Cryptographic Algorithm Validation
Program's byte-oriented SHA-256 and SHA-512 vectors, which `crypto/tests` checks
ours against (every short and long message, and the Monte Carlo test).
They are works of the US government, in the public domain, and unmodified.

| File | From | sha256 (first 16) |
|---|---|---|
| `SHA256ShortMsg.rsp` | csrc.nist.gov, CAVP `shabytetestvectors.zip` | 75e1cb8399463848 |
| `SHA256LongMsg.rsp` | the same archive | 6fac36f37360bcf7 |
| `SHA256Monte.rsp` | the same archive | 29ea30c6bb4b84e4 |
| `SHA512ShortMsg.rsp` | the same archive (fetched 2026-10-14; its SHA-256 files identical to those above) | e53a36c03609e5a3 |
| `SHA512LongMsg.rsp` | the same archive | b1f3f05d5c209777 |
| `SHA512Monte.rsp` | the same archive | 8ca78659286c2f01 |

Fetched 2026-10-13 from
https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip.
The implementations (`crypto/lib/SHA256.swift`, `SHA512.swift`) are ours,
from FIPS 180-4.
