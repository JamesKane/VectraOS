# Roadmap

Each milestone has exit criteria. A milestone is done when its criteria pass
under `vx ci` and every budget it introduces has a running check
(principle 13). This file looks ahead: a finished milestone keeps a brief
here, and its history, step by step, is in git and `docs/decisions/`.

## Where things stand (2026-11-20)

- **V0 to V7 are done**: the kernel, the userland, the bring-up link,
  Taisce, the desktop, the Orange Pi 6 Plus and the swarm. amd64 and arm64
  run everything; rv64 runs its whole QEMU suite, tier 1 included.
- **The board** runs VectraOS beside its FreeBSD, its `/data` an encrypted
  volume unlocked at boot by a swarm member.
- **Under way:** V6f, the Orange Pi 6 Plus feature complete: the focus
  board until every device on it is driven (the owner, 2026-11-20),
  the GPU, the video codec and the NPU included. First the Sky1's I2C
  controllers and the RX8900 real-time clock on them (D163), with its
  GPIO controllers.
- **Paused:** V6b, the Orange Pi RV2 (the owner, 2026-11-20). Its
  kernel runs on the board's harts from our own devicetree (D154), V3's
  link and the native suite pass there, 8 of its budgets over their
  limits (the ring's two accepted), its microSD is /data, and power(8)
  keeps its thermal zones and steps its CPUs (D160-D162). The RV2
  notebook's "Handoff, 2026-11-02" is where to pick it up.
- **Next:** V6b's rest, then the amd64 board (V6c), which waits (the owner),
  then the devicetree boards (V6d, V6e: D154, D155); then compute (V8). Below, after the briefs: what the finished
  milestones left open, then the milestones ahead.
- **Backlog (proposed):** eight items from a review of the Rust
  reenvisioning (`../Vectra-OS`), B1 to B8 below the milestones:
  checks shown able to fail, supply leases, observed confinement and
  coherence, whole-machine checks, and smaller ones.
- **Testing (D88):** `vx test --changed` runs what a change risks, reading
  build files for what they name. Each arch's QEMU tests run in parallel
  and take under 5 minutes, and a check that flakes is removed, not
  retried. The full suite, `vx ci`, closes a milestone.

Milestones run in order. Each one puts in place what the next one
depends on. Board bring-up is attempted only once its dependencies are in
place, each finished in QEMU first (D76).

## V0. Ground — done 2026-10-15

croi lifted in, booting and passing its self-tests on three arches; the
bench, the trace format, `vx`, the size budgets.

## V1. Setup-engine kernel — done

154 calls cut to 91 (D18-D38), the hot calls batched (D39-D42), the one
ring with RingCheck (D43), ports and the debuglog as rings (D44).

## V2. Userland base — done 2026-10-16

One ABI (D45); the floor, Sys, libc, ld, the trace; tier 1 (D47); IPC,
Node and the launcher; time (D48) and `/env` (D81); byte streams (D46);
drivers under devmgr (D74, D83, D84); the console and plumber (D85); the
manual (D86).

## V3. Bring-up link (D15, D77) — done 2026-10-18

`/proc`, crypto, `/net` with cs and dns; 9gate, factotum and `vx cpu`;
warm boot (D101), the link on rings (D103), `trace` (D102).

## V4. Taisce on disk — done 2026-10-18

The block class and virtio-blk (D82, D106); `/data` across reboots with
queries, live queries, whole listings and mapped files; the file budgets
(D105).

## V5. Desktop (D107-D123) — done 2026-10-22

The text stack, UICore and themes as data; Radharc, the SDK and Kit, rio
and vt; Tracker, Deskbar, Settings, workspaces, notices, the lock
screen; the GPU through Venus; guide and hot reload. Shared libraries
for tier 1 followed (D124), and fs's page cache (D131, D145).

## V6. Orange Pi 6 Plus (D69, D125-D147) — done 2026-10-29

The platform, rge(3), NVMe, xHCI and HID, the GPU's first probe, the
desktop on its display (linlon(3), dptx(3)); the native suite and V3's
link pass on the board, and Taisce's crash harness on its NVMe. Four
items were moved out by the owner (below).

## V7. Edge: 9gate and the swarm (D148-D153) — done 2026-10-30

9P2000 to Linux's v9fs (pjdfstest, docs/v9fs-conformance.md) and 9front;
a PC mounting the board's `/dev`; `cpu -h` between nodes; 9P2000.vx
(renames, typed attributes); the swarm (each node's key, the swarm file,
membership as trust, the swarm service); Taisce's S2 (dated snapshots,
send and receive, AES-256-XTS with passphrase and swarm slots). The LAN
bulk read was accepted below its budget (below).

## Carried forward

What the finished milestones left open, by area. Each is work to pick up,
not history; the measurements behind them are in git.

**Kernel and runtime**
- The kernel's budgets on the board: 7 of the native suite's 17 over
  (`syscall.null` 173 ns, `ipc.channel_call` 2.6 µs, `port.wake_median`
  6.3 µs, `counter.wake_median` 5.8 µs, `ring.per_1000_slots` 14 µs,
  `ring.round_trip` 352 ns, `trace.probe_enabled` 60 ns), for D127's
  comparison to judge.
- The Orange Pi RV2's ring budgets, accepted (the owner, 2026-11-02):
  `ring.per_1000_slots` about 128 µs (limit 10) and `ring.round_trip`
  about 930 ns (limit 300). Each is the X60's cross-hart line transfers,
  about 130 ns one way with none overlapped; prefetch, Zicbom and
  FastForward's slots didn't reach the limits, and the bench now lets go
  every 64 slots (D159, the RV2 notebook).
- A wake costs ~1.7 µs a hop, 0.75 of it the IPI to an idle CPU; idle
  CPUs keep sleeping in WFI (the owner), so cuts are software only.
- A fresh-page fault spends 0.27 of its 0.93 µs scanning fs's mappings
  linearly (`handleFault`, `mapPresent`).
- The floor's stdout mixes the lines of a process's threads printing at
  once (one line buffer, locked a character at a time).
