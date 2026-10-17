# The keyring

The authentication agent (M6k part k4; architecture §17), after Plan 9's
factotum: it holds every key and runs the authentication protocols for
apps, which only pass bytes between it and their peer. An app gets the
result (whom it authenticated as, the peer, a session secret), never a
long-term key.

## The core (k4b)

`Keyring` (`services/keyring/lib`, tier 0, tested hosted in `tests`):

- **Keys** (`Keys.swift`) are factotum's text: `key proto=scram-sha-256
  server=mail.example user=jk !password=secret`. A `!` attribute is
  secret: a listing shows `!password?`. Values quote as rc does. A
  `KeyStore` adds (replacing a key with the same public attributes),
  deletes by pattern, lists, and takes factotum's ctl lines (`key ...`,
  `delkey PATTERN`).
- **Patterns** are `name=value` and `name?` terms. A secret attribute
  matches only `name?`, so a client can't guess a secret one try at a
  time. `within(scope)` says whether a pattern stays inside an app's
  scope, its manifest's patterns.
- **Sessions** (`Session.swift`): `Keyring.start(pattern, role:, app:,
  scope:)` gives an `AuthSession`. Its `next()` returns `send`, `need`,
  `needKey`, `needConfirm` or `done`; `feed` takes the peer's messages.
  A key's `confirm=always|once|never` says whether its use asks the user
  (`once`: once per app). By default `pass` always asks and SCRAM never.
  The answer comes back through `confirm(_:)`, or a key added (`needKey`),
  or `declineKey()`.
- **Protocols:** `proto=pass` reveals a password (client only, after a
  yes). `proto=scram-sha-256` (`Scram.swift`, RFC 5802 and 7677, no
  channel binding) runs in both roles. A server's keys are `role=server`,
  holding each user's password, `salt` (base64) and `i`. The client checks
  the server's signature before it's done. Stubs: SASLprep (no NFKC yet),
  and iteration counts are only accepted from 4096 to 1,000,000.
- **proto=ed25519** (`Signer.swift`, N1c) signs with a key no app
  holds: sshd's host key. A server-role session sends the public key (32
  bytes), needs the bytes to sign, sends the signature (64), and is done.
  The key is `key proto=ed25519 service=sshd !seed=BASE64` (RFC 8032's
  private key); when none matches, the keyring makes one from its
  randomness (`Keyring(random:)`, croi's CPRNG in `bin/keyring`) with the
  pattern's attributes, so the host key exists from first use. Server
  sessions never ask the user. Tested against RFC 8032's first vector.
- **The protocol** is `AuthIPC` (`Protocol.swift`; idlc's outputs in
  `idl`): `Keyring.startSession(pattern:role:session:)`, then
  `AuthSession`'s `next`, `feed`, `failure`, and the `answered` event that
  ends a wait on the user.

The tests replay RFC 7677's example exchange byte for byte in both roles.
They also run a client keyring against a server one, and check that bad
peers are refused (a wrong password, a forged signature, a nonce not
extended, too few iterations, a mandatory extension), plus scope,
confirmation and missing keys.

## The service (k4c)

**Who's asking.** The keyring's manifest says `export per-client`: the
launcher alone reaches its own tree, and opens one for each service that
uses it, through its `clients` node (`LaunchIPC.Clients`, naming the
client), so the keyring knows which app asks and an app can't claim to
be another (system/launch/README.md). A user's manifest:

    use keyring
    grant keyring proto=scram-sha-256 server=db     # a pattern its sessions must stay within
    grant keyring admin                             # and /svc/keyring/ctl: factotum's

A client's tree has `keyring` (`AuthIPC.Keyring`) and, with `admin`,
`ctl` (reading lists the keys, secrets hidden; writing `key ...` or
`delkey PATTERN`). `KeyringState` (`lib/Server.swift`, tested hosted
over channels in `tests/ServerTests.swift`) serves them: each session an
`AuthSession` on the dispatcher; one that waits on the user puts its
question in `questions`; `answer` takes the reply from any thread and
the session's `answered` event goes to its app; a key added (the prompt,
or ctl) ends the waits it answers; a session that closes takes its
question with it.

**The prompt** (`prompt/`, `KeyringPrompt`, a Kit app; tested hosted in
`prompt-tests`, `TODHCHAI_KEYRING_SAMPLE=FILE` draws board 10's) asks one
question at a time, oldest first: an app wants a key (Deny, Allow;
Escape is Deny), or needs one (a password, in a secure field: bullets,
and no value for readers; the user too if the pattern doesn't name one;
Cancel, Add). `bin/keyring` (`Main.swift`, `boot/shell/keyring.manifest`)
shows it as a panel (undecorated, over every window) while a session
waits, and closes it when none does. Without the storyboard's fonts in
bootfs it can't draw, and refuses what would ask the user. Its window is a secure surface (M6k k6a: the keyring's manifest says
`grant radharc secure`; Radharc leaves it out of `a11y` and shows it
black to its `pixel` probe and, with k6b, to captures), and its label
says so: "Secure surface · keyring".

`keyring-amd64` (`bin/keyring-test`, `tests/native/keyring`): ctl's keys,
SCRAM between two sessions, `pass` allowed and denied by clicks in the
prompt, a pattern outside the scope refused, a password typed into the
prompt.

The encrypted keybag comes with the login screen (decided 2026-10-13);
until then keys live in the keyring's memory, and a restart loses them.

## Radharc's approver (M6k k6c)

The keyring's manifest says `grant radharc approver`: it connects to
Radharc's `approvals` and asks on its prompt what Radharc asks (an app
wants capture, inject, observe or shortcuts: "privileged-test wants to
watch your input", Deny or Allow), on a thread of its own; Radharc keeps
the answer (services/radharc/README.md).
