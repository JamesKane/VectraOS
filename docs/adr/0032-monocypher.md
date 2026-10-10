# ADR-0032: Monocypher 4.0.3, vendored unchanged, for the content store's hashes and release signatures

Status: accepted, 2026-10-06 (proposed 2026-10-04). The import was reviewed by James Kane on 2026-10-04 (`VENDOR.ndb`).

## Context

M5 step 9 builds the content store (06 §4). Its objects are named by BLAKE2b-256, and release records will be checked with Ed25519 (06 §5, from M10). 06 §14 puts the import here, at the first use of either, rather than at M10. Writing cryptographic primitives ourselves is out of the question. Monocypher is small (about 3.5 kLOC with the optional Ed25519 file), portable C99 with no dependencies but `<stddef.h>` and `<stdint.h>`, audited (Cure53, 2020), and constant-time by design. Its BLAKE2b is the same function Limine uses for module hashes (01 §10), so the system has one hash function.

## Decision

- **Monocypher 4.0.3**, the latest release (2026-06-15, which fixes a timing leak in EdDSA signing), from `github.com/LoupVaillant/Monocypher`, is vendored unchanged under `third_party/monocypher`. Kept (`subset=`): `src/monocypher.{c,h}`, `src/optional/monocypher-ed25519.{c,h}` (SHA-512 and Ed25519 as RFC 8032 has them; the core's EdDSA uses BLAKE2b instead), and the licence, authors and changelog. Left out: the documentation, the tests and the build files. Licence: BSD-2-Clause or CC0-1.0, the user's choice; VectraOS takes it under BSD-2-Clause.
- **Provenance.** The release publishes no checksum and no signature. The tarball's sha256 is from a fresh download over HTTPS (2026-10-04). When reviewing, confirm it against a second fetch, and compare the kept files with the release's git tag.
- **The build** is `./build`'s, from `ports/monocypher/port.ndb`: a native port, compiled once per architecture with the native programs' freestanding flags into `libmonocypher.a`, which `distd` and `install` link, with its headers as system headers so the house warnings stay the house's. The host's tests and `host/vxstore` compile the same two files for the host, each as its own object with its own flags.
- **What VectraOS uses**, and only through `lib/vx-store` and, later, the record checks: `crypto_blake2b` (and its incremental form) for object names; `crypto_ed25519_check` for signatures from M10. No key is generated or held on a node by this import; `keyd` (M10) is where node keys live.

## Consequences

- Upgrading is replacing the seven files with the next release's.
- Monocypher's code is not under the house rules (04 §1.1); it builds with its own flags and `./build check` does not lint it, as for ACPICA, musl and Lua.
- Nothing here signs: releases stay unsigned until M10 (06 §14), and `./build release` says so.