- `port.wake_p99` (V2's exit, 14.7 µs against 9.1), to compare
  interleaved; arm64's RTCs (rv64's: the Orange Pi RV2's P1 PMIC, time(4)); the warm boot's return in two
  speeds (0.42 and 0.62 s).
- m2 3-5 times slower on the board than under KVM, cause open.

**Files**
- `fs.refault_4k` ~45 µs on the board: BLAKE3 checking the block ~6.8 µs
  (kept, the owner), `NodeBulkChannel.read` growing an Array each read,
  the pager reading one range at a time and never ahead.
- `fs.seq_read_64m`'s limit, and `services.rss` with the cache in it (the
  owner's, D131).
- A pager FAIL faults a mapping's reader instead of returning EIO;
  CrashTests don't cover write-behind.
- A volume filled to its last blocks can't be emptied, and fs then commits
  without end (taisce(4)); nothing holds a writer back while its pages
  wait for a commit (a 512 MiB node writing 256 MiB went out of memory).
- Encrypted volumes: a new one can't be made on a node without a
  keyboard, and fs restarted on one comes back locked (fs(4)).
- The idle board's 361 MiB resident, 253 MiB of it fs's six bitmaps the
  volume's size: sparse sets for the five nearly empty.

**Desktop and GPU**
- The GPU: hotplug acted on; per-output scale, EDID names and colour;
  suspend in devmgr's protocol; UIGPU and buffer objects (D121);
  `theme.compose.4k` 6-7 ms against 1.5.
- The shell: Deskbar's tray replicants, GPU and AUDIO gauges, Restart and
  Shut down, and its idle wakeups untested; the Inspector's jobs,
  threads, handles, IPC graph and tracer; Do not disturb.
- Settings' idle wakeups are untested: settings-test's check that an
  unchanged Keyboard pane stays asleep over 3 s failed two runs in three
  on a loaded host (2026-10-31) and was removed; judge it on a quiet
  machine before it returns.
- Themes: Appearance's Edit and Save as theme, an output's layer and app
  rules, Graphite, Indigo Magic and NeXT; themes and fonts on the volume
  (D133, proposed).
- Translucent windows and blur behind them, not designed yet.
- Studio's asks of the desktop (`docs/studio.md` §10, D96): Radharc's
  gated `capture` with damage regions, Deskbar's capture lamp, NV12 and
  P010 buffers.
- The terminal's throughput (D134, proposed).
- Hot reload: TLS in loaded objects, pointer input in HotFrame;
  `reload.module_10k` missed and accepted (1.5 s against 1 s).
- The kit frame's reference images; `cpu -h` from a rio window, not yet
  run; Tracker's slow menus on the board.

**The Orange Pi 6 Plus**
- `boot.console` 118 ms against 100 (deferred): time the kernel's phases,
  start the console earlier.
- The idle desktop's wakeups, 5,582 in 60 s against 0: power's thermal
  poll, and rge's interrupts, which a networked board's budget must
  allow for.
- D127's comparison: VectraOS's own column (its libc needs posix_spawn,
  nftw and clock_nanosleep), the best-mechanism column, and the bench
  drive's, network, loaded-latency, boot_shell and bash rows.
- Firmware as packages per device, amending D4; a tested
  critical-temperature shutdown; HBR3, MST and audio, and the other
  DisplayPort outputs.

**Network and the swarm**
- The LAN bulk read, accepted below 112 MB/s (the owner, 2026-10-30):
  84-86 MB/s off the board's export, 111-112 onto it. The board's send
  path is the work: one connection's serial chain (encrypt, write into
  net, segment, send), net's main thread the busiest; a second
  connection adds about 40%.
- 9P2000.vx: memory (a program run from an import needs VMEX), watch,
  query and lease, each waiting for its first user.
- v9fs's remaining pjdfstest failures, each a Node feature: symbolic
  links, special files, owners, modes, atime.
- The `auth` role (a multi-user swarm); `/swarm/pool` is V8's.

**Tools**
- rc and its commands against 9front's (`vx rc-oracle`, D70).
- `esp-cpu` and `esp-board-cpu` go stale unless built by their own
  targets.

## V6f. The Orange Pi 6 Plus, feature complete (arm64)

The focus board until every device on it is driven (the owner,
2026-11-20), after V6's platform, display and NVMe. Its facts are in
`docs/boards/orangepi-6-plus/`; the hardware's functional specs are
chinese-wall's `sky1-*`, `panthor`, `linlon-vpu` and `zhouyi-npu`
(`../chinese-wall/specs`), which a driver is written from. Each item
lands with its page, its host tests and its `support.tsv` row, and is
checked on the board through the cpu image and a warm boot.

1. **Low-speed buses and the clock** (D163): the Cadence I2C
   controllers (`CIXH200B`) and devices on them as links; the RX8900
   real-time clock (`\_SB_.I2C3.RTC0`) read by the time service on
   arm64; the Cadence GPIO controllers (`CIXH1002`, `CIXH1003`) and
   `GpioInt`/`GpioIo` links. Then SPI (`CIXH2001`), the USB-C PD
   controllers (`CIXH200D`) and PWM.
2. **Power:** the idle governor over `_LPI` with the GPT as the
   always-on timer (KP, sky1-soc 03), a CPU frequency governor and
   floor, the little cluster's temperature, a tested critical
   shutdown; the idle desktop's wakeups and resident memory (Carried
   forward).
3. **Audio:** an audio class fed by a ring (V9's, brought forward), HDA
   (`CIXH6020`) with the ALC269 (sky1-audio), and DisplayPort audio.
4. **Display:** the other DisplayPort outputs, HBR3, MST and hotplug
   acted on.
5. **Before the large devices,** the backlog's adoptions (below the
   milestones), in their order: B1 (checks shown able to fail), B6
   (model checks beyond the ring), then B2 (supply leases: mali(3)'s
   power-up loses its own order) with B3 (coherence and own-MMU
   masters as observed) and B5 (one owner a register page). B7, B8
   and B4 fit beside any item. With them, firmware for devices (D164,
   proposed, amending D4): how a device's blob (the GPU's CSF
   firmware, the video codec's) is shipped, named and given to its
   driver. Items 6 to 8 come after.
