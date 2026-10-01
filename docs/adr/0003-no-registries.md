# ADR-0003: No package registries

Status: accepted, 2026-09-30.

## Context

Registries (crates.io, npm, PyPI and the like) give dependency trees too deep to audit, typosquatting, maintainer takeover, and build scripts that run on the build machine (D13).

## Decision

- Outside code enters only as pinned, reviewed source under `third_party/`, one ADR per import, with a `VENDOR.ndb` record giving upstream, hash, licence, reviewer and patches (04 §3.1).
- `build` reads only the repository and never fetches anything. CI builds with no network.
- Code generators in an import's upstream build run once, when it is vendored; their output is committed and reviewed.
- When two imports compete, the smaller one that can be audited wins.

## Consequences

`./build vendor-check` enforces this in CI and as a pre-commit hook.
