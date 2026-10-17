# factotum

Every key, and the authentication protocols run with them, after Plan
9's factotum (D75): services pass messages between factotum and their
peers and get results, never a long-term key. It is todhchai's keyring
(services/keyring at 527ff94) under Plan 9's name, its AuthIPC sessions
kept, its prompt left behind: this factotum is headless and refuses a
session that would ask the user (D75). Its page is factotum(4).

## The parts

- `lib/Keys.swift`: keys and patterns in factotum's text, the store and
  its ctl lines (`key ...`, `delkey PATTERN`).
- `lib/Session.swift`: `Factotum.start` gives an `AuthSession` for a
  pattern and a role, stepped with `next` and `feed`; `publicKey` gives
  ed25519's or noise-ik's public half.
- `lib/NoiseIK.swift`: `proto=noise-ik`, Noise IK with the node's key
  (made from the CPRNG on first use) for 9gate (D77): the service feeds
  the handshake's parameters, passes its messages, and gets the
  session's keys.
- `lib/Scram.swift`, `lib/Signer.swift`: `proto=scram-sha-256` and
  `proto=ed25519`, as todhchai's.
- `lib/Protocol.swift`: AuthIPC (`todhchai.auth.Factotum` and
  `AuthSession`; idlc's outputs in `idl`, pages auth-factotum(5) and
  auth-authsession(5)).
- `lib/Server.swift`: `FactotumState`, a tree for each client through the
  launcher's `clients` (`export per-client`, manifest(6)), scoped by the
  client's `grant factotum` lines; `admin` adds `ctl`.
- `Main.swift`: bin/factotum, its randomness the kernel's CPRNG.

Names and values are compared as bytes: String's `==` needs Unicode's
tables, which tier 0 links without.

## Tests

`tests/FactotumTests.swift` and `tests/ServerTests.swift` are
todhchai's: RFC 7677's exchange byte for byte in both roles, a client
factotum against a server one, bad peers refused, scope, confirmation and
missing keys, RFC 8032's signature, and the service over channels.
`tests/NoiseIKTests.swift`: two factotums making a session through their
apps, factotum against Noise's own handshake, the key made once and
listed hidden, a wrong key and a pattern outside the scope refused.
GateTests runs 9gate with factotum's key between two stacks.

Keys live in memory until Taisce keeps them on disk (V4).
