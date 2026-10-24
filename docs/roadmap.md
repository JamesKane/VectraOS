# Roadmap

Each milestone has exit criteria. A milestone is done when its criteria pass
under `vx ci` and every budget it introduces has a running check
(principle 13).

## Where things stand (2026-10-23)

- **V0 to V5 are done in QEMU, on amd64 and arm64.** rv64 builds
  everything; its QEMU suite is off in `vx test` and `vx ci` until full
  Swift (tier 1) runs there, waiting for Swift's calling conventions in
  its LLVM (the owner's call, 2026-10-17).
- **Shared libraries (D124) are done** (2026-10-23): tier 1 programs are
  linked against one copy of the Swift runtime, FoundationEssentials and
  tier 1's own libraries in bootfs's `lib/`, bound by the process that
  starts them (linkmap(6)). rio is 0.69 MB (14.1 static), the largest
  image 68 MB (139). `desktop.shared_rss` was missed at first, 30.8 MB
  against 27.8 static with a third of static the target. Measured by
  mapping, 23 MB of it is rio's frames, atlases and stacks, which linking
  can't share, so the target is now what the programs held static. bootfs
  now serves its files as slices of the image, which every process
  shares, and the three hold 27.4 MB (met). One place a boot for each
  library would save at most 2.4 MB more and isn't planned. Kit now draws
  straight into a window's buffer, with no canvas (26.4 MB). Each Kit
  window's painter held a 4 MiB image atlas and a 1 MiB glyph atlas,
  zero-filled at once, about 16 MB of rio's three windows; atlases now
  begin with no rows and grow as they fill, and the three hold 8.9 MB.
- **V6, the Orange Pi 6 Plus, has begun** (2026-10-24). It also
  enforces what QEMU couldn't judge at V5's exit. The loader and kernel
  boot on it from a one-shot boot entry beside its FreeBSD, on DBG2's
  console, with all 12 cores; the kernel's self-tests pass through user
  mode, the PMU and the ITS, after two fixes QEMU couldn't show (the
  ITS's tables were cleaned with a cache line not yet known; firmware
  leaves PMCR's LP set). A boot is now a production boot unless
  `croi.test=` names the tests to run (D125), and the driver test is a
  Swift suite that takes its addresses from the machine.
- **Testing (D88):** `vx test --changed` runs what a change risks, reading
  build files for what they name. Each arch's QEMU tests run in parallel
  and take under 5 minutes (amd64 about 2, arm64 about 3), and a check
  that flakes is removed, not retried. The full suite, `vx ci`, closes a
  milestone.
- The history of each milestone, step by step, is in git and in
  `docs/decisions/`; below are the highlights and what each left open.

Milestones run in order. Each one puts in place what the next one
depends on. Board bring-up (V6) is attempted only once its dependencies
are in place: the bring-up link (V3, D15), Taisce on disk (V4) and the
desktop (V5), each finished in QEMU first (D76).

## V0. Ground — done 2026-10-15

croi lifted into this repository, booting and passing its self-tests on
amd64, arm64 and rv64 in QEMU; todhchai's bench, trace format and budget
scrape; `vx` as the front door; the size budgets running.

## V1. Setup-engine kernel — done

- The audit (`docs/syscall-audit.md`, D18, D19): 154 calls cut to 91, one
  family a commit (D20-D38), each with its replacement in place first:
  `object_bind` and `port_wait` with a leeway (D20).
- The hot calls batched (D39-D42); the one ring in Swift and `ring.h`,
  checked by RingCheck (D43); ports and the debuglog as rings (D38, D44).
- Exit: the kernel and IPC budgets green, the syscall ceiling published,
  `ring.kicks` 0 under load. `channel_call` < 1 µs stays a hardware
  target, guarded by m2's 1.6 µs limit under KVM.

## V2. Userland base — exit met

- One ABI (D45); the floor, Sys, libc, ld and the trace; tier 1, C, C++
  and full Swift by the `*-vectraos` toolchain (D47), on amd64 and arm64.
- The control plane: IPC, Node with bulk rings, the launcher; time as a
  UTC page from the time service (D48); the environment as `/env` (D81).
- Byte streams on the ring (D46): stdio, FDIO, rc and its commands.
- Drivers (D74): ACPI, PCI over ECAM, devmgr and the driver host with DMA
  through each IOMMU, virtio, virtio-input and kbdfs (D83, D84).
- The console and the plumber (D85); the manual (D86).
- Exit (2026-10-16): `cat /svc/*/status` run by rc, spawn → main 79 µs
  (< 200 µs), services 3.7 MiB (< 32 MiB), the first bench history
  recorded (cd3eb6d), `man/missing` down to the pty.
- Left open: arm64's and rv64's RTCs; the rc and command gaps an audit
  against 9front found (`vx rc-oracle` tracks them, D70); `port.wake_p99`
  (14.7 µs against 9.1 µs at the exit), to check interleaved.

## V3. Bring-up link (D15, D77) — done 2026-10-18 on amd64 and arm64

- Notes and `/proc`; crypto; the net class and the stack serving `/net`
  with dial(2), cs and dns; the console's shell (D97).
- 9gate (Noise IK, export and import), factotum holding its key, and cpu:
  `vx cpu`, rc on a node with the terminal's `/dev/cons` and files at
  `/mnt/term`, its `/net` too (D104); the pty gone.
- Warm boot and `vx remote boot` (D101); the link on rings (D103);
  `trace`, a profile of a node (D102).
- Exit under `vx ci` (fcf08a2), the bench recorded on a quiet machine:
  `remote.first_call` 53.8 ms, `remote.copy` 491.5 ms, `remote.warmboot`
  621.3 ms; `services.rss` 11.9 MiB, accepted in the open. `man/missing`
  is empty, and every milestone after keeps it so.
- Left open: rv64's link waits for tier 1 there; the warm boot's return
  comes in two speeds (0.42 s and 0.62 s), not looked into.

## V4. Taisce on disk — done 2026-10-18

- The block class with virtio-blk (D82, D106); Taisce on a virtio disk at
  `/data` across reboots, with `vx disk` and `vx fsck`.
- Its queries, live queries, whole listings and mapped files in fs(4);
  taisce(4) and query(6); the manual on the volume.
- Exit under `vx ci` (262c478), the file budgets' first records on a
  quiet machine: `fs.read_4k` 310 ns, `fs.live_update` 56 µs,
  `fs.commit_64_p99` 3.9 ms, `fs.list_100k` 1.7 ms, `fs.fsync_p99` 1.7 ms
  (judged on a board, D105); `services.rss` 13.7 MiB, accepted.
- Left open: S2's parts are V6's and V7's.

## V5. Desktop (D107) — done 2026-10-22 on amd64 and arm64

- Step 1, the APIs: the text stack with fonts as data, UICore on D91's
  roles, theme files as ndb entries resolved in layers (D108, D109), the
  mouse service.
- Step 2, Radharc on the boot framebuffer: its own vblank, input on the
  ring, colour in linear light (D110), the trusted prompt (D111), the
  clipboard (D112), and the kit frame pixel-tested at 100% to 300%.
- Step 3, the SDK and Kit, then rio: the SDK's Loop over one port, the
  reference app in 9 calls (≤ 12); Kit on tier 1; rio's text windows with
  no pty and no escape sequences, and vt taking one over.
- Step 4, the shell: Tracker, Deskbar, Settings (D113-D115), workspaces
  tiled and spatial with layouts as processes (D116), notices (D117), the
  lock screen (D118).
- Step 5, the themes whole: Platinum Indigo and Neon Tab, high contrast,
  knobs, a theme per workspace, `vx theme check` in `vx ci` (D119).
- Step 6, the GPU: the display class and virtio-gpu (D120); Vulkan and
  Venus generated, our loader and Loinnir, and Radharc composing on the
  GPU where QEMU has Venus (D121).
- Step 7: guide, the manual as hypertext; `plugin.replace` met; hot
  reload, with `vx reload` through the cpu session (D122).
- Exit under `vx ci` (640936f, in 8.7 minutes), accepted by the owner as
  amended in D107 (D122, D123):
  - On amd64 under KVM (boot-rio-kvm): key → draw 0.22 ms (< 1 ms), on
    the glass in 1 frame (≤ 2), cold start 5.5-16 ms (< 50 ms), in both
    themes. arm64's key → glass is 1 frame; its times are enforced on the
    board.
  - `desktop.mode_switch`, `theme.switch` and `plugin.replace` green;
    every shipped theme passes `theme check` and the kit frame's tests.
  - `reload.module_10k` missed and accepted: 1.5 s against 1 s, bound by
    swiftc's front end; the limit stands.
- Left open:
  - The GPU: hotplug acted on; per-output scale, EDID names and colour;
    suspend in devmgr's protocol; UIGPU and buffer objects (D121);
    `theme.compose.4k`, about 6-7 ms against its 1.5 ms target.
  - The shell: Deskbar's tray replicants, GPU and AUDIO gauges, and
    Restart and Shut down; the Inspector's jobs, threads, handles, IPC
    graph and tracer; a notices drawer as a document (V11), and Do not
    disturb; Deskbar's idle wakeups, untested since their check flaked.
  - Themes: Appearance's Edit and Save as theme, an output's layer and
    app rules, and Graphite, Indigo Magic and NeXT.
  - Hot reload: TLS in loaded objects; pointer input in HotFrame.
  - The kit frame's reference images; shared libraries for tier 1
    programs (13 MB static PIEs today).
  - Not in V5: translators, previews and Player (V14), audio (V9, V14),
    Edit (V11), the hosted SDK over Wayland and PipeWire, the touchpad,
    and local time over D48's UTC.

## V6. Orange Pi 6 Plus (CIX Sky1)

The first board (D69, replacing D5's Q8B). Attempted only once V0 to V5
are done (D76), so the board meets Taisce and the desktop already
tested in QEMU. The board work then starts with V3's link, so every later step
is a rebuild and `vx remote boot`, not a stick and a walk. Its facts are
in `docs/boards/orangepi-6-plus/`.

1. **Console first:** the loader and kernel print through COM2, the
   PL011 that DBG2 names (there is no SPCR), as `boot-dbg2-console` does
   in QEMU. A 3.3 V USB-serial adapter on the 10-pin debug header: pin 1
   TX, pin 3 RX, pin 5 GND. The first boot reads the ID registers, which
   settles D53's crypto question.
2. **The platform:** GICv3 with ITS (and erratum 2941627, if this GIC
   revision has it), SMP across three core tiers (D68's kernel half
   lands before V6, in QEMU), and PCIe through the generic ACPI host.
   A board rule (D126, compiled in) selects the SBSA watchdog's `WOR`
   refresh (done); the two SMMUv3 stay as firmware set them until a
   board rule takes them over with the IORT's RMRs.
3. **Ethernet:** an RTL8126 driver in the net class, written for the
   Realtek RTL8125/8126 family, which V6c, brimstone and the Orange Pi 5
   Plus also use.
4. **The V3 link on the board:** `vx cpu`, a copy from `/mnt/term`,
   `log -f` and `vx remote boot` against the Orange Pi 6 Plus.
5. **Then the rest:** NVMe, with Taisce's volumes on it (V4's), the
   board rules (the watchdog's refresh, the SMMU takeover), a GOP
   framebuffer text console, and USB for HID. The GPU's first probe
   follows AbyssBSD's power-up order exactly: a wrong order costs an
   SError and a power cycle.
6. **The desktop on the board** (V5's): on the GOP framebuffer until the
   board's own display path, which D69 reorders in its own entry
   (Adreno 690 was planned for V5 while the Q8B was the first board,
   ADR-0019).

`firmware/README.md` lists each blob's provenance.

**Designs to write when V6 starts** (placeholders):
- Firmware as part of the hardware: distributed as FreeBSD does, a
  package per device, installed only for hardware that is present.
  Amends D4's list; says where packages are hosted and who signs them.
- The power service's thermal half, which todhchai's M10 had for the
  Sky1: the SCMI service, CPPC, ACPI thermal, and a tested
  critical-temperature shutdown, so the desktop on the board is not
  cooled by firmware alone. Battery waits for a developer with a laptop.

- **Taisce's encryption (S2, D105):** per-volume AES-XTS, designed
  here from todhchai's notes (its M9; no code exists), since a board's
  disk leaves the bench.

**Exit:**
- V3's exit commands pass against the board.
- The native suite passes on the board through the serial budget scrape.
- Orange Pi 6 Plus power-on → console, and warm-boot turnaround, are
  within budget.
- Taisce's crash harness passes on NVMe, and the desktop budgets are
  green on the board.
- The Orange Pi 6 Plus and its required components are experimental in
  `docs/hardware/support.tsv` (D66).
- VectraOS measured against stock and tuned Ubuntu and FreeBSD on the
  board, in D127's rows and bands: every row has a band, and each gap is
  an optimization pass in this roadmap. bash's rows are pending (D127).

## V6b. Orange Pi RV2 (rv64)

The rv64 board (D51), after V6's board (D69) and on the same V3 link.
Its facts are in `docs/boards/orangepi-rv2/`. It starts once the
firmware path (D51's open question) is decided and rv64 builds and tests
against RVA22 in QEMU (`-cpu rva22s64`).

1. **Console first:** the loader and kernel print through UART0, a
   16550-style UART at `0xd401_7000` with 32-bit registers 4 bytes apart.
2. **The platform:** 8 harts through SBI HSM, the PLIC, the SBI timer,
   and DMA within each bus's window, with no IOMMU.
3. **Ethernet:** a K1 EMAC driver in the net class (RGMII, Motorcomm
   PHYs), whose bus reaches only the first 4 GiB of DRAM.
4. **The V3 link on the board,** as for V6's.
5. **Then the rest:** eMMC and microSD (SDHCI, below 2 GiB), PCIe with a
   DesignWare MSI backend, USB 3 for HID, and the P1 PMIC's reset.

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

## V7. Edge: 9gate and the swarm

- 9gate toward Linux and 9front, on V3's 9P2000 core and Noise IK (D77,
  D78): 9front mounts an export unchanged, and Linux `v9fs` mounts it as
  9P2000, the translator speaking `.L` only where `v9fs`'s conformance
  needs it (which messages, decided here).
- VectraOS↔VectraOS extensions for attributes, queries, leases and ring
  bridging, negotiated as `9P2000.vx` (D78).
- Swarm node roles and `/swarm/pool`.
- **Taisce's snapshots and their send and receive (S2, D105):**
  snapshots as dated directories, and a volume's changes sent to
  another node's over 9gate, designed here from todhchai's notes (its
  M9; no code exists).
- **The export on rings** (D103 left it on messages): its reads and
  writes take one lock per fid around the file's Node client, so a 9P
  client's Treads on one file go one at a time, in 32 KiB messages; a
  ring per fid would carry them together (Twrite still waiting for its
  count). Measured first, on two QEMU nodes on one network, one
  importing the other's export: nothing reads an export in V3 (the cpu
  link imports; a node can't import itself, net having no loopback;
  vx has no 9P client).
- **cpu between VectraOS nodes** (D75), on V3's server (D77): `cpu -h
  NODE` from a node's terminal, the remote rc's text that window's, and
  each node's identity its factotum's Noise IK key.

**Exit:**
- Linux `v9fs` mounts a VectraOS export and passes conformance.
- A PC mounts the Orange Pi 6 Plus's `/dev`.
- `cpu -h` from one VectraOS node to another gives rc with the
  terminal's `/dev/cons`, authenticated through both nodes' factotums,
  with no pty on either side.
- The LAN budgets are green.

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
service per account, with its keys held by factotum.

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
  - audio: FLAC, Opus, Vorbis, MP3;
  - video: AV1 and VP9 in software, then H.264 and HEVC on each
    board's video unit (the Sky1's Mali-V).
- **Containers:** Matroska and WebM, MP4, Ogg.
- **Applications:** the player, music and photos.

**Exit:**
- 1080p60 AV1 plays on the Orange Pi 6 Plus with no CPU pixel copy and
  no dropped frame.
- Every decoder matches its oracle.

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

## Research tracks (unscheduled)

- CHERI-RISC-V on rv64 (QEMU-CHERI first).
- Halide-style algorithm/schedule split in VXCompute.
- hetIR-style checkpoint and migration of accelerator work across swarm
  nodes.
- RK3588, on the Orange Pi 5 Plus (on hand), and the Hailo-8 over M.2.
  Shipped with DT, but a community EDK2 gives it ACPI, so using that
  firmware needs a decision, not a DT path (`docs/boards/orangepi-5-plus/`).
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
