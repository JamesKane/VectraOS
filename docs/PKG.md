# Packages and updates: files by hash, installed by a bind

**Written before the code.** Vectra has no package or update story. An
update today is a rebuild on the host: `build.odin` stages `build/esp`, and
the machine boots the new tree. `docs/FLEET.md` step 3 serves that one tree
over 9P, so a fleet updates when its file server does. A board on a desk
with no host checkout beside it cannot update at all. This plan is for that
board, and for the fleet it may later join.

**What a person sees.** `pkg verify` names every file of the base system
whose bytes are not what the build signed, and every file no manifest
names. `echo update > /mnt/pkg/ctl` fetches the newest signed release from
the file server and binds it. `echo rollback base > /mnt/pkg/ctl` goes back
one. A new `sam` in one window and the old one in another is two
namespaces, and nothing else.

## 1. What is taken, and from where

**From plan-neo, the whole design.** Its `docs/packages.md` and roadmap
phase U (U1 to U8) are the model here. A file is stored under the SHA-256
of its bytes, a manifest lists a package's files by hash, and a signed
release names one manifest. A peer is a file server, so a fetch is a mount
and a read. An install is a bind, so a rollback is the previous bind.

This document keeps all of that. It changes what Vectra already has an
answer for: the keys, the wire, the discovery and the formats.

**From `docs/WEB.md` section 3, the store.** `webfs` already keeps a
directory of bodies named by their SHA-256, and writes a body only if its
name is not there. That is a content store. The code comes out of
`servers/webfs` into `sys/libstore`, and both programs use it.

**From `docs/FLEET.md`, the rest.** `factotum` holds the keys, so no
program does. The wire is the fleet's 9P, sealed by the Noise handshake
under every stream. `ndb` names the machines, so no discovery protocol is
needed. `/lib/namespace` and `newns` are the install mechanism, once
`newns` learns Plan 9's `. file` from `namespace(6)`, which replays
another namespace file in place.

## 2. The store and the manifest

The store is `/usr/pkg/store`, one file per blob, named by the hex SHA-256
of its bytes. `/usr` is `kfs` on the scratch disk, the one writable disk
that keeps what is written to it and renames atomically. The ESP is FAT,
and under QEMU `vvfat` does not keep a raw write.

    /usr/pkg/
        store/9f86d081...      one blob, named by its hash
        installed/NAME/VERSION/  a package, materialised as a tree
        namespace              the binds, written by pkg, replayed by newns
        seen/CHANNEL           the highest seq this machine accepted
        releases/CHANNEL/SEQ   every release it accepted, as it arrived

A blob arrives in a temporary name and is renamed into place only after
its hash checks. So a store never holds a file whose name lies.

**A manifest is text, one line per file.** Path, mode, size and hash, in
that order, sorted by path, so `cat` reads it and `diff` compares two:

    amd64/bin/sam   0755  184320  2c26b46b68ffc68f...
    lib/sam/keys    0644     812  fcde2b2edba56bf4...

A manifest names a package, a version and the architectures it holds on
its first line. It is itself a blob, so a package version is one hash.
`installed/NAME/VERSION` is the tree its lines describe, built by linking
each blob out of the store. Two versions that share a file share one blob.

**The base system is a package too.** It is named `base`, its version is
its release's `seq`, and its manifest is every file `stage_vectra` puts
under `build/esp/vectra`. The build writes it as `/lib/pkg/base.manifest`.

Proves: a tree stored and read back matches its manifest, and `verify`
names a blob changed in the store. A blob that arrives with the wrong
bytes is never renamed into place.

## 3. The signing chain

Peers are not trusted. Keys are.

    root key          offline, its public half at /lib/pkg/root.key
      signs a channel key    name, public half, notbefore, notafter
        signs a release      channel, seq, time, expires, manifest, previous
          names a manifest   which names blobs, each checked by its hash

**A release is text too.** One `attr=value` line each, and a last line
`sig=` whose value is the channel key's Ed25519 signature over every byte
before it. A client evaluates nothing else before it trusts a release.
The signature is Ed25519 because `core:crypto` has it and `libpgp` already
signs with it through `factotum`.

**`seq` stops a replay, `previous` chains, and `expires` stops a freeze.**
A client refuses a release whose `seq` is not above `seen/CHANNEL`, and
one whose `previous` is not the hash of the release it holds. So a peer
cannot hand over last year's release with last year's bug in it. `expires`
catches a peer that offers nothing newer at all. Past it, `pkg`
says the channel is stale on every `status` read and in the log, and
still runs what it has.

**Expiry needs a clock, and a board may not have one set.** A clock that
reads before the release's `time` is unset, and `pkg` says so and skips
the expiry check. `seq` still holds with no clock at all. `cmd/timesync`
from `docs/FLEET.md` step 3 sets the clock before `pkg` runs, when it can.

**The keys live in `factotum`.** A channel key is a line on the signing
machine's `factotum`:

    key proto=sign name=stable !private=...

