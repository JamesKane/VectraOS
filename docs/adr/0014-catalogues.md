# ADR-0014: Publisher catalogues for package dependencies

Status: accepted, 2026-10-02. Provisional with 06: rewritten against the code when packages arrive (M6 onwards).

## Context

Installing a package resolves its dependencies (06 §3.4). Resolution needs to know which versions of a package exist, and which have been withdrawn, so something has to list them. The usual answer is a registry (npm, PyPI, crates.io): one service that owns a global name space of packages and serves every version of each.

D13 and ADR-0003 refuse registries, for the build: they bring dependency trees too deep to audit, typosquatting, maintainer takeover, and build scripts that run on the build machine. Those harms are not specific to builds. A registry that `distd` consults at install time would bring the same ones to every user's machine, with install-time scripts in place of build scripts. Rule 13 leaves what users install to them, but a resolution mechanism that ships in the base system is the platform's choice, not the user's.

So the question is whether resolution can find versions without a registry, and without reintroducing any of its harms.

## Decision

**A catalogue is one publisher's signed list of its own packages.** It is an ndb file (D14) plus a detached Ed25519 signature over its exact bytes, made by the publisher's key:

```
catalogue publisher=ed25519:a1c3… seq=118 expires=2027-06-01T00:00Z
package=lua         version=5.4.7  record=b2:5e02… vx-abi=1,2
package=lua         version=5.4.8  record=b2:c771… vx-abi=2
package=tree-sitter version=0.24.3 record=b2:0f9a… vx-abi=2
revoked package=lua version=5.4.6 reason="parser overflow, CVE-…"
```

- **It lists only packages signed by its own key.** `distd` refuses a catalogue that names a record under any other key, and checks every record it fetches against both the catalogue's hash and the publisher's signature.
- **There is no shared name space.** A package is known by (publisher key, name), everywhere: in manifests, in locks, in catalogues and on screen. Two publishers can both have a package called `lua`; neither can satisfy a dependency on the other's.
- **The system ships no catalogue and trusts no publisher by default.** A publisher's key is trusted only once the user has said yes to it, at the first install that needs it (06 §3.3). No host is authoritative for any catalogue. It is fetched from the same sources as everything else (06 §6.1), and the signature makes the source irrelevant.
- **Resolution reads only the catalogues of keys the graph names.** It never searches, never follows a name to a publisher, and never asks one catalogue about another publisher's packages.

**Each harm of a registry, and what stops it here:**

| Harm | Answer |
|---|---|
| Typosquatting | Dependencies name a key, not just a name. A look-alike name under another key matches nothing |
| Maintainer takeover | A publisher's key is pinned. A new key is accepted only if a catalogue signed by the old key names it (`successor=ed25519:…`), or if the user says yes to it as a new publisher. A stolen key is still a stolen key: installed apps do not move, because they run from their locks, and `app update` shows every changed version before the user accepts it |
| Install-time code | **A package has no install-time code**: no hooks, no scripts, no post-install step. Installing stores a tree and writes a lock. Whatever a package needs to do, it does when the app runs, inside the app's namespace |
| Dependency trees too deep to audit | The user sees the whole graph before anything is fetched: every package, version, size, publisher and namespace grant (06 §3.4). `app why` shows why any package is there. Per-app resolution means a library pulled in by one app is confined to that app's namespace |
| A replayed old catalogue hides a revocation | `seq` only increases, and `distd` keeps the newest it has seen per key. After `expires`, the catalogue is still used, but the app's status and `/dist/status` say it is stale and revocations may be missing. The publisher chooses the expiry, so its key can stay offline between releases |
| A hostile catalogue or manifest | Sizes are bounded before parsing. The parsers are in `lib/vx-dist`, built for the host and fuzzed like the system's other parsers (04 §7) |

**ADR-0003 is unchanged.** The build never reads a catalogue, and `third_party/` stays the only way outside code enters the repository or a release. No base release depends on a package. Catalogues govern only what a user chooses to install in their own user land.

**Discovery is out of scope.** Catalogues answer "which versions of this publisher's package exist", not "which packages exist". How a user first finds an app is open (06 §16).

## Consequences

- `distd` gains catalogue fetching, checking and caching. `/dist/catalogues/<key>/` serves each one it holds, with its signature and `status` (`seq`, `expires`, `stale`).
- A publisher needs one key and a way to serve two files. Any 9Px server, swarm node or HTTPS mirror will do; the system provides `./build catalogue --sign <key>` to write one.
- A package whose publisher stops renewing its catalogue keeps working from its lock. It is flagged stale, not removed.
- ADR-0003 gets a note that its scope is the build and the base release, and that installed packages are governed here.