6. **GPU:** mali(3) from its probe to running command streams under its
   firmware, its MMU and a job scheduler (panthor's spec), then UIGPU's
   buffers and Vulkan compute and rendering (D62, D121).
7. **Video codec:** Mali-V (`CIXH3010`, linlon-vpu): H.264, HEVC and VP9
   decode, H.264 and HEVC encode.
8. **NPU:** the Zhouyi X2 (`CIXH4000`, `CIXH4010`) as a backend of V8's
   `/dev/accel`, whose protocol and CPU executor come forward for it.
9. **USB:** mass storage (V6c's item 1 needs it too) and devices beyond
   HID boot devices.

**Exit:** each device on the board is experimental in
`docs/hardware/support.tsv` with its test, or moved out by the owner;
the native suite and V3's exit commands pass on the board.

## V6b. Orange Pi RV2 (rv64)

The rv64 board (D51), after V6's board (D69) and on the same V3 link.
Its facts are in `docs/boards/orangepi-rv2/`, and its handoff, where
to start, in that notebook's "Bring-up": it is driven from the Mac
Studio, which has the SD card slot (the owner, 2026-10-30). The
firmware path is decided: the loader reads the DTB first (D51). rv64
builds and tests against RVA22 in QEMU (`-cpu rva22s64`) before the
kernel runs on the board.

1. **Console first:** the loader and kernel print through UART0, a
   16550-style UART at `0xd401_7000` with 32-bit registers 4 bytes apart.
2. **The platform:** 8 harts through SBI HSM, the PLIC, the SBI timer,
   and DMA within each bus's window, with no IOMMU.
3. **Ethernet:** a K1 EMAC driver in the net class (RGMII, Motorcomm
   PHYs), whose bus reaches only the first 4 GiB of DRAM. It is the
   first device devmgr finds in a devicetree, so D154's pieces come
   with it: `lib/fdt`, `vx dtc` and our trees on the ESP, `bus/dt`, and
   links to the APBC and APMU clocks and resets.
4. **The V3 link on the board,** as for V6's.
5. **Then the rest:** eMMC and microSD (SDHCI, below 2 GiB, done), PCIe
   with a DesignWare MSI backend (written, D156: k1-pcie(3) and its PHYs
   and slot power, devmgr binding what it finds, the kernel's MSI frames;
   the link waits for a drive), USB 3 for HID (done), the P1 PMIC's
   power-off (done; reset is the SoC's watchdog, which also runs as the
   kernel's: done), the thermal sensor, its zones' critical trips
   kept by power(8) (D160, done), and the CPUs' clocks and supply
   stepped by power(8) at a passive trip (D161).

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- RV2 power-on → console, and warm-boot turnaround, are within budget.
- The RV2 and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V6c. The AMD tower (amd64)

amd64's first board (D69): the Ryzen 9 7900X tower, after V6b and on
the same V3 link and Realtek driver. Its facts are in
`docs/boards/pc-7900x/`. It boots from a USB stick only, when the owner
frees the machine; its disks hold other work.

1. **Console first:** the board has no serial port (no SPCR, DBG2 or
   16550), so the console is a GOP framebuffer text console (V6's item
   5), or a PCIe serial card whose address the loader is told.
   **Queued (owner, 2026-10-24): logs to a USB stick,** in case the
   serial card isn't here in time: the console's log written to the
   stick the tower boots from, read on the dev machine afterwards. It
   needs USB mass storage first (bulk-only transport and SCSI, under
   xhci(3), into the block class; xhci drives HID and hubs only today),
   then FAT32 written as well as read (D132, amending D8), which UEFI
   loading needs anyway: a node writing its own ESP. The log is a file
   on the stick that the dev machine opens anywhere.
2. **The platform:** xAPIC as firmware leaves it, the LAPIC one-shot
   timer (no TSC-deadline on AMD), and AMD-Vi with interrupt remapping:
   croi's K12b, tested so far only in QEMU.
3. **Ethernet:** the RTL8125, through V6's Realtek family driver.
4. **The V3 link on the board,** as for V6's.
5. **Then the rest:** NVMe (Taisce's volumes, as V6's) and xHCI for HID. The Radeon 610M (RDNA 2)
   waits for D62's desktop track.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the console budget
  scrape.
- Power-on → console, and warm-boot turnaround, are within budget.
- The tower and its required components are experimental in
  `docs/hardware/support.tsv` (D66).

## V6d. Orange Pi 5 Plus (arm64, devicetree)

The second arm64 board and the first arm64 one with a devicetree
(D154), on mainline U-Boot's EFI (the owner, 2026-10-31). Its facts
are in `docs/boards/orangepi-5-plus/`. It needs D154's pieces from V6b
(`lib/fdt`, `vx dtc` and the shipped trees, `bus/dt`, links), and adds
arm64's tables.

1. **arm64's tables from the tree,** first on QEMU's `virt` with no
   ACPI, then the board: UART2 at 1.5 Mbaud, the GIC-600 with the ITS
   fix (erratum RK3588001), PSCI.
2. **PCIe:** the DesignWare host and its PHYs, with the CRU's clocks
   and resets as providers; then NVMe and the RTL8125s, for the V3 link.
3. **Then the rest:** the fan (failing safe), eMMC and microSD, USB 3.

**Exit:** V3's exit commands and the native suite pass on the board;
the board and its required components are experimental (D66).

## V6e. VisionFive 2 (rv64, below RVA22)

A small, old rv64 board, run through fallbacks (D155): four U74 harts
at `rv64gc_zba_zbb`, no V, Svpbmt, Zicbom or Sstc. Its facts are in
`docs/boards/visionfive-2/`. It comes after V6b, on the same DT path.

1. **The floor dropped** (D155), after the K1's cost is measured on the
   RV2, and the kernel's boot-time fallbacks.
2. **The board:** the console, four harts, the L2 controller's flush as
   a board rule, then the PLDA PCIe host for NVMe and the USB hub, and
   the DesignWare MACs.

**Exit:** V3's exit commands and the native suite pass on the board;
the board and its required components are experimental (D66).

## V8. Compute

- **The Q8B's bring-up first** (D69: it moved here from the first board's milestone, since the CDSP
  and the Adreno need it), on V3's link:
  - Console: the loader and kernel print through the GENI UART (SPCR
    interface type 0x13), a polled driver after AbyssBSD's
    `uart_dev_qcom_geni.c`, with a register-level model test, since QEMU
    has no GENI. It needs a 1.8 V USB-serial adapter on the 40-pin
    header: pin 6 GND, pin 8 TX (gpio63), pin 10 RX (gpio64). Never
    connect it to the 3-pin header by USB-C, which is 12–20 V power in.
  - The platform: GIC with ITS, SMP across the A78C and X1C clusters,
    PCIe segment 4 behind UEFI's TC9563 switch, and the SMMUv3 under the
    hypervisor's rules (AbyssBSD's `lessons.md`).
  - Ethernet: a TC956x driver (XGMAC2, XPCS, QCA8081 PHY) in the net
    class, after AbyssBSD's `tcx` driver and `ethernet-tc956x.md`, with
    the DMA address offset of `0x10_0000_0000`.
  - The V3 link on the board, then NVMe, `qcom-gcc` and USB for HID.
  - The Q8B and its required components become experimental in
    `docs/hardware/support.tsv` (D66).
- The `/dev/accel` protocol, `.vxm` artifacts, the `vxc` host compiler
  (ONNX/StableHLO → TOSA) and the CPU TOSA executor.
- The swarm's `/swarm/pool`: leases for accelerators, and remote
  `/dev/accel` (from V7, D148).
- The CDSP backend on the Q8B: a first-party FastRPC driver following
  AbyssBSD's NPU notes.
- Adreno Vulkan compute.

**Exit:**
- One `.vxm` runs on the CPU, the CDSP and Adreno, with results checked
  against the CPU reference.
- The camera → NPU → render path does 0 CPU pixel copies.

## V9. Wasm and games

- `wasmd`, interpreter first, then AOT through `vxc`.
- WASI over nodes and rings, a guest ABI under D80's rule: mapped onto
  Plan 9's interfaces, its shapes in nothing native.
- A reference game: a frame-loop intent, input and audio rings, Vulkan.
- Audio output, which the game needs first and V14's player reuses: an
  audio device class fed by a ring, with drivers for virtio-snd in
  QEMU, HD Audio on amd64 and the Orange Pi 6 Plus's output. No
  milestone before this one plays sound.
- Record and replay over the hot-reload state block (D92), and Wasm
  plug-ins: a `wasmd` process serving a host's plug-in interface.
- **Designs to write when V9 starts** (placeholders, from the NeoDarwin
  API study, carried by both donors):
  - Game controllers: one HID gamepad class with per-family drivers and
    a controller database as data (F-214; todhchai SDK §6, NeoVectra's
    `/dev/input/gamepads`).
  - Variable refresh and tearing for the frame intent (todhchai's game
    mode).

**Exit:**
- A Wasm build of a small Bevy or Godot sample runs at its frame budget on
  the Orange Pi 6 Plus.
- The reference game runs with hot reload and looped replay, with no
  frame missed at a reload (`reload.frames_missed`).

## V10. The Ghost (D90, proposed)

The opt-in, local-first agent (`docs/ghost.md`), on V3's `/net` and
factotum, V4's Taisce, V5's trusted path, V7's swarm and V8's
accelerators. Earlier milestones design in what it needs
(`docs/ghost.md` §11): effect classes in `.schema`, structured
failures, a Taisce origin attribute, non-realtime GPU queues, and the
executor's decoding ops in V8's `.vxm` format.

1. Watchers, signatures and insights, with no model.
2. The CPU runner and local models, as `.vxm` from `vxc`.
3. The GPU and NPU runners, and placement.
4. Evolution and automation (and the time trigger, `docs/ghost.md` §13).
5. Frontier providers, with a first-party TLS 1.3 client.

**Designs to write when V10 starts** (placeholder): the ciphers TLS 1.3
needs that D89's library lacks (AES-GCM, P-256 and RSA signatures),
checked against libsec as D89's are.

**Exit:**
- On the Orange Pi 6 Plus, a planted driver failure yields a cited
  insight from a local model, whose fix runs and undoes.
- An automation the Ghost wrote runs with the Ghost disabled.
- The Ghost's budgets (`docs/ghost.md` §10) are green.

## V11–V16. Native applications (D95, D96, proposed)

The applications that both NeoVectra and todhchai planned
(`docs/apps.md`), under one axiom: the web is hypermedia content,
not an application delivery device, so applications are native and
the browser runs nothing it fetches. Each is our own code speaking
existing protocols and formats, as a stated profile within a line
ceiling that the milestone sets as its first step (`vx loc --check`);
every exit below includes its components within their ceilings. A
protocol is a service that keeps standard files in Taisce, and an
application is a live query plus that service's node. Each
milestone adds the kits its applications need, grown from those
applications (principle 22). Studio may move up to follow V14
directly; that is the owner's call (`docs/apps.md` §9).

### V11. Reading and writing

- **The browser:** its own engine, from the WHATWG specifications,
  with a stated CSS profile and no JavaScript: links and forms are its
  only interactivity. It also reads Gemini, Gopher and CommonMark.
  `webfs` serves HTTP/1.1 over V10's TLS 1.3.
- **The editor:** Acme's architecture, sam's structural regular
  expressions, LSP to language servers on the developer's host over
  cpu (none on the device, D4), and Git written first-party.
- **The debugger and trace viewer:** DWARF 5, through `/proc`.
  Design to write when V11 starts (placeholder): crash records, from
  todhchai M7's debugd (post-mortem attach to a held crashed process)
  and NeoVectra's `/tmp/crash/N`, and a kernel panic record that
  survives a reboot.
- **Translators** for images, fuzzed and checked against host oracles
  (D89's pattern).

**Exit:** the browser renders the manual and a reference set of
documents within its page budget, and the editor edits, builds and
debugs a VectraOS program over cpu.

### V12. Communications

In this order: feeds (Atom, RSS), mail (IMAP4rev2, SMTP, MIME), contacts
and calendar (CardDAV, CalDAV), chat (IRCv3, then XMPP with OMEMO), and
social (ActivityPub, then AT Protocol and Nostr). Each protocol is one
service per account, with its keys held by factotum. ActivityPub's
profile includes PeerTube's videos and channels, VectraOS's answer to
video sites (`docs/apps.md` §7): a followed channel is a live query,
and a video plumbs to V14's player.

**Exit:**
- Each service interoperates with a reference server run on the host.
- An idle inbox costs no wakeups.
- No application process holds a socket or a key.

### V13. Documents

Write, Sheet and Show save ODF as their own format, with OpenFormula
for formulas. OOXML, CSV, Markdown and EPUB come in through
translators, and output is tagged PDF. One typesetter, one formula
engine and one PDF writer serve all three, and the browser's printing
too. There are no macros.

**Exit:** each application round-trips the ODF conformance documents
it claims, and opens a reference set of OOXML files.

### V14. Media

- **The media pipeline** is processes on rings, shown in the patch bay.
- **Decoders:**
  - images: PNG, JPEG, GIF, WebP, AVIF;
  - audio: FLAC, Opus, Vorbis, MP3, AAC-LC;
  - video: AV1 and VP9 in software, then H.264 and HEVC on each
    board's video unit (the Sky1's Mali-V), and H.264 in software
    where there is none (`docs/apps.md` §11, question 5).
- **Containers:** Matroska and WebM, MP4, Ogg.
- **Streaming:** progressive HTTP and an HLS client (RFC 8216), for
  video on demand and live; no DASH.
- **Applications:** the player, music and photos.

**Exit:**
- 1080p60 AV1 plays on the Orange Pi 6 Plus with no CPU pixel copy and
  no dropped frame.
- Every decoder matches its oracle.
- A video from a PeerTube instance run on the host plays over HLS,
  H.264 with AAC, from a channel followed in V12's social service.

### V15. Studio (D96)

Streaming and recording for creators (`docs/studio.md`):

- capture, game, camera (UVC), audio and remote sources;
- scenes in Taisce;
- a realtime mixer;
- hardware encoders first, with Opus and AV1 in software;
- outputs to RTMP(S) and Enhanced RTMP, SRT, WHIP and HLS;
- recordings and a replay buffer.

The Recorder is Studio with a file as its only output.

**Exit:**
- An hour's 1080p60 stream from the Orange Pi 6 Plus to an RTMP server
  and to its own HLS origin at once drops no frame and makes no CPU
  pixel copy.
- The reference game holds its frame budget while being streamed.
- Studio's budgets are green.

### V16. Calls and remote windows

- Voice and video calls on WebRTC's media path only (ICE, DTLS-SRTP,
  RTP; no data channels or SCTP)
  and Opus, reusing V15's encoders and WHIP's stack. Signalling is
  XMPP's Jingle, through V12's service.
