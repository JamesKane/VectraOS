# NIST CAVP test vectors: SHA-256, SHA-512, AES-256 and XTS-AES-256

Data, not code (principle 29): the Cryptographic Algorithm Validation
Program's byte-oriented SHA-256 and SHA-512 vectors, which `crypto/tests` checks
ours against (every short and long message, and the Monte Carlo test), and
its AES-256 known answers (ECB GFSbox, KeySbox, VarKey, VarTxt) and
XTS-AES-256 vectors (the data unit sequence number form).
They are works of the US government, in the public domain, and unmodified.

| File | From | sha256 (first 16) |
|---|---|---|
| `SHA256ShortMsg.rsp` | csrc.nist.gov, CAVP `shabytetestvectors.zip` | 75e1cb8399463848 |
| `SHA256LongMsg.rsp` | the same archive | 6fac36f37360bcf7 |
| `SHA256Monte.rsp` | the same archive | 29ea30c6bb4b84e4 |
| `SHA512ShortMsg.rsp` | the same archive (fetched 2026-10-14; its SHA-256 files identical to those above) | e53a36c03609e5a3 |
| `SHA512LongMsg.rsp` | the same archive | b1f3f05d5c209777 |
| `ECBGFSbox256.rsp` | CAVP `KAT_AES.zip` (fetched 2026-10-30) | 6b0800d4d666d57a |
| `ECBKeySbox256.rsp` | the same archive | 010a648bfc725f0e |
| `ECBVarKey256.rsp` | the same archive | 41026476e854b2e9 |
| `ECBVarTxt256.rsp` | the same archive | 0be3b50f6b3e28e3 |
| `XTSGenAES256.rsp` | CAVP `XTSTestVectors.zip`, its `format tweak value input - data unit seq no/` (fetched 2026-10-30) | 8b72c26e9a940552 |
| `SHA512Monte.rsp` | the same archive | 8ca78659286c2f01 |

Fetched 2026-10-13 from
https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip.
The AES archives are at
https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/aes/KAT_AES.zip
and .../aes/XTSTestVectors.zip.
The implementations (`crypto/lib/SHA256.swift`, `SHA512.swift`, `AES.swift`)
are ours, from FIPS 180-4, FIPS 197 and IEEE 1619.
