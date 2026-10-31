# D153. Taisce's S2: snapshots as dated directories, send and receive between members, and AES-XTS per volume (2026-10-30, decided by the owner; D148 §5, V7 step 7; extends D105)

D148 put Taisce's S2 in V7, its three parts designed together:
snapshots as dated directories, a volume's changes sent to another
node's over 9gate, and per-volume AES-XTS. todhchai's filesystem.md
(§2, §3, §5, §8) is the only design; none of it was built.

## What stands

- **One volume a device.** A partition holds one volume: superblock
  rings at both ends, two alternating bitmaps, the intent log, data
  (Superblock.swift's `Layout`). There is no container of volumes.
- **Copy-on-write by superblock flip** (S1). A node pointer is
  physical: block, BLAKE3-128 of the node, birth txg. The catalog maps
  each tree (the FS tree, each index, the journal) to its root.
- **A file's extents** record their blocks and each block's checksum,
  but not the group that wrote them.
- **Free space** is a bitmap. A freed block is held through its group,
  deferred through the next, then retired until no reader's epoch can
  see it.
- **No AES** anywhere in the tree. crypto/lib has BLAKE3, ChaCha20,
  SHA-2, HMAC, PBKDF2, X25519 and Ed25519, checked against 9front's
  libsec, which has AES and XTS.
- **The node's key is on its volume** (D152 §1), in plain until this
  step encrypts the volume.

## Proposed

### 1. Snapshots

**On disk** (format 6):

- A file extent records its birth txg, as a node pointer does.
- Two new trees go in the catalog:
  - **Snapshots:** id → txg, time, the catalog root at that txg.
  - **Deadlists:** (snapshot id, birth, block) → count.
- Taking a snapshot is one record at a commit; nothing is copied.

**Freeing** (ZFS's and gefs's rule, todhchai §3):

- A block born after the newest snapshot is freed as now.
- An older block goes onto the newest snapshot's deadlist instead.
- When snapshot S is deleted (P before it, N after), N's deadlist
  entries born after P are freed; no one else could see them. S's
  deadlist then merges into N's.
- No refcounts, no extent-reference tree.

**Shown** as Plan 9's dump shows them:

- fs's tree gains `snap/YYYY/MMDD/`, with `.1`, `.2` for a second and
  later one in a day. Each is the volume read-only at that txg.
- Ordinary directories, so `diff`, `cp` and `bind` work. There's one
  view: no labels, and no `.snapshot` in every directory.
- A manifest mounts them as it mounts the volume (`mount /n/dump
  fs/snap`).

**Control** through fs's `ctl`:

- `snap` takes one.
- `unsnap YYYY/MMDD[.N]` deletes one.
- Nothing is deleted on its own.

**Limits:**

- With snapshots, a full volume fails writes until one is deleted.
- Queries and live queries on a snapshot wait. Its indices are
  captured, so this is possible later.

### 2. Send and receive

**The stream** is a logical diff from snapshot A to snapshot B, or
from nothing to B:

- fs walks the two FS trees together, skipping every subtree whose
  pointers are equal (block and checksum).
- It sends the inodes, entries and attributes that differ, the data of
  the extents that differ, and the deletions.
- Indices and the journal are not sent: the receiver applies the
  records as ordinary operations, so its own indices, journal and live
  queries follow.
- A stream is plaintext inside Noise IK, whatever either volume is.
  The receiver writes with its own key.

**Received into a directory** on the receiver's volume,
`recv/<sys>/`:

- A received file keeps the sender's inode in an indexed attribute
  (`sys:sent-ino`), so an incremental stream finds the files it
  changes. That uses the indices already there; it's not a new table.
- After each stream, the receiver takes its own snapshot, and the
  directory records the base it holds: the sender's volume uuid and
  snapshot txg.
- An incremental stream from any other base is refused.

**The files:**

- fs's `send`: write `[A] B` to it, then read the stream from it, one
  stream an open.
- fs's `receive/<sys>`: a stream written to it is applied to
  `recv/<sys>/`.

**Between nodes:**

- The `file` role's 9gate listener exports fs's whole tree rather than
  `/data`: the volume at `volume/`, plus `snap/`, `send` and `receive/`.
- A member imports another's tree as now, and `send -i A B` copies a
  stream from one node's `send` to another's `receive/<sys>`.
- Members are already trusted with the whole volume (swarm(4)), so
  this widens nothing.

### 3. AES-XTS per volume

**The cipher:**

- AES-256-XTS (FIPS 197, IEEE 1619), our own code, with a 4 KiB data
  unit and the tweak the block number.
- It sits in a `BlockDevice` that wraps the partition, so Taisce above
  it is unchanged.
- It covers every block except the two superblock rings, which stay
  plain and hold the keybag.

**Integrity:**

- On an encrypted volume, every checksum becomes keyed BLAKE3 of the
  plaintext, the key derived from the volume key.
- XTS alone is malleable; the keyed Merkle tree makes the whole volume
  authenticated, at no added cost.
- An unencrypted volume keeps plain BLAKE3.

**AES on each arch:**

- amd64 uses AES-NI, which Ivy Bridge has.
- arm64 uses the Armv8 crypto extension as a D128 tier. The Sky1 has
  it; the baseline doesn't.
- rv64 and any CPU without either uses constant-time bitsliced
  software. A table AES leaks keys through cache timing.
- It's checked against libsec's AES and XTS, as the other ciphers are.

**The keybag:**

- The volume key is random, made at format.
- Up to four slots each wrap it: ChaCha20 under a key-encryption key,
  tagged by keyed BLAKE3.
- A slot can be added or removed without rewriting the volume.
- Two kinds of slot (§4 asks which to build):
  - **Passphrase:** the key-encryption key from PBKDF2-HMAC-SHA256.
  - **Swarm:** unlocked by a member, McCallum-Relyea over Edwards25519,
    as Tang/Clevis do. The member holds a key pair and learns nothing
    of the volume key. The node needs no identity to ask, which matters
    because its identity is on the volume.
  - What a swarm slot protects against: a disk taken away from the
    swarm's network is unreadable; one that stays on it, with a member
    up, unlocks.

**Unlocking:**

- fs mounts an encrypted volume locked.
- Its tree answers, but `volume/` waits until `unlock` (with a
  passphrase) is written to fs's `ctl`, or a swarm slot's member
  answers. fs gains `/net` for that, optional.
- factotum, 9gate and cpu's server wait with `/data`. The dev link
  (vx's pinned key, bootfs) doesn't.

**Formatting:**

- `--format --encrypt` (and `vx disk --encrypt`) makes an encrypted
  volume.
- An existing volume isn't converted in place: it's formatted anew.

**Budget:** the file budgets (D105) stand on an encrypted volume,
judged on the board, plus one new one, `crypto.aes_xts_4k`, with its
check.

## Not chosen

- **Adiantum** (ChaCha12 wide-block, made for CPUs without AES): D148
  named AES-XTS, and both boards' CPUs have AES.
- **Raw (encrypted) send:** the tweak is the block number, so blocks
  can't move unencrypted, and members are trusted.
- **Containers of many volumes, reflinks, compression:** todhchai's S2,
  not D148's.
- **Labels beside dates.**
- **Automatic retention.**
- **Argon2.** PBKDF2 is in the tree; a memory-hard KDF is new code.

## Built in this order

1. Snapshots: format 6, the deadlists, `snap/`, `ctl`. Done: format 6
   mounts format 5 (its extents read as born in group 0), and its intent
   records replay. Freed blocks wait in memory until the commit puts
   them on the deadlist; the deadlist is keyed by the group that let a
   block go, then its birth, so taking a snapshot rekeys nothing.
   Putting them there can let go more nodes, so the commit goes round
   until a round lets go of none. fs serves `snap/` read-only, by Node
   alone and past the files' VMOs, on the volume's thread; `ctl` takes
   `snap` and `unsnap`, and `--daily HH:MM` takes one a day in the cpu
   and board images. TaisceTests' shadow model and crash harness take
   and delete snapshots, and deleting every snapshot gives back exactly
   what a volume that never had them has free. Checked on a bridged
   QEMU node whose volume format 5 made: it mounted, took two
   snapshots, read the old file in one, refused a write there, deleted
   the other, and kept the rest across a reboot.
2. Send and receive, between two QEMU nodes. Done: the sender reads
   only the inner nodes of the two snapshots' file trees and skips the
   leaves they share; each node whose keys differ goes whole but for
   its data, of which the blocks whose checksums differ. The receiver
   moves each node it takes into a staging directory, `.receiving`,
   applies its kind, mode, attributes and data, and at the end deletes
   what's gone and puts every node at its names, so renames, swaps and
   moved directories need no order; it puts back the times of the
   directories it only passed through. fs serves `send` and
   `receive/<sys>`; send(1) copies between them; the `file` role's
   export is fs's tree, which 9gate holds at `/fs`. TaisceTests send
   whole and incremental streams, and twelve rounds of random changes,
   comparing every name, link, byte, attribute and time. Checked on
   two bridged QEMU nodes: node1's snapshot went whole to node2's
   `receive/node1` through 9gate's import of its tree (76.6 MB, about
   20 s), a change after it as 160 bytes, and a stale incremental and a
   second whole snapshot were refused.
3. AES and XTS, with the keybag, passphrase slots and unlocking. Done:
   `AES256` and `AESXTS` in crypto/lib, four blocks at a time; where
   every CPU has them (the topology page's record, D128) the work is
   crypto/accel's C, AES-NI on amd64 and the Armv8 extension on arm64,
   and elsewhere, as on rv64, constant-time software whose SubBytes is
   Boyar and Peralta's circuit over bit-planes. clang's `ivybridge`
   leaves AES-NI out (D52), so amd64 reads the record too. CAVP's ECB
   known answers and XTSGenAES256 vectors check both paths, as does
   libsec's AES and XTS on random keys and units; CryptoSuite checks
   them on each arch. Keyed BLAKE3 goes through the four-chunk and the
   cached-group paths. Taisce's format 7 puts the keybag in the
   superblock with an authenticator, the superblock's keyed checksum,
   since the superblock stays plain; `SealedDevice` encrypts every
   other block and hands its checksum key to the volume, which keys
   every checksum by it. A slot is ChaCha20 under PBKDF2-HMAC-SHA256
   (200,000 rounds) of the passphrase and its salt, tagged with keyed
   BLAKE3. TaisceTests' crash harness runs over an encrypted volume
   too, and new tests show nothing written appears on the disk, a
   flipped or moved block and a superblock forged without the key are
   caught, another key opens nothing, and slots change by a commit. fs
   starts its tree at once and mounts on the volume's thread once it
   has the key; `ctl` takes `unlock`, `slot add passphrase` and `slot
   remove`, and `status` shows the keybag. `vx disk --encrypt` and
   `vx fsck` read a passphrase from standard input.
   A locked boot needed a way to the passphrase, which the proposal
   didn't give: the launcher opens each service's mounts before it
   starts it, so every service that mounts `/data` (the console's
   shell among them) waits for the volume. The owner chose a prompt
   on the console, as LUKS and geli ask at boot (2026-10-30): fs reads
   kbdfs's cons in raw mode, nothing shown, and asks again for a
   passphrase no slot takes. So the dev link waits too, until step 4's
   swarm slot unlocks with no prompt. boot-unlock types a wrong
   passphrase and then the right one through QEMU's monitor, and vx
   cpu then writes to `/data`: 18 s on amd64, 15 on arm64. The budget
   `crypto.aes_xts_4k` (a 4 KiB block, its limit 10 µs with the
   instructions) is reported by launch-test: 16 µs on amd64 and 25 on
   arm64 under TCG; it is judged under KVM and on the board at the
   milestone's exit, with the file budgets on an encrypted volume.
4. Swarm slots. Done: McCallum-Relyea over Edwards25519 in crypto,
   the member's key clamped to a multiple of 8 so a request's
   small-order part tells nothing. factotum holds the member's half,
   `proto=mcr`, a key made on first boot and kept on the volume with
   the node's noise-ik key; the swarm service answers on tcp!*!17021,
   unsealed, since the asker has no identity yet, and its status gives
   the key. A swarm slot holds the member's key, the point C and the
   member's address (a dial string; the node can't read the swarm file
   or ask cs, both on the volume): fs's `ctl` takes `slot add swarm
   ADDRESS KEY`, and at boot fs asks each swarm slot's member through
   `/net` (its manifests mount net's, optional) beside the console's
   prompt, again and again, the wait doubling to 30 s. The slot's tag
   now covers the whole slot. The floor's stdout mixes the lines of a
   process's threads printing at once (one line buffer, locked a
   character at a time), so fs's prompt and swarm threads say their
   lines in turn, and the swarm service waits for its unlock
   listener's line; the floor itself is unchanged. boot-swarm-unlock
   boots a member, then the node twice on an encrypted disk, its calls
   to 10.0.2.100!17021 relayed to the member's forwarded port (qemu.sh's
   new `--relay`): the passphrase unlocks the first boot, which adds
   the slot; the member alone unlocks the second, 40-80 ms after fs
   asks. 21 s on amd64, 33 on arm64.

Each is tested in TaisceTests: the crash and shadow-model fuzzers gain
snapshots, deletes and receives. Each is also run on QEMU nodes while
the board is in other use.

## Decided (the owner, 2026-10-30)

As proposed, with these four choices:

- **Unlocking:** both kinds of slot. A swarm member unlocks the volume
  at boot, and a passphrase written to fs's `ctl` recovers it.
- **Naming:** snapshots are shown by date only, `snap/YYYY/MMDD[.N]/`.
- **Taking:** on demand through `ctl`, and once a day at a UTC time the
  manifest names, in the cpu and board images. Nothing is deleted on
  its own.
- **Sending:** the `file` role's listener exports fs's whole tree, so
  an import sees the volume at `volume/`, beside `snap/`, `send` and
  `receive/`.