`pkg release` writes the release's digest to `rpc` and reads the
signature back, as `proto=openpgp` does today. The root key is derived
from a passphrase with argon2id, as `docs/FLEET.md` section 4 derives a
user's key. It exists only for the minute a person types it to sign a new
channel key, and then nowhere. Verification needs only public halves, so
a client's `factotum` holds nothing for `pkg`.

Proves: a release signed on the fs machine verifies on the other. Three
releases are refused: one re-signed with an older `seq`, one whose
`previous` breaks the chain, and one whose channel key is past its
`notafter`. And the control, the `seq` check removed, where the older
release installs.

## 4. Install is a bind

A package is never unpacked over the system. It is a tree under
`installed/NAME/VERSION`, and an install is a line in
`/usr/pkg/namespace`:

    bind -a /usr/pkg/installed/sam/4.2/$cputype/bin /bin
    bind -a /usr/pkg/installed/sam/4.2/lib/sam /lib/sam

`/lib/namespace` ends with `. /usr/pkg/namespace`, so every new process
and every `newns` sees what is installed. `pkg` also applies the lines to
its caller's namespace, so the shell that asked sees it at once.

**So a rollback is the previous bind.** `pkg` keeps the file's earlier
forms, and `rollback NAME` writes the line for the version before. An
install that fails halfway leaves a directory no line names. Two versions
at once is two namespaces: `bind -b /usr/pkg/installed/sam/4.3/$cputype/bin
/bin` in one window tries the new one, and no other process sees it.

**A package goes after the base, with `-a`.** So a package cannot shadow
a base command by accident. A manifest that names a file the base names
is refused at install, with both names in the error.

**The base is replaced the same way, one line earlier.** The first line of
`/lib/namespace` binds `/n/fs/$cputype/bin` over `/bin`, and the ESP's
tree is release zero. A base update writes its own first line to
`/usr/pkg/namespace`, `bind /usr/pkg/installed/base/SEQ/$cputype/bin /bin`,
which replaces the ESP's `/bin` for every new process. The kernel still
binds the ESP's tree for its own checks, so a store that will not mount
still boots to a shell.

**The kernel is not a bind.** Limine reads it off the ESP before any
namespace exists, so step 6 gives it a boot entry of its own instead.
That is the only write `pkg` makes outside `/usr/pkg`.

Proves: two versions of one program installed at once, run from two
namespaces, each printing its own version. A rollback puts the first
back for the next process. A package that names `/bin/ls` is refused.

## 5. `/mnt/pkg`, and one tree for both sides

`servers/pkgfs` posts `/srv/pkg` and is mounted at `/mnt/pkg`. **The same
tree is the control interface and what another machine fetches from**,
so a machine that holds a blob can hand it on.

    /mnt/pkg/
        ctl          w  one command a write:
                        install NAME[@VERSION] | remove NAME | update [NAME]
                        rollback NAME | verify [NAME] | gc | refresh
        status       r  channel, seq, time, expiry, blobs held, bytes
        index        r  installed: NAME VERSION MANIFEST STATE
        available    r  from the current release: NAME VERSION SIZE
        channels/stable  r  the signed release as it arrived
        blocks/HASH  r  one blob, checked again before it is served
        log          r  fetches, checks, refusals, binds, in order

A write to `ctl` that fails answers the reason as the write's error, so
`echo install sam > /mnt/pkg/ctl` in `rc` prints why. `cmd/pkg` is a thin
front that writes `ctl` and reads the answer, and `pkg verify` is the one
verb that works with no `pkgfs` running.

## 6. Fetch: from the fs machine, then from a peer

**The first source is the fleet's file server.** `ndb` names it with
`pkg=` on its line. `pkgfs` imports that machine's `/mnt/pkg` over the
sealed 9P of `docs/FLEET.md` step 1. It reads `channels/stable` and checks
the chain. Then it reads the manifests it lacks, and `blocks/HASH` for
each blob it lacks. Each blob is checked against the hash it asked for
before it lands.

A standalone board names a server across the internet the same
way, with a `key=` it trusts, and nothing else changes.

A rebuild that changes one program fetches one blob, and an update needs
no diff format.

**A peer fetch is a later step, and the same read.** Any machine whose
`ndb` line carries `pkg=` serves `blocks/`. `pkgfs` asks the fs machine
for the release and the peers for the blobs, and one wrong blob costs one
failed check. A room of boards then updates once from outside and then
from each other.

## 7. `pkg verify`, and the stale ESP

`pkg verify` walks `/lib/pkg/base.manifest` against `/n/fs` and hashes
every file. It names three kinds of wrong:

- a file whose bytes differ
- a file the manifest names and the tree lacks
- a file the tree holds and no manifest names

The manifest leaves out itself and `tmp/`, which a running machine
writes. `verify NAME` does the same for one installed package.

**The third kind is a bug this project has, today.** Nothing wipes
`build/esp` between builds. So a program renamed or removed in
`build.odin` stays on the ESP, and a stale binary answers to its old
name. A fleet build puts two architectures there on purpose, and the
manifest names both. `verify` catches the stale file on the first
boot after it appears, where today it hides until something runs it.

