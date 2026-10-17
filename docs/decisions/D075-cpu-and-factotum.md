# D75. The terminal is rio's window, remote sessions are Plan 9's cpu, and the keyring becomes factotum (2026-10-16, proposed)

The pty is temporary (services/pty/README.md): it goes for Plan 9's
`/dev/cons`, served by whatever shows a program's text, as rio serves
each window's. This decision says what serves it, locally and remotely,
and the authentication a remote session needs. The owner's direction
(2026-10-16): the terminal becomes rio's window, the pty's remote role
goes to cpu, and factotum authenticates.

- **The terminal is rio's text window, inside Radharc.** todhchai's
  Terminal (`shell/terminal`: an xterm emulator over a pty) is ported as
  `rio`, Plan 9's window, not its window manager: Radharc stays the
  compositor and window manager, with its workspace modes (D9) and its
  `wctl` (architecture §7). Each rio window serves its programs'
  `/dev/cons`, `/dev/consctl` and its own `wctl` in their namespace, and
  is the other end of their fds 0 to 2 (D46). Its text is plain and
  editable, as rio's: typing is edited anywhere after the output point,
  a line goes to the program when sent, hold mode keeps it until
  released, and `rawon` passes keys as they come. Programs see no escape
  sequences and no `TERM`.
- **The VT goes to `vt`.** `TerminalCore` (the DEC parser, cells,
  scrollback, the alternate screen, `KeyEncoder`) becomes Plan 9's
  `vt(1)`: a program run inside a rio window, raw on its `/dev/cons`,
  for tier 1 programs that want xterm, which it hands `TERM`. A window
  carries no emulator of its own.
- **Routing is plumbing.** Terminal's right-click route (the word under
  the pointer, sent to the router from the program's directory, which rc
  told it in OSC 7) becomes rio's: the selection or the word, plumbed
  with the window's directory, which the window knows because it serves
  its programs' namespace, not from an escape sequence.

- **A remote session is cpu, as Plan 9's.** `cpu -h NODE [-c CMD]` runs
  rc on another node in that node's namespace, with the terminal's own
  tree imported at `/mnt/term` and `/mnt/term/dev/cons` bound over
  `/dev/cons`, as 9front's cpu and rcpu do. rc's fds 0 to 2 are rings
  (D46) that 9gate bridges to the terminal's window, so the remote side
  has no pty and the terminal has none either; editing stays the
  terminal window's. It is the CPU role of the swarm's node roles
  (architecture §5, after NeoVectra's docs/02 §6), and rides 9gate
  over Noise IK (V7). It replaces sshd's `shell` between VectraOS nodes;
  it does not replace SSH as the bring-up link. Run in a rio window, the
  remote rc's text is that window's, edited there.
- **SSH stays the bring-up link** (D15 unchanged): stock OpenSSH on the
  dev machine reaches a board from V3, long before 9gate exists. Its
  session serves `/dev/cons` itself, with no pty: when the client asks
  for a pty (OpenSSH's own terminal is raw then), sshd's session echoes
  and edits lines, as a window would.
- **The keyring becomes factotum.** todhchai's keyring is already after
  factotum: it holds every key, runs the protocols for programs, which
  get the result and never a long-term key, keeps keys in factotum's
  text (`key proto=... !secret=...`) and takes factotum's ctl lines. So
  this is not a second mechanism: it is the one, under Plan 9's name.
  `services/keyring` is lifted as `services/factotum`, serving
  `/svc/factotum` (its `ctl`, and the typed `AuthIPC` sessions rather
  than factotum's text `rpc` file: one wire format, D6). Its prompt, its
  per-client scopes and confirmations, and Radharc's approver stay as
  todhchai has them. The encrypted keybag is its secstore.
- **factotum holds the node's identity.** Noise IK's static key is a
  factotum key (`proto=noise-ik`), as sshd's host key is
  (`proto=ed25519`): 9gate asks factotum to run the handshake's
  operations on it, so neither 9gate nor cpu holds the key. Added in V7.
- **A headless boot.** factotum's server-role sessions never ask the
  user, and without a prompt it refuses what would. A host key is made
  from the CPRNG on first use, as the keyring does. This settles the
  prompt half of N1's open question (roadmap, known issue 2); where keys
  persist across boots waits for Taisce on disk (V5), until when a
  headless node's identity lasts one boot.

Depends on: notes between processes (croi has none yet), so the
terminal's interrupt reaches the remote rc as a note, as cpu forwards
it (rio posts `interrupt` on DEL the same way); 9gate and Noise IK
(V7); Radharc (V6) for rio. Until V6 the console serves `/dev/cons`
the same way, so the pty can go before the desktop does.

Not chosen: Radharc rebuilt as Plan 9's rio, serving `/dev/draw` and
`/dev/mouse` per window (a second window protocol beside Radharc's, and
V6's design undone); Terminal kept with a VT in every window (programs
would keep emitting escape sequences, and editing would stay the
program's); cpu over SSH (a second session protocol between our own
nodes, beside 9gate); Plan 9's p9sk1 or dp9ik with an auth server (a
swarm has no central authority; Noise IK's static keys are its
identities); keeping the name keyring (one name for the mechanism, the
one Plan 9 gave it, now that the shell, the namespace and the console
are Plan 9's too).
