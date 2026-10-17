# D77. The bring-up link is Plan 9's cpu, not SSH (2026-10-16, decided; supersedes D15's protocol, amends D75)

D15 chose SSH for the bring-up link because todhchai's N1 had most of
sshd built, and stock OpenSSH on the dev machine needs nothing of ours.
D75 then made Plan 9's cpu the remote session between our own nodes,
leaving SSH a second session protocol kept only for bring-up, and D76
put Taisce and the desktop ahead of the boards, so building the link
ourselves no longer delays the first board. The owner's direction
(2026-10-16): pull SSH entirely, and bring forward enough of cpu to be
the link.

- **The link is cpu, in V3.** `vx cpu NODE [-c CMD]` on the dev machine
  dials the node and exports the dev machine's tree, which the node's
  rc sees at `/mnt/term`, with `/mnt/term/dev/cons` over its
  `/dev/cons`. The one session does everything SSH and SFTP did:
  - a shell: rc on the node, its text the dev terminal's, which stays
    in cooked mode and edits lines as a window would (D75);
  - file copies: `cp /mnt/term/PATH /dev/bin/`, with no SFTP or scp;
  - push and run: a program copied or bound from `/mnt/term`;
  - log streaming: `cat` of the debuglog's node;
  - warm boot: `warmboot /mnt/term/PATH/kernel.elf /mnt/term/PATH/bootfs.img`.
- **What V3 brings forward from V7:** 9gate's core, the 9P2000.L codec
  with export and import (one dialect; Linux `v9fs` conformance, the
  VectraOS extensions and the swarm stay V7's); the Noise IK transport
  (`Noise_IK_25519_ChaChaPoly_SHA256`, all of whose primitives N1's
  crypto has); factotum's `proto=noise-ik` key; the cpu server; and
  notes between processes in croi, so the terminal's interrupt reaches
  rc as a note.
- **`vx cpu` is ours.** The dev machine's client is Swift in `vx`, over
  the same codec and transport, built by SwiftPM: a host tool, so D4
  holds. Both ends are tested against each other in `swift test`, and
  against the device in QEMU, before any board.
- **D15's guardrails stay**, for the cpu listener: off unless the image
  is built with `vx boot --cpu PUBKEY`; on-link only; only the pinned
  dev machine's key is accepted; a test checks that a normal image has
  no listener. Its serial console plus Ethernet, and warm boot from
  memory, stay as D15 decided them.
- **No SSH anywhere.** `services/sshd` and SFTP are not lifted; N1's
  crypto, network stack, net class and virtio-net still are. D3 is as
  it was before D15 amended it: 9gate's protocol is the only one our
  nodes speak on the network.
- **The pty goes in V3.** With cpu's session serving `/dev/cons` and the
  console serving it too, nothing needs a pty after V3 (D75 had it wait
  for V5's rio). rio (V5) is then the first local window, not the pty's
  replacement.

Amends D75: cpu arrives in V3, not V7, and the bullet keeping SSH as the
bring-up link (its session serving `/dev/cons` itself) no longer
applies.

Costs, accepted: N1's sshd and SFTP, mostly built, are dropped; V3 gets
bigger (part of it V7's work, done sooner); we own both ends of the
link, so a link bug on a new board can't be ruled out with a mature
client (the serial console, V6's item 1, is the fallback); and nothing
outside `vx` reaches a node until V7's `v9fs` interop.

Not chosen: keeping SSH alongside cpu until V7 (two session protocols
for four milestones); drawterm or plan9port on the dev machine
(third-party, and neither speaks Noise IK); 9P without encryption for
bring-up (on-link only is a guardrail, not a reason to send keys and
images in the clear).