- Remote windows across the swarm as encoded surface streams, which
  also show a web application running on another machine (D95), with the
  latency target an open question (NeoVectra 02 §9).

**Exit:** a call between two VectraOS nodes, and one with a standard
WebRTC peer, within the latency budget; a remote window on the LAN
under its frame budget.

## Backlog: from the Rust reenvisioning (proposed, 2026-11-20)

A review of `../Vectra-OS` (its `docs/kernel/01` to `13` and
`docs/HANDOFF.md`) against croi and the drivers. Its kernel is younger
and narrower (arm64, one CPU, one lock), so none of its structure is
taken: not its twelve objects, its single lock, its static manifest or
its WaitSet. What is taken is how it models a SoC and how it shows a
check can fail. Each item is proposed until the owner schedules it; an
item that changes a mechanism gets its decision when it starts. In the
order they'd be done:

| | Item | Size | Fits with |
|---|---|---|---|
| B1 | Every check shown able to fail | done (2026-11-20), stopped at the tool | — |
| B2 | Supply leases: a register window that depends on its power | done (2026-11-20, D169, D170): the G720 off and on under a running desktop | — |
| B3 | Confinement and coherence as observed | done (2026-11-20, D168) | — |
| B4 | Checks over a whole machine's description | medium | V6f; V6d and V6e's trees |
| B5 | One owner a register page | done (2026-11-20, D167) | — |
| B6 | Model checks beyond the ring | done (2026-11-20): the PMT and BTI lifetimes | — |
| B7 | A board run that ends itself | kernel half done (croi.watchdog_limit); the stuck report open | V6f |
| B8 | A count of `unsafe` in drivers | small | any milestone |

