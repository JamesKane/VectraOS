# Phase 6 — Installation, packaging and updates

_Blueprint v0, 2026-10-02. Provisional: nothing here is needed before M5 (04 §6). It fixes the intended shape and is rewritten against the code each piece produces (§14)._

## 1. Goals

- **Install from one image.** A user boots the release ISO (or the same image written to USB), and the installer puts the system on a disk.
- **Find signed updates without a central server.** Updates come from any peer that has them: the user's own swarm, the LAN, strangers on the internet, or a mirror. A peer is never trusted; a signature and a hash are.
- **Apply only when the user asks.** Finding and downloading can run in the background, by policy. Changing the system never does.
- **Install new software with its dependencies.** Installing an app finds, checks and fetches the packages it needs, and the packages they need, without the user listing them (§3.4).
- **Roll back.** A bad update costs one reboot. The previous release stays bootable, and the machine's configuration and the user's files are snapshotted before the change.

Non-goals for v1: one system-wide set of library versions that all software must agree on, a central app store, live (rebootless) updates of the base system, and updates that apply themselves.

## 2. The model

There are three ideas, and each does one job:

1. **The base system is one immutable, versioned tree, never a set of packages.** A release is built from one commit, byte-for-byte reproducibly (04 §7), and named by the hash of its tree. Nothing on a running system modifies it. An update replaces the whole tree, so there is no partial state and nothing to resolve.
2. **Trees live in a content-addressed store.** Every file is stored once, by hash, as Plan 9's venti stored blocks. A peer that has an object can serve it to anyone, and the fetcher checks it against the hash it asked for. Downloading an update fetches only objects the store lacks, which makes the delta automatic. Keeping an old release costs only what differs from the new one.
3. **Booting picks a release; snapshots keep mutable state.** The disk holds several boot slots, each naming one release's tree. A new release is tried once and kept only if it comes up healthy. What a release does not contain (the machine's configuration and the user's files) is protected by filesystem snapshots, the same mechanism as agent undo (03 §8.5).

```
 signers (independent rebuilders)         peers: swarm · LAN · internet · mirror · the ISO
   build commit → same tree hash                serve /store objects by hash; untrusted
   sign release record (k of n)                              │
              │                                              │ 9Px reads, checked by hash
              ▼                                              ▼
 ┌──────────────────────────── distd (this node) ───────────────────────────────┐
 │ verify record chain → fetch missing objects → verify → stage → (user: apply) │
 │ /dist: ctl status policy releases/ apps/ store/                              │
 └───────────────┬──────────────────────────────────────────────┬───────────────┘
                 │ write slot, set trial boot                   │ snapshot before apply
                 ▼                                              ▼
   ESP: slot A (current) · slot B (trial) · slot C (previous)   fsd: /cfg, /home snapshots
```

## 3. What is shipped

### 3.1 The release

A **release** is everything the project ships at one version, for every architecture:

- one **release record** (§5.3): version, the commit it was built from, the previous release's record hash, and a tree hash per (architecture, set);
- the **trees** those hashes name, in the content store (§4);
- **install images**: the x86_64 ISO (hybrid, so it can be written to USB) and the aarch64 USB/SD image, each listed in the record with its hash.

A release's tree is what a running system sees at `/boot`, `/bin`, `/lib` and the rest of the read-only base (02 §5). It includes the kernel and `bootfs.tar` that a boot slot holds (§7). Once `fsd` exists (M5), `bootfs` shrinks to what is needed to reach the system volume: `svcd`, `devmgr`, the storage drivers, `fsd` and `distd`. The rest of the base is served from the store.

### 3.2 Sets

A release is split into a few **sets**, as OpenBSD's releases are: `base` (always installed), `devel` (clang, lld, Git, Python and the sysroot, M10), `desktop` (M6) and `ai` (`aid` and its runtimes, M9). Each set is a separate tree, so a node that never installs `ai` never stores or fetches it.

Sets are not packages. They share the release's version and signature, they cannot be mixed across releases, and installing one never resolves anything: `devel` from release 42 runs on `base` from release 42. A machine's selection is a line in its configuration (`sets=base,desktop,devel`).

### 3.3 App packages

