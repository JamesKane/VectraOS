# D105. V4's scope: Taisce on virtio-blk through the block class, its queries over Node, its budgets on the device; S2 later (2026-10-18, decided; extends D8, D76, D82)

V4 is "Taisce on disk". Most of Taisce is already here: V3 lifted
todhchai's S0 and S1 whole (`fs/taisce`, IMPORTS.tsv at 527ff94).
That means attributes, indices, the query language and its planner,
live queries from the change journal, the copy-on-write tree's commits
by superblock flip and the intent log. The crash, shadow-model and
query fuzzers came with it, in TaisceTests, so `vx ci` runs them on
every change.

What V4 lacks:

- **A disk.** The block class is ramdisk(4)'s `sdZ0` alone. Our
  virtio-blk is its constants; todhchai's driver speaks a typed IDL,
  not D82's sd directories.
- **The Node operations.** fs(4) refuses `query`, `live`,
  `declareIndex`, `wholeListing` and `map`.
- **A measure of its budgets**, and its pages.

This decision settles V4's order and four choices the roadmap left open.

- **The block class first (D82).** One sd library serves ramdisk(4)
  and virtio-blk alike:
  - `/dev/sdXX/ctl`, `raw` and `data`, and a file for each GPT
    partition, with bulk on the ring;
  - virtio-blk's device code lifted from todhchai, under the sd files,
    not its protocol.

  GPT comes now, because V6's boards put the ESP and Taisce on one NVMe
  disk. Taisce's write barriers become the device's flushes
  (`VIRTIO_BLK_F_FLUSH`): the crash harness proves only what the device
  honours, so the block class's flush is in the harness's model. NVMe
  stays with the boards (D76).
- **Then Taisce on it, surviving reboots.** fs(4) mounts a volume on a
  virtio-blk disk. `vx` lifts todhchai's `mkfs-taisce` and
  `fsck-taisce` as subcommands. A boot test writes, then reads back
  after a cold boot and after a warm one.
- **Then the Node operations.** fs(4) serves `query`, `live`,
  `declareIndex`, `wholeListing` and `map`. It lifts todhchai's fs
  service (watches and live queries from the journal) and its mapped
  files' cache.
- **Then the budgets, on the device.** A file bench in the services
  boot, as `node.file_copy` is, after todhchai's `taisce-bench`: the
  cached 4 KiB read, a live query's update, fsync's p99, a group commit
  of 64, and four readers against one. They are judged by `vx bench`
  under KVM.
- **Then the manual on a volume.** `vx` writes `lib/man` into the disk
  image, and the shell's manifest binds it over bootfs's. Also
  `taisce(4)` and the query language in section 6.

**The four choices.**

- **S2 is not in V4.** Snapshots as dated directories, send and
  receive, and per-volume encryption are design only, even in todhchai
  (its M9; no code). Encryption comes with the boards (V6), which carry
  data off the bench; send and receive come with 9gate's node-to-node
  links (V7), which carry them. Each milestone's section names its
  part.
- **The Tracker budget moves to V5.** "Tracker listing 100k entries,
  warm, < 100 ms" measures V5's file manager. V4 gets the part of it
  that is Taisce's: a `wholeListing` of 100k entries through fs(4),
  warm, under the same 100 ms; V5 measures Tracker's on top of it.
- **fsync's p99 is judged on hardware.** Under QEMU it measures the
  host's disk and QEMU's cache mode. The bench uses `cache=none` on a
  file of this machine's disk and records what it gets. The limit holds
  on a board (V6), as `ring.kicks`'s does off a hypervisor.
- **vx builds the disk image.** It makes the volume on the host (mkfs)
  and copies the manual in, rather than the node formatting a blank
  disk at first boot, so every boot starts from a known disk. A test
  that needs a blank one asks for it.

Left out: todhchai's FUSE mount of a Taisce image on the dev machine,
useful for looking into an image but not needed for V4's exit;
`vx` may gain it later.

**Exit** (V4's in the roadmap):
- the file budgets are green under KVM (fsync's reported);
- the crash harness passes every write prefix over the block class's
  flush semantics;
- a file written survives a cold boot and a warm one.