A failing disk and a changed file are one finding here, as in plan-neo.
Until step 2 the manifest is unsigned, so `verify` proves the tree matches
the build and not that the build is trusted. The boot line says so.

## 8. What is refused, and why

- **A script that runs at install.** An install is a bind, and a bind runs
  nothing. A package that needs setup ships a file a program reads. So an
  install cannot do what the person did not see.
- **An unsigned package, and a switch that allows one.** A developer who
  wants a local package makes a local channel key, which is one line in
  `factotum`. A switch to skip the check is a switch someone leaves on.
- **A dependency solver.** A manifest lists dependencies by name and
  minimum version. `pkg` computes the closure and refuses a conflict, and
  names the two packages. Two versions can be installed at once, so most
  of what a solver prevents cannot happen here.
- **Discovery by broadcast, a DHT, and a Bloom filter of held blobs.**
  `ndb` names every machine in a fleet, and a board names its source.
  plan-neo's U6 solves a problem a homelab with a database does not have.
- **Building on the target.** `build.odin` builds a package on the host,
  per architecture, and the fs machine signs it.
- **Privacy of what is installed.** A peer sees the hashes a machine asks
  for and may recognise them. Nothing here hides that, and saying
  otherwise would be worse.

## 9. The order

Each step ends with a boot line in `tests/pkg.rc`, and each is usable
before the next starts. Steps 0 to 4 give a verifiable package system
with rollback and one source, and step 0 alone catches the stale ESP.
Sizes count the tests.

### Step 0: `verify`

`build.odin` writes `/lib/pkg/base.manifest` while it stages the ESP.
`cmd/pkg` with the one verb, and SHA-256 from `core:crypto`. About 350
lines. Needs nothing this tree has not built.

Boot line: `pkg verify` over the staged tree answers clean. The control
writes one byte into a staged file and adds one stray file, and `verify`
names both, by path and by kind.

### Step 1: the store and the manifest

`sys/libstore` out of `servers/webfs`, `installed/` built from a
manifest, `pkg verify NAME`. About 500 lines. Needs step 0 and `kfs`.

Boot line: a tree stored and materialised matches its manifest, and a
blob corrupted in the store is named.

### Step 2: releases and signatures

Section 3's chain, `proto=sign` in `factotum`, `pkg release`, and
`/lib/pkg/root.key` staged by the build. About 600 lines. Needs
step 1 and `docs/FLEET.md` step 2.

Boot line: section 3's proof and its control.

### Step 3: install as a bind

`/usr/pkg/namespace`, `. file` in `newns`, `install`, `remove` and
`rollback`, the base's own line. About 500 lines. Needs step 2.

Boot line: section 4's proof.

### Step 4: `/mnt/pkg`

`servers/pkgfs` over `lib9p`, section 5's tree. About 700 lines. Needs
step 3.

Boot line: `echo install sam > /mnt/pkg/ctl` from `rc`, and an error
read back from a refused install.

### Step 5: fetch from the fs machine

`pkg=` in `ndb`, the import, `update` and `refresh`. About 400 lines.
Needs step 4 and `docs/FLEET.md` step 3.

Boot line: on the two-machine bench, machine two updates from machine
one's store and runs the new program. A blob changed in flight is
refused.

### Step 6: the kernel

`vectra-SEQ.elf` beside the old kernel, and a new first entry in
`limine.conf` with the previous one kept second. About 300 lines. Needs
step 5, and a bench whose ESP keeps a write, which `vvfat` does not.

Boot line: by hand, a board boots the updated kernel and falls back to
the previous entry from the Limine menu.

### Step 7: a peer fetch

Blobs from any machine `ndb` names with `pkg=`. About 300 lines. Needs
step 5.

Boot line: machine two installs from machine three's blobs, with machine
one serving only the release.

## 10. Decisions taken here, and what would reverse them

- **A hash names a file, and a fetch is a read.** The reversal is none.
- **Install is a bind, and nothing runs.** The reversal is none.
- **Text formats, where plan-neo chose fixed-width structures.** `cat`,
  `diff` and `grep` read text. The reversal is a release too large to
  read in one message, and there is not one.
- **Ed25519, through `factotum`.** The reversal is a primitive
  `core:crypto` drops, and the release names its algorithm so one can
  move.
- **The root key is a passphrase.** So it is nowhere to steal. The cost
  is that it is only as strong as the passphrase, and it wants a long
  one. The reversal is a hardware key, and then `factotum` talks to it.
- **The store is on `kfs`.** The reversal is a file system of this
  tree's own with snapshots, and then the store moves onto it.
- **`ndb` is discovery.** The reversal is a fleet too large for one
  file, and the same argument as `docs/FLEET.md`'s users.

## See also

- `docs/FLEET.md` -- the file server, `factotum`, `ndb`, and the
  namespace file this installs into.
- `docs/WEB.md` -- the store by hash this reuses.
- `docs/NAMESPACE.md` -- the union a bind makes.
- `docs/HARDWARE.md` -- the board this is for.
- `docs/KFS.md` -- the disk the store is on.
- plan-neo's `docs/packages.md` -- the design this adapts.