Software that is not part of a release is a **package** (03 §6): a tree plus a manifest, in the same store format and fetched the same way. An **app** is a package a user runs; a **library** is a package other packages require (shared libraries, a language runtime, programs another package calls, data such as fonts or models). The format and the rules are the same for both:

- **Declared dependencies.** A manifest lists what the package needs: the system ABI (`requires=vx-abi>=2`), sets of the release (`requires=set:devel`) and other packages (§3.4).
- **Namespace-confined.** The manifest declares the namespace template the app runs in (`needs=/wsys,/dev/audio,net:client`). Installing shows it to the user (F-219), and `svcd` builds exactly that namespace at launch (rule 3).
- **Signed by its publisher.** A package names its publisher key. The first install pins the key, as `ssh` pins a host key; an update is accepted only under the pinned key, or a successor that key signed.
- **No central index** (D13, ADR-0003). A package is installed from a reference the user gives: its record's hash and publisher key, or a file or URL holding them. Anyone can run an index as an ordinary file server; the system ships none.
- **Per user, beside the base.** Installed apps live in the store and are bound into the user's namespace (`bind -a /dist/apps/hx/bin /bin`). Updating an app is a new tree. Running instances keep the old one until they exit, so app updates need no reboot.

The POSIX ports the project builds (LLVM, Git, Python) ship in a set, not as packages, so that the release's signers have rebuilt them. A package can require that set.

### 3.4 Dependencies

Installing a package resolves its dependencies: `distd` works out the whole set of packages it needs, shows it, and fetches it. What keeps resolution small is that **dependencies are resolved per app, not for the whole system.** Each app runs in its own namespace (rule 3), and `svcd` binds the app's own resolved libraries into it (`/lib`, `/bin`). Two apps that need different versions of one library each see their own, and both are stored once per distinct version. So there are no conflicts between apps, and nothing installed for one app can break another.

**Names are scoped by publisher.** A dependency names a package and the key that publishes it:

```
# manifest.ndb of the package hx
package=hx version=3.1.0 publisher=ed25519:6b0f…
    requires=vx-abi>=2
    requires=lua version>=5.4.0 publisher=ed25519:a1c3…
    requires=tree-sitter version>=0.24.0 publisher=ed25519:a1c3…
    needs=/wsys,/dev/cons
```

There is no global name space of packages, so a look-alike name under another key never satisfies a dependency, and typosquatting has nothing to aim at (D13).

**Versions follow semantic versioning,** and a requirement gives only a lower bound. Versions with the same major number are compatible; a new major version is a different package as far as resolution goes, and can sit beside the old one.

**Resolution is minimal version selection,** as in Go's modules. For each package, take the highest of the lower bounds that anything in the graph asks for, within one major version. That needs no SAT solver and no search: it is one walk of the graph. It is deterministic, since the result depends only on the manifests and never on what was published yesterday. It also gives the versions the app's publisher built and tested against, not newer ones nobody has tried together.

**Finding versions** (ADR-0014). A publisher serves a **catalogue**: a signed ndb file listing its packages, their versions and their record hashes, plus any versions it has **revoked**. `distd` reads the catalogue of each publisher the graph names, from the same sources as everything else (§6.1), and checks its signature against that publisher's pinned key. A catalogue lists one publisher's own packages and nothing else, so it is not a registry; there is still no index the system trusts for everyone. A revoked version is never chosen: resolution takes the next version up that the catalogue lists.

**The result is a lock.** Resolution writes `/dist/apps/<app>/lock`: every package in the graph, with the record hash of the exact version chosen. The app runs from the lock, never from a fresh resolution. Installing the same app on another node of the swarm copies the lock, so both run the same bytes.

**Updating is a new lock.** `app update hx` re-resolves with the newest version each catalogue lists within the same major version (the user asked for newer, so newer is what they get), shows what changes, and writes a new lock only when the user agrees. The old lock and its objects are kept until `gc`, so `app rollback hx` returns to it, as `rollback` does for the system (§10).

**What the user sees before anything is fetched:** every package in the graph, its version and size, every publisher key not yet pinned (each needs a yes), and every namespace grant any package in it asks for. A dependency's grants are the app's grants, because they run in the app's namespace.