### B1. Every check shown able to fail — done 2026-11-20, stopped (the owner)

`vx mutate` (D165) is in place with its five-minute limit, and
RX8900Tests' mutants are all caught; no further suite gets mutants (the
owner, 2026-11-20: not worth their run times). The plan as written
follows, for the record.

A clean result is suspect until each safeguard it rests on is removed
and the check catches the removal. There, this found properties that
held of nothing, a safeguard that did nothing (the state count the same
without it) and a checker that asked the kernel for the answer under
test.

- **Design impact.** `vx` gains a step (`vx mutate SUITE`) that builds
  copies of the tree, each with one named edit, and runs the suite that
  should catch it; an edit must apply exactly once, a survivor is said
  with why it survives, and unbroken controls run among them, so a busy
  machine's failure isn't taken for a catch. The edits are a file beside
  each suite. In Swift (D14), run on copies, never in place. Not in
  `vx ci`: a milestone's exit, or by name while working (D88; rows in
  `docs/risk.tsv`).
- **Limit:** a run takes at most five minutes (D165), so a suite is
  mutated only if its mutants fit. RingCheck doesn't: one run takes 92 s
  (2026-11-20), and its safeguards stay shown by the checker's own broken
  variants. The QEMU suites (`dma`, drivers, interrupts, the IOMMUs')
  take a boot each, so they qualify only with a short list.
- **Exit:** `vx mutate` in place with its limit, and each suite that fits
  it has a mutants file whose mutants are all caught or explained.

### B2. Supply leases — done 2026-11-20

D169 (the kernel's supply object and its three calls) and D170 (devmgr
holding them in its graph's order). On the Orange Pi 6 Plus the G720
 was powered off and on under a running desktop, mali's power-up has no
 order of its own, and no SError came of it. The plan as written follows.

**Kernel half done (D169):** `supply_create`, `supply_bind` and
`supply_end` (246-248), the state machine checked as SupplyCheckTests,
the boot self-test and the budget `supply.end_to_clear` (limit to be set
from hardware). devmgr, scmi and the reset controller, and mali(3)'s
power-up, are the other halves.

Today a device's power-up order is each driver's convention through
devmgr's links (D154's item 4 orders binding, not removal), a touch of
an unpowered block is an SError, and croi panics on any SError. There,
a window is derived from a lease on what powers it: to end one the
kernel asks the holder, and at a deadline unmaps the window, masks its
interrupt and aborts its stream, and only then tells the provider it
may cut. The stray access becomes a page fault in one driver host. It
runs on their Sky1 for DPU4 and the G720.

- **Replaces** (principle 1): the order kept in each driver, and most of
  the open "SError delivered to the faulting process".
- **Kernel.** Kept on Zircon's objects: a physical VMO made from an MMIO
  resource can be given a *supply*, an object its provider holds.
  Ending it runs, in order: a signal to each holder's port; at the
  holder's release or the deadline, every mapping of the VMO unmapped
  and shot down (interrupts on, never under the scheduler lock), the
  interrupt objects bound with it masked, the BTI's domain set to
  abort and waited out; then the provider's signal. A provider has a
  deadline too. New calls (the audit's count rises from 91), a new
  entry in the lock orders (supply -> aspace -> vmo; supply -> IRQ
  table; supply -> IOMMU unit), a section in `drivers.md` and an entry
  in `zircon-divergences.md`.
- **What a deadline can't do.** A master the kernel doesn't translate
  (B3) can't be aborted: its pins stay quarantined until its provider
  reports a reset. A foreign processor (the PM core, a DSP) can't be
  forced: the supply ends *pinned*, and the provider leaves it on.
- **devmgr.** The provider graph gains its other direction: a provider's
  driver holds the supplies of what it feeds, joined where a device
  needs several (the Sky1's largest has 5), and devmgr refuses a graph
  with a cycle or a supply with no root (B4). scmi(3), devmgr's `_ON`
  and the reset controller become providers of supplies rather than
  steps a driver calls.
- **Drivers.** DriverHost's `Registers` becomes a borrow of the grant
  (`~Escapable`, the Lifetimes feature), so a view can't be kept past a
  release; a quiesce is a packet on the host's one port, at a point the
  driver chose; firmware's state is looked at first (a device may be
  inherited running).
- **Not covered:** core idle and hardware clock gating (too fast for a
  lease: a table of which idle states each timer allows), and a cut
  firmware makes by itself (a thermal trip), which stays an SError.
- **Budget and check:** the time from an end to clear, with its limit
  (performance.md); the supply's state machine under B6's checker with
  B1's flaws; on the board, a driver that reads on after its supply is
  cut faults and the board runs on.
- **Exit:** mali(3)'s power-up has no order of its own, and the G720
  powered off and on under a running desktop without a power cycle.

### B3. Confinement and coherence as observed

- **Coherence has a source.** devmgr takes a device's coherence from
  `_CCA`, coherent when there's none (`Devices.swift`); the Sky1's GPU
  says 1 and isn't, and its NPU ran ten times slower on the wrong
  memory type. A manifest (or a board rule, D126) states the observed
  value with where it was seen, and it wins over firmware's; a
  DMA-capable device bound on firmware's word alone says so in devmgr's
  `status`.
- **Own-MMU masters are unconfined.** The G720 and the Mali-V translate
  through tables their driver writes, so no SMMU confines them and the
  driver is trusted with all of memory. Their BTIs are the passthrough
  kind with its WARNING, whatever the IORT says, and `vx hardware`
  prints each board's trusted base: every driver whose master the
  kernel doesn't translate, and every SMC range whose calls take
  addresses.
- **Quarantine has a rule.** Nothing in drivers or services calls
  `bti_release_quarantine` today. A translated device's quarantined
  pins are released once its domain is detached; an untranslated one's
  only after its provider reports the device reset (B2), and are
  charged to devmgr's account meanwhile.
- **Design impact:** devmgr's device record and manifest grammar,
  `support.tsv`'s columns, dma(2)'s and devmgr(8)'s pages. No kernel
  mechanism.
- **Exit:** every DMA-capable device on the Sky1 has a stated source for
  its coherence, and `vx hardware` lists its trusted base.

### B4. Checks over a whole machine's description

Their generator refuses a chip that doesn't check out, and over their
own hand-written tables it found a video codec granted to the console.
A second description format would break principle 1, so the checks run
on what we have: our trees (D154, `vx dtc`) and devmgr's provider
record built from a board's captured ACPI tables.

- **Checks:** register ranges that overlap unless one nests the other;
  an enabled device no manifest matches and nothing marks as left
  alone; a supply graph with a cycle, or a supply with no root or no
  provider; a master whose IOMMU has no supply of its own (the Sky1's
  display SMMU is in a power domain); an interrupt with two owners; a
  stream id in two devices on one unit; a register page split between
  two hosts (B5); a driver's register offsets against the spec's tables
  where chinese-wall has them.
- **Design impact:** `vx dtc --check` and a host test over each board's
  captured tables (`docs/boards/*/`), in `vx ci`; each check lands with
  a description that must fail it (B1). The device record gains what
  the checks need said: a device left alone on purpose, with its
  reason.
- **Exit:** the Sky1's captured tables and the RV2's tree pass, each
  check with its failing control.

### B5. One owner a register page

An MMIO resource grants every page it touches (Zircon's non-strict
validation), so two hosts whose registers share a page each get all of
it, and the MMU can't keep them apart. On the Sky1 mailbox 6's page
holds SCMI's shared memory and every CPU's CPPC register, which power(8)
maps (D130) beside scmi(3).

- **Design impact:** devmgr grants a page to one host (exclusive
  resources, which it doesn't make today) and refuses a second, or
  names the pair in a manifest as one group in one host; a register
  another host needs is reached through its owner's node. power(8)'s
  CPPC writes are the first case to settle: through scmi(3), or the
  page's owner changed.
- **Exit:** devmgr's `status` shows no page in two hosts on any board,
  and B4's check holds it.

### B6. Model checks beyond the ring — done 2026-11-20 for the PMT and BTI lifetimes

D166: the lifetime logic is `lib/dmalife`, generic over a world the
kernel and a model provide; the shared checker (`lib/check`) explores
one BTI and two PMTs in 14 s on brimstone, its broken variants failing.
It found no bug. Port rings against cancel and close, and B2's supply,
are left for when they are next changed. The plan as written follows.

There the kernel's lease, call and domain logic is plain code behind a
trait for hardware, so the checker explores the code that ships, in
every reachable state of a small machine. croi can't be lifted whole
under one, but RingCheck (D43) already does this for the ring.

- **Candidates,** by the bugs they've had: a PMT's and its BTI's
  lifetimes through unpin, close, quarantine and process death (the
  "holder isn't a CPU" bug); port rings' packets against cancel and
  close; B2's supply, which is written this way from the start.
- **Design impact:** each candidate's state machine moves out of its
  object into a type with no locks or pointers of its own (indices and
  generations), which the kernel calls under the object's lock and a
  host checker drives; a memory budget in the checker that reports
  incomplete, never a kill by the OS; `lib/check`'s Checker made
  the shared one.
- **Exit:** the PMT and BTI lifetimes hold in every state, and each
  check's broken variant (a dropped safeguard in the checker, as
  RingCheck's) fails; each check runs within RingCheck's time or less.

### B7. A board run that ends itself

There a board's test kernel feeds the watchdog for a bounded time only,
ends a run once nothing has been said for 20 s, and, idle late in a
run, says what each process still there waits on. It ended their power
cycles for a wedged run.

- **Design impact:** board-test's image only: the kernel's watchdog
  feed gains a limit taken from the command line, and a stuck report
  (each thread's wait, by process) goes to the debuglog before the
  reset. board-test(8)'s BUGS (the launcher goes on after it ends)
  closes with it.
- **Exit:** a board-test run wedged on purpose resets the Sky1 by
  itself and its log names the waiter.

### B8. A count of `unsafe` in drivers

Their drivers forbid `unsafe` outright, with the raw access kept in one
audited runtime. Ours mark it (`-strict-memory-safety`) but don't bound
it: 84 lines in `drivers/block`, 49 in `drivers/net`.

- **Design impact:** a build check beside `CheckNoArc`: `unsafe`
  outside `drivers/host` is counted per driver against a recorded
  number that only falls (a size budget, `vx loc`), with DriverHost
  growing the safe forms the drivers lack (bounded views of pinned
  memory and of rings a device writes, copied out before they're
  checked).
- **Exit:** the count recorded for each driver, and a new driver starts
  at zero.

## Research tracks (unscheduled)

- CHERI-RISC-V on rv64 (QEMU-CHERI first).
- Halide-style algorithm/schedule split in VXCompute.
- hetIR-style checkpoint and migration of accelerator work across swarm
  nodes.
- The Hailo-8 over M.2, on the Orange Pi 5 Plus (V6d).
- A stretch goal: the Mac mini (M4, base), from Asahi Linux's facts and
  reverse engineering. No UEFI or ACPI, 16 KiB DART pages, and Asahi is
  at early bring-up on the M4 (`docs/boards/macmini-m4/`).

## Designs waiting for a trigger

Placeholders with no milestone yet. Each design is written when its
trigger arrives, not before.

| Design | Trigger | Start from |
|---|---|---|
| System updates and rollback; secure and measured boot | Before others install the system | todhchai M9 (atomic updates on Taisce S2); NeoVectra 06 (ESP slots, trial boot), whose boot chain was Limine |
| USB beyond HID: mass storage, audio, networking; exFAT read | Daily use of the desktop | todhchai's xHCI classes |
| Network management: several interfaces, firewall, VPN, NTP, mDNS/DNS-SD | Daily use of the desktop | NeoVectra's trusted networks |
| Wi-Fi and Bluetooth | A desktop with a radio is a target (the SBCs have none) | Nothing in any donor |
| Battery and laptop power | A developer with a laptop to build and test on | todhchai architecture §8 (profiles) |
| MIPI cameras | VectraOS is a usable desktop; for makers | V15's UVC capture |
| RDP or VNC | Managing mixed fleets | `cpu` and V16's remote windows |
| Printing and scanning | Undecided | NeoVectra's driverless IPP Everywhere and eSCL |

Out of scope: accessibility beyond the High contrast theme (D91),
unless funded with a team; localization beyond English and its close
cousins; touchscreens and pens; HDR and colour calibration. Hosting VMs
is a non-goal: VectraOS boots on hardware.

## Known issues

1. ~~**The rv64 PMU self-test fails intermittently**~~ **Fixed 2026-10-15.**
   The test's definition of idle was wrong; the PMU code was fine. See
   `docs/kernel/design/user.md`, K6e. The original report follows. (Found
   2026-10-15, in V0's first `vx ci`.) `boot-smoke` panicked with `pmu self-test: overflow
   sampling`: overflows 57, samples 55, with frames 55, on idle CPUs 1
   (overflows 1). The next 4 runs passed, so it failed 1 time in about 6
   rv64 boots. `PmuSelfTest` counts any cycle sample on another CPU as
   "on an idle CPU". A background thread (`dlog-dumper`, `reclaim`) that
   runs during the sampling window may be enough to trip it. Not yet
   diagnosed. Fix before V0 exits, either in the kernel or in the test's
   definition of idle, with the reason written in
   `docs/kernel/design/cpu.md`.
2. **Status of todhchai's N1** (2026-10-15). It lives on its unmerged `n1`
   branch:
   - **Done:** crypto, the stack hosted and native, sshd hosted with SFTP,
     the net class, virtio-net.
   - **Left:** push and run (N1e). sshd on croi (d4) and rc on a pty (d5)
     are no longer needed: V3's link is cpu (D77).
   - **Open there:** a decision on where a headless boot's key lives (now
     its Noise IK static key, D77), because the native keyring needs
     Radharc for its prompt. D75 settles
     the prompt (a headless factotum asks no one and makes the key on
     first use); where keys persist across boots waits for V4.

   V3 lifts crypto, the stack, the net class and virtio-net from a pinned
   commit of that branch; IMPORTS.tsv records the commit.
3. **`trace.probe_enabled` rose from 18 to 21 ns under KVM, accepted
   (2026-10-16).** D50 put the trace rings on the one ring, whose
   OVERWRITE protocol costs each record a sequence mark, a release fence
   and the sequence's store besides the record and the cursor. `vx bench
   --compare 801b3f6` measured 21.0 ns against 18.0 ns in every one of 5
   interleaved runs; the limit stays 30 ns, met. A cheaper write (filling
   the slot in place instead of copying a built record, fewer checks of
   the CPU's writer) is worth trying before a probe-heavy budget needs it.

4. ~~**The cpu server stops listening under a burst of calls**~~ **Fixed
   2026-10-17.** Found by `vx remote boot`'s first probing (16 dials at
   once, 5 s each, which QEMU's port forward handed the new boot
   together), then reproduced with 16 bare calls that hang up at once.
   Two bugs, one hiding the other, both silent until the launcher logged
   ends and the kernel logged limit kills:
   - net was killed by the kernel, past its port's 4096 user packets
     (`PORT_TOO_MANY_PACKETS`): NodeTree readies every waiting session of
     each live conversation each time the stack settles, a frame or a
     request, and each `IPCDispatcher.wake` queued a packet. A wake now
     queues one only if none is waiting to be taken. ipc-test wakes a
     server 10,000 times before its dispatcher runs: one wake, where the
     old code was killed.
   - Nothing restarted it: the launcher's bootfs entries borrow bootfs's
     handle, which its `main` closed after its last use (a duplicate), so
     only images with `launcher.until`, which kept it to the end,
     restarted a bootfs program. In a cpu image no service could restart,
     and cpu, whose net was gone, couldn't either. The Launcher now holds
     the image.
   boot-cpu restarts net and sends 32 bare calls, and the cpu server
   answers after each; five bursts of 64 under KVM leave it answering.
   The launcher now logs each end (`exited`, `restarted`, `didn't
   restart:` and why), the kernel each process killed past a limit, and
   dial errors their reason. vx's probing stays at 4 dials at once.

5. **arm64's boot-ipc hung once in a full `vx test` run** (2026-10-18).
   ipc-test started and printed nothing more until the 90 s timeout
   (no check failed: something waited for good). The same run's other
   tests, and the run before it (where QEMU was killed from outside,
   floor-hello and fdio-test with it), passed or failed for other
   reasons; boot-ipc alone passed 25 times since, 12 of them beside an
   amd64 suite, and boot-lean-icount, which missed m2's exit once in
   that run, 3 times. The change under test touched nothing ipc-test
   runs; 422eb5a's coalesced wakes, which its last check exercises, are
   the first suspect if it comes back.

6. ~~**IdleSuite's "and never entered it while bound" failed once**~~
   **Fixed 2026-10-18:** the check counted CPU 0's entries from before
   the profile, when it may rightly enter the deep state: woken in the
   gap, or choosing with the bound it read just before the profile came
   (whose kick then ends that idle at once). It counts from once a
   demotion is seen (docs/kernel/design/cpu.md). The original report:
   (2026-10-18, amd64's boot-intremap-off, TCG, load about 5): CPU 0 was
   seen entering the deep idle state within 50 ms of an interrupt's
   deadline profile bounding it. Four runs after, at load 8.7, passed.
   A timing check that a busy host can break, or a real race between
   the profile's bound and the idle governor's choice: not looked into.
   Again 2026-10-18 (amd64's boot-intremap-off, TCG, in a vx test
   --changed run beside arm64's suite); three runs after passed.

7. **boot-cpu's trace hung once under KVM** (2026-10-18, `vx bench`'s
   second cpu boot, a quiet machine): `trace 2 DIR` printed `trace:
   recording` and its session never ended, while the 60 copies beside
   it all did; nothing on the console. The next 21 boots to the same
   step passed. Where in the script (the sleep, the stop, or the copies
   to /mnt/term through the import's ring) is not known; when it fails,
   boot-cpu now reads `/proc/trace/ctl` in a call of its own (still
   `recording`, `stopped`, or no answer from proc) and lists what
   reached the terminal, for next time.

8. ~~**m2's `ring.kicks` misses its limit**~~ **Decided 2026-10-18.**
   0-8 in most full and lean boots under KVM, against `limit=1` (none),
   the same at 01b3437. Each kick answers a real sleep: m2's throughput
   run logged its kicks' entries, one in four quiet lean boots, mid-run,
   the consumer ringing a producer that had spun its 50 µs on a full
   ring while the consumer was stalled; the round trip, whose sides
   never sleep, rang none. So the count is the host's stalls of a vCPU.
   By the owner's choice the limit holds only off a hypervisor (CPUID's
   hypervisor bit); under KVM `vx bench` judges the count against
   history (+50%, 8 kicks).

9. **`services.rss` at 14.5 MiB under KVM, accepted (2026-10-24).**
   `vx bench --record` at b09c3eb judged it against the median of the
   last five records (11.4 MiB, from runs as low as 3.9 MiB) and refused
   it. The rise predates D128's changes: an interleaved `--compare
   89d8649`, the commit before them, measured 14.3 MiB there and 14.5
   here, and the last record (262c478, 2026-10-19) was 14.4 MiB. The
   owner accepted it as the new baseline; where the services' memory
   went since 11.4 MiB is not yet looked into. The limit stays 31.9 MiB.

10. **Two faults found drafting D131** (2026-10-24, by reading, not run):
    - **A mapped file shows old bytes after a shrink.** `MappedHeader.resize`
      (`services/fs/lib/Mapped.swift`) zeroes only when the file grows,
      and `mappedWrite` (`services/fs/server/MappedFiles.swift`) zeroes no
      gap. A file shrunk, then written past its new end but within the
      VMO's capacity, shows the old bytes in the gap through its mapping,
      where Taisce reads zeros. Fix: zero from the new size to the old on
      a shrink. FsTests' `mappedFilesStayCurrent` gets the check. D131
      would remove the cause (shrinking a pager VMO drops its pages), but
      the fix shouldn't wait for it.
    - **memory.md says pager VMOs can't be resizable.** Its K13d note
      ("RESIZABLE / UNBOUNDED NOT_SUPPORTED (no resizable VMOs)") is out
      of date: `pager_create_vmo` takes RESIZABLE since K13h (that
      section says so) and UNBOUNDED since K14i (`PagerSyscalls.swift`);
      DISCARDABLE is the option it refuses.

## Open questions

1. Host tests: SwiftPM plus CTest, as todhchai does, or CTest only (D11).
   Decided in V0.
2. ~~The shell~~: todhchai's rc, because V3's cpu sessions run it (D15, D77).
3. A dedicated transport for remote ring bridging, versus 9P reads and
   writes (V7).
4. Whether the CDSP accepts unsigned first-party Hexagon code on the Q8B's
   firmware. Check AbyssBSD's `npu/` notes before V8.
5. ~~`space` mode~~: plain free placement with spatial memory, not a
   canvas larger than the screen (D116, decided 2026-10-22 against a
   bring-up reference workflow).
6. A hardware watchdog on V6's board, so that a hang becomes a reboot
   into the stick's known-good kernel instead of a walk. The Orange Pi 6
   Plus has an SBSA watchdog in its GTDT that refreshes only through
   `WOR` (D69): a board rule selects it. Whether the Q8B's firmware
   exposes WDAT or an SBSA watchdog is checked in V8.
7. UEFI network boot (todhchai N1f), for recovering from a kernel that
   won't come up at all. Not chosen for V3 (D15); revisit if V6's hangs
   are frequent.