**When resolution fails**, the reason is specific: no version the catalogue lists meets a bound, a publisher's catalogue cannot be fetched, a key is not accepted, a requirement names a newer `vx-abi` than the release provides, or a required set is not installed (and adding it is offered, from the current release).

### 3.5 Versions

- A release has a **sequence number** per channel, which only increases, and a name for people (`2027.03`). Its tree hash identifies it exactly.
- **Channels:** `stable`, `testing` and `dev` (every commit that passes CI). A node follows one channel. Switching to a channel whose newest release has a lower sequence number is a downgrade, and is treated as one (§5.4).
- **`vx-abi`** is the version apps see. A release states the `vx-abi` versions it provides, and an app that needs a newer one is refused at install with that reason, not at run time.

## 4. The content store and the tree format

- **Objects are named by BLAKE2b-256** of their content, written `b2:<hex>`. BLAKE2b is already in the boot chain (Limine's module hashes, 01 §10) and in Monocypher, so the system has one hash function.
- **A file** is split into 64 KiB blocks. Its hash is the root of a hash tree over the blocks, so a reader can check any block on its own, without reading the whole file. Small files are one block.
- **A directory** is an ndb file (D14) with one record per entry: `name=clang mode=0755 size=91234567 hash=b2:…`. Its hash is the hash of that text, which is written in one canonical form (sorted by name, no optional whitespace).
- **A tree's hash** is its root directory's hash. Two builds of one commit give the same tree hash (04 §7), which is what lets independent signers agree (§5.2).
- **Verified reads.** The server that serves a release tree checks every block against the tree before returning it or paging it in. So a block corrupted on disk, or altered by someone with the disk, fails the read with an error; it is never executed. With the boot chain's checks (§7), every byte of the base system is verified from firmware to `exec`, as dm-verity does for Android.
- **Names under `/dist/store`** are by hash: `/dist/store/b2/9f/9f3c…`. Peers read objects there over 9Px (§6.2).

`distd` keeps the store as files on the system volume. Blocks that two releases share are stored once.

## 5. Trust

### 5.1 Keys

Every key is Ed25519, like the swarm's node keys (02 §6.2). `keyd` holds the private keys a node has; the release keys never touch a node.

| Key | Held | Signs | Lifetime |
|---|---|---|---|
| **Root** | Offline, k of n, by the project | The root record: the release and heads keys and their thresholds | Years. A new root record is signed by a threshold of the old one's keys, so a node follows a rotation without trusting anything new |
| **Release** | Offline, one per signer | Release records | Rotated through the root |
| **Heads** | Online, on the project's publishing machine | The heads record: the newest release per channel, with an expiry | Days per record |
| **Publisher** | The package's author | Package records and its catalogue (§3.4) | Pinned at first install (§3.3) |
| **Swarm owner** | Offline (02 §6.2) | Optionally, approval of a release for the swarm (§6.3) | |

The root record a node trusts ships in its release (`/boot/lib/dist/root.ndb`), so installing from an ISO pins it. A user who builds and signs their own releases (§5.5) puts their own root there.

### 5.2 Signed by rebuilding

A release key signs a release record only after its holder has **built the commit themselves** and got the same tree hashes. Builds are reproducible (04 §7), so a signature attests "this tree is what that commit builds to", not "this machine made it". The root record sets the threshold (at least 2). A compromised build machine, or one compromised signer, cannot ship a release.

Anyone can check a release the same way: `./build release --verify <record>` rebuilds the commit and compares tree hashes.

### 5.3 Records

All records are ndb text plus a detached signature file, signed over their exact bytes.

```
# release.ndb  (signed by release keys, k of n)
release=42 name=2027.03 channel=stable commit=17931a2… prev=b2:4be1… vx-abi=1,2,3
set=base    arch=x86_64  tree=b2:9f3c… size=212M
set=base    arch=aarch64 tree=b2:0a71… size=198M
set=devel   arch=x86_64  tree=b2:c4d2… size=1.4G
image=iso   arch=x86_64  hash=b2:77e0… sha256=5d1a… size=640M

# heads.ndb  (signed by the heads key)
channel=stable release=42 record=b2:e1f9… expires=2027-03-21T00:00Z
channel=testing release=57 record=b2:30c8… expires=2027-03-21T00:00Z
    revoked=39 reason="fsd corrupts on power loss; CVE-…"
```

A node accepts a release record if: its signatures meet the threshold of release keys in the root record it trusts; its `prev` chain reaches the release the node runs (a fork of history is refused); and its sequence number is higher than the node's. It accepts a heads record if it is signed by the current heads key and has not expired. The heads record only says *which* release is newest; it cannot make a node accept a tree the release keys did not sign.

### 5.4 Threats

| Attack | What stops it |
|---|---|
| A peer or mirror sends bad data | Every object is checked against the hash that was asked for. The peer is dropped and reported in `/dist/status` |
| A peer sends endless data | Sizes are known from the record and the directory objects before fetching. Parsers of records and directories are fuzzed (04 §7) |
| An old, signed release is offered as new (downgrade) | Sequence numbers only increase. A node goes back only to a release it already holds, when the user asks (§10) |
| Peers withhold new releases (freeze) | Heads records expire. A node that has not seen an unexpired one within its policy's limit (default 14 days) says so in `/dist/status` and on the desktop, instead of reporting "up to date" |
| Releases from different versions are mixed | A release is one record with every tree hash; sets cannot be mixed across releases |
| A release key is stolen | It cannot reach the threshold alone. The root rotates it out |
| The heads key is stolen | It can delay updates or point at an older signed release, which nodes refuse as a downgrade; it cannot introduce code |
| An old catalogue is replayed to hide a revocation | A catalogue has a sequence number, which only increases, and an expiry, after which it is flagged stale (ADR-0014) |
| A dependency is swapped for another publisher's package | Dependencies name their publisher's key; no other key satisfies them (§3.4) |
| The build machine is compromised | Signers sign only trees they built themselves (§5.2) |
| The disk is altered while the machine is off | Verified reads (§4) and the boot chain's hashes (§7); keys sealed to the boot measurements do not unseal (§9.4) |
| Someone watches the network | Transfers are encrypted (§6.2). A peer learns which objects a node asks for, so which release it is moving to. That is stated, not hidden (§6.3) |

### 5.5 Your own distribution

The trust root is a file, not a company. A hacker who runs a fork builds releases with `./build release --sign <key>`, serves the store from their own node, and installs their root record. Their swarm then updates from their tree exactly as others update from the project's. Nothing in `distd` knows which root is "official".

## 6. Distribution

### 6.1 Sources

`distd` asks for objects from these sources, in this order, and takes each object from whichever answers first:

1. **The swarm.** Every node's store is a read-only tree in its namespace, so another node of the same owner reads it over the swarm's own mounts: `/n/tower/dist/store`. One node fetches a release from outside; the others fetch from it. The swarm is a cache, not an authority: every node checks every signature and hash itself.
2. **The LAN**, on networks the user has marked as trusted: peers found by DNS-SD (`_vxdist._tcp`), as `swarmd` finds swarm nodes (02 §6.3).
3. **Internet peers**, found through **rendezvous servers** that the heads record names: a rendezvous server is a 9Px file server with one file per release (`/peers/<record hash>`), listing peers' addresses and public keys. A peer that seeds writes its address there; one that fetches reads it.
4. **Mirrors**: plain HTTPS servers holding the store as files, reached through `tlsd` (00 D16). They are the fallback that works through any proxy, and the way a new node finds its first heads record. Peer-to-peer is never the only path.
5. **Local media**: the install ISO, or a USB stick, is a source like any other (§8).

### 6.2 One protocol

Every source except mirrors is read with 9Px over `9px+tcp` (02 §3.2), so there is no new protocol. With strangers, the Noise handshake uses keys from outside the swarm: the peer's key from the rendezvous list, and a key the fetcher makes for the session. The peer attaches strangers only to its store, read-only, without a token. That export is a narrow `exportfs` view, and the hostile-client test (04 §7) covers it. A peer limits each stranger's rate and number of connections.

### 6.3 Policy

Downloading uses the network and disk; seeding uses upload bandwidth and tells strangers that the node exists. So both are policy (rule 12), chosen at install and kept in `/dist/policy`:

```
check=daily         # never | daily | weekly: read a heads record
fetch=auto          # auto: download in the background (intent background) | manual
sources=swarm,lan,internet,mirror
seed=swarm,lan      # who may read this node's store; internet is opt-in
metered=pause       # pause | allow: on networks marked metered
keep=2              # previous releases kept bootable (§10.3)
approve=none        # none | owner: apply only releases the swarm owner has approved
freshness=14d
```

- **`apply` is not a policy.** The system changes only when the user asks (§9).
- **Approval by the owner.** With `approve=owner`, a node applies a release only once the swarm owner's key has signed an approval of its record, which `swarmd` gossips. That lets the owner hold a whole swarm at a known release, or try a release on one node first.
- **Timers follow rule 5.** A daily check is a deadline with hours of leeway, coalesced with other background work, so an idle machine wakes for it once.

## 7. On the disk

The installer lays out a disk with GPT:

| Partition | Size | Holds |
|---|---|---|
| ESP (FAT32) | 512 MiB | Three **boot slots**, `\EFI\vectra\{a,b,c}\`: each a Limine binary with its configuration enrolled, the kernel and `bootfs.tar`. One UEFI boot entry per slot, named after its release |
| System volume (`fsd`) | The rest | `/dist/store`, `/cfg` (the machine's configuration) and `/home`, as separate subvolumes so each can be snapshotted on its own |

- **A slot belongs to one release.** Its Limine configuration gives the BLAKE2B hashes of its kernel and `bootfs` (01 §10), and its `bootfs` holds that release's record and tree hash. So firmware measures Limine, Limine checks the kernel and `bootfs`, and `distd` serves the rest of the tree only as that tree hash verifies (§4).
- **Slots rotate:** one is current, one holds the previous release (the rollback target), one receives the next release. Each slot is a few tens of MiB (the boot image budget is 16 MiB, 00 §8), so the ESP size leaves room to grow.
- **Secure Boot.** The Limine binary in each slot is signed, because its enrolled configuration changes with every release. Releases are reproducible unsigned. The signature is appended afterwards, and verification strips it to compare. Which key signs (the project's, enrolled by the user, or the user's own) is an ADR before M10 (§16).

## 8. Installation

1. **Boot the ISO.** Limine loads the kernel, `bootfs` and one more module, `store.tar`: the release's objects for the sets on the image. The live system runs from them in memory. Because the firmware reads the install medium, the installer needs no driver for a CD, a USB stick or an ISO 9660 filesystem; it needs a driver only for the target disk (virtio-blk or NVMe, M5). The cost is memory: a machine needs RAM for the sets it installs, plus about 256 MiB.
2. **Check the image.** The ISO's hash is in the signed release record. Before booting, a user can check it on any system: the record lists a SHA-256 beside the BLAKE2b, and a host build of `vxverify` checks the signatures. After booting, the live system checks `store.tar` against the record in `bootfs`.
3. **Ask, then write.** `install` (a script over `/dist`; a `vxui` front end from M6) asks for: the target disk, the sets, the update policy (§6.3, each line explained), the node's name, and the first user. It shows a summary and writes only after a confirmation that names the disk and says it will be erased.
4. **Partition and copy.** It writes the GPT, formats the volumes, and copies objects from the live store into the disk's store. The copy is a fetch with the live system as its only source (§6.1, 5), so installing and updating share one path and the same checks.
5. **Make the first slot.** It writes slot `a` from the release's tree, creates its UEFI boot entry, and puts it first in `BootOrder`.
6. **Make the node's identity.** `keyd` generates the node key and seals it to the new slot's measurements (§9.4). The node joins a swarm later, with a pairing code (02 §6.2), or never.
7. **Reboot** into the installed system.

Installing with the network (the newest release rather than the ISO's) is the same steps followed by an ordinary update before the first reboot.

## 9. Applying an update

### 9.1 States

Each release `distd` knows of is in one state, shown in `/dist/releases/<seq>/status`:

```
seen ─► fetching ─► fetched ─► staged ─► trial ─► current ─► previous ─► (removed)
                                  │         │
                                  │         └─► failed  (did not come up healthy; old release current again)
                                  └─► (unstaged by the user)
```

- **seen:** a valid record is known, newer than the current release.
- **fetched:** every object of every installed set is in the store and verified. Under `fetch=auto` this happens in the background. `/dist/status` says how much it will download before it starts (`fetch=38M of 412M`).
- **staged, trial, current:** only after the user asks.

### 9.2 Staging

`sysupdate` (or the desktop's update prompt, or `echo apply 42 > /dist/ctl`) asks to apply a fetched release:

1. **Show what changes:** the release notes from its record, the sets, the download that remains, and any warning (a revoked release, `vx-abi` versions removed with apps that need them, approval missing under `approve=owner`).
2. **Snapshot** `/cfg`, and `/home` if the policy says so (§10.2).
3. **Write the free slot:** copy the kernel, `bootfs` and the signed Limine binary from the release's tree, sync them, and read them back against their hashes. A slot is written in full before it is named anywhere, so a power loss here leaves an unused slot, rewritten on the next attempt.
4. **Reseal keys** to the new slot's measurements (§9.4).
5. **Set `BootNext`** to the new slot's entry. `BootOrder` is unchanged, so the current release stays the default.
6. **Reboot,** now or when the user chooses. Until then, `unstage` undoes steps 3–5.

### 9.3 Trial boot and commit

UEFI's `BootNext` boots an entry once and then clears itself. So the new release gets exactly one boot, and the firmware's ordinary boot order, which still starts with the old slot, is the rollback:

- **If the new release crashes, hangs or is powered off** before it commits, the next boot is the old release, with no code from the new one involved. A hardware watchdog, where the machine has one, turns a hang into a reboot. `distd` on the old release then marks the new one `failed` and tells the user what happened.
- **If it comes up healthy,** `distd` commits: it moves the new slot to the front of `BootOrder`. Healthy means: every service its manifests mark `restart` is running and has not restarted for 60 s; the console shell or the desktop session has started; and every check in `/cfg/dist/checks/` (executables, so a user can add their own) has exited with an empty exit string. The deadline is 5 minutes.
- After the commit, the release is `current` and the one before it `previous`. Rolling back from here is the user's choice (§10.1).

The kernel cannot write UEFI variables today. How it gains that, narrowly, is an open question (§16).

### 9.4 Keys sealed to the boot chain

`keyd` seals the node key to the TPM's measurements of the boot chain (02 §6.2), and a new release changes them. Because a release is reproducible and its hashes are in the signed record, `keyd` can compute the new release's measurements before it boots, and add a second seal under them while it still runs the old one. Both seals stay until the old release is removed, so either slot unseals the key and a rollback keeps the node's identity. A slot whose measurements match no seal (a modified kernel) cannot unseal it, which is the point of sealing.

## 10. Rollback

### 10.1 The system

`echo rollback > /dist/ctl` (or `sysupdate rollback`) makes the previous release current: it moves its slot to the front of `BootOrder` and reboots. The base system needs nothing else, because it never changed: the previous release's tree is still in the store, and its slot still on the ESP. Rolling back to a revoked release warns first and is still allowed; it is the user's machine.

The firmware's boot menu lists every slot by its release name, so a release that boots but cannot reach a shell can be left from the firmware, without the OS.

### 10.2 Configuration and files

A release never contains the machine's state, so state is the only thing an update can damage, through a new release that rewrites a file in a newer format.

- **Before staging,** `distd` asks `fsd` for a read-only snapshot of `/cfg`, and of `/home` when the policy says `snapshot=cfg,home`. These are the copy-on-write snapshots that M5's filesystem must provide for agent undo (03 §8.5, 04 §6): one mechanism serves both.
- **Rolling back the system restores `/cfg`** from the snapshot taken when the failed release was staged. Changes made to `/cfg` since are listed first, and the newer `/cfg` is itself kept as a snapshot.
- **`/home` is never rolled back automatically.** It holds work done since the update. Snapshots appear read-only by date, as Plan 9's dump did: `/n/snap/2027/0314/home/…`. The user copies back what they need, or asks for a whole-tree revert explicitly.
- **Rule for releases:** a release that changes a format in `/cfg` or `/home` reads the old format and writes the new one only when it saves a change. Its release notes say so, because a rollback after such a save leaves the old release a file it may not read.

### 10.3 Retention

- `keep=2` keeps two previous releases bootable, within the three slots and in the store (a fourth needs a fourth slot; the policy grows the slot count with the ESP).
- `distd` collects objects reachable from no retained release, staged release or installed app. It never collects the current release or the rollback target.
- Snapshots taken for an update are dropped when that update's release leaves the retained set, unless the user has kept them.

## 11. `/dist`: the file interface

`distd` serves `/dist` (rule 10), with `.help` and `.schema` like every service:

```
/dist/
    status        state=idle channel=stable current=41 next=42 next.state=fetched fetch=38M/412M heads.age=2h
    ctl           (write) check · fetch [seq] · apply seq · unstage · rollback [seq] · gc · seed on|off
    policy        the policy above (§6.3); written by the user, not by programs without the grant
    root.ndb      the trust root in use
    releases/42/
        record    the signed release record      notes   its release notes
        status    state=fetched sets=base,desktop missing=0 slot=-
        log       what distd did with it, as ndb events
    apps/hx/
        manifest  lock  status  tree/  log
        locks/    earlier locks, kept for app rollback until gc
    catalogues/<key>/   each publisher catalogue held: catalogue, sig, status (seq, expires, stale)
    store/        objects by hash; read-only; what peers mount
    peers         current sources, with bytes moved and objects refused
```

- **Who may write `ctl`:** the user's shell and the desktop's update surface. An agent's namespace template does not include `/dist` (02 §7), so an agent cannot update or roll back the system; it can read `status` if the user grants that.
- **The commands for people** are scripts over these files: `sysupdate` (as 9front's) for releases, `app install|remove|list|update|rollback|why` for packages, where `app why lua` shows which installed apps need a package, and at what versions.

## 12. Failure cases

| Case | Result |
|---|---|
| Power lost while fetching | Objects are written under a temporary name and renamed after verification. The fetch resumes |
| Power lost while staging | The slot is incomplete and named nowhere (§9.2). Staging starts again |
| Power lost during the trial boot | `BootNext` is spent, so the next boot is the old release, and the update is marked `failed: no commit`. The user can apply it again |
| A dependency's publisher revokes the version an app's lock uses | `/dist/status` and the app's status say so; `app update` re-resolves past it. The app is not changed until the user asks |
| A catalogue cannot be fetched | Installed apps are unaffected, since they run from their locks. Installing or updating anything that needs that publisher waits, and says which catalogue is missing |
| Disk full | Space is computed from the record before fetching, and the fetch is refused with the amount needed. `gc` and a lower `keep` are offered |
| No peers have an object | The fetch waits with backoff and reports which source has failed; mirrors are tried last |
| The clock is wrong | Heads freshness depends on time. Until NTP (M8), freshness is advisory and `/dist/status` says so |
| The ESP is damaged | The firmware boots no slot. The ISO's live system can repair the slots from the system volume's store (`install --repair`) |

## 13. Budgets

Added to 00 §8 when the milestone that makes each measurable lands:

| Budget | Target | From |
|---|---|---|
| Install from the ISO, `base` set, to NVMe | < 60 s on T1, after the user's last answer | M5 |
| A check with no new release | One heads record, < 4 KiB moved | M8 |
| Download for a release that changes one program | That program's changed blocks plus directory objects, < 2 MiB beyond it | M8 |
| Staging a fetched release | < 5 s | M10 |
| Rollback | One reboot | M10 |
| Store cost of keeping the previous release | Only the objects it does not share with the current one | M5 |
| Idle cost | No wake-ups beyond the scheduled check, coalesced with other background work (00 §8's idle budget) | M6 |

## 14. Where the pieces land

| Milestone | Pieces |
|---|---|
| **M5 Storage** | The store and tree format, `distd` with verified reads, `/cfg` and `/home` subvolumes and snapshots, `install` from the ISO with `store.tar`, `./build release` (unsigned), slots written to the ESP, rollback by hand. Monocypher is vendored here rather than at M8, because the first signature check is here |
| **M8 Swarm** | Release and heads records signed and checked; sources from the swarm and the LAN; NTP-backed freshness; owner approval |
| **M9 AI** | Mirrors through `tlsd`; the `ai` set |
| **M10 Self-hosting and T1 hardware** | Trial boot with `BootNext` and commit; keys resealed for a staged release; Secure Boot signing (ADR); internet peers and rendezvous servers; independent signers rebuilding on VectraOS itself; the `devel` set. This replaces "signed A/B image updates" in 04 §6 |
| **M6 onwards** | Packages, dependency resolution, catalogues and locks, once there are apps (`vxui`, M6); the desktop's update surface. Resolution is a host-testable library (`lib/vx-dist`), fuzzed on hostile manifests and catalogues like the other parsers |

## 15. Heritage

| Taken from | What | Changed |
|---|---|---|
| Plan 9 venti and fossil | Content-addressed blocks; dated, read-only dump trees | Hash trees per file for verified random reads; dumps from the CoW filesystem (M5) |
| Plan 9 `replica`, 9front `sysupdate` | The system is one tree, pulled whole | A signed, reproducible tree, not a log of file changes applied in place |
| OpenBSD | Release sets; `signify`'s small Ed25519 signatures | Sets are trees in a store, not tarballs |
| The Update Framework (TUF) | Root, release and timestamp roles; thresholds; freeze and mix-and-match defences | Fewer roles: one release record replaces TUF's targets and snapshot metadata, because a release is one tree |
| ChromeOS, Android A/B | Boot slots and a one-shot trial boot | Slots name trees in a shared store, so a slot is small and keeping more is cheap |
| OSTree, Nix | Several system trees sharing objects; atomic switching; many versions of one library side by side | The base has no package graph; side-by-side versions come from per-app namespaces, not rewritten paths |
| Go modules | Minimal version selection; lower bounds only; a lock of exact hashes | The same algorithm, over signed packages from many publishers |
| BitTorrent | Fetching verified pieces from untrusted peers | Over 9Px, the system's only protocol, not a second one |
| Reproducible Builds, Debian's rebuilders | Independent rebuilders vouching for a binary | Their signatures are the release signatures (§5.2), not a separate check |

## 16. Open questions

1. **Writing UEFI variables.** `BootNext` and `BootOrder` are UEFI runtime variables, and runtime services run in kernel mode with the firmware's mappings. The choices are a narrow kernel call for variable services only, given as a capability to `distd`, or a boot-time mechanism in Limine that reads a trial flag from the ESP and so needs no runtime services. ADR before M10.
2. **Who serves the verified base tree.** `distd` serving it and acting as its pager (and so a trusted pager, 01 §5), or `fsd` with a verified-tree mode that `distd` feeds. Decided with the M5 filesystem.
3. **Block size and chunking.** Fixed 64 KiB blocks make verified random reads simple; content-defined chunking would make deltas smaller when bytes shift within a file. Measure on real releases before deciding; fixed until then.
4. **The Secure Boot key.** Users enrolling the project's key or their own, against a Microsoft-signed shim so that machines boot with their default keys. The shim brings a second loader and trust in a third party's CA.
5. **Internet peer discovery.** Rendezvous servers are a few points the heads record names, so one being down is tolerable but all being down leaves mirrors only. A first-party DHT removes that dependence and adds a large, exposed component. Start with rendezvous servers, and revisit with data.
6. **Machines without UEFI variables:** Apple Silicon through m1n1, and boards whose firmware does not keep them. They need the boot-time mechanism of question 1.
7. **Discovering publishers.** Resolution follows keys that manifests name, so it never needs a directory of publishers. Finding an app in the first place does: today it is a reference the user gets from somewhere. Whether the system should ever ship a way to search catalogues the user has chosen, without making any of them trusted by default, is left until there are apps to find.
8. **Shared libraries.** Per-app resolution works with static linking and with dynamic linking alike; the second needs a dynamic loader, which the system does not have yet. 09 §4.8 sets the direction for the system's own libraries: dynamic, once the loader exists. Whether libraries ship as `.so` files, as static archives that the app's own build links, or both, is decided with the first library packages.
9. **Disk encryption.** The system volume encrypted with a key `keyd` seals to the boot chain, unlocked by a passphrase where there is no TPM. Its interaction with resealing (§9.4) is the same problem, already solved there.
