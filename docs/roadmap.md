# Roadmap

Each milestone has exit criteria. A milestone is done when its criteria pass
under `vx ci` and every budget it introduces has a running check
(principle 13). This file looks ahead: a finished milestone keeps a brief
here, and its history, step by step, is in git and `docs/decisions/`.

## Where things stand (2026-10-30)

- **V0 to V7 are done**: the kernel, the userland, the bring-up link,
  Taisce, the desktop, the Orange Pi 6 Plus and the swarm. amd64 and arm64
  run everything; rv64 runs its whole QEMU suite, tier 1 included, and
  waits for its board (V6b).
- **The board** runs VectraOS beside its FreeBSD, its `/data` an encrypted
  volume unlocked at boot by a swarm member.
- **Next:** the boards for rv64 and amd64 (V6b, V6c) wait (the owner);
  then compute (V8). Below, after the briefs: what the finished
  milestones left open, then the milestones ahead.
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
- A wake costs ~1.7 µs a hop, 0.75 of it the IPI to an idle CPU; idle
  CPUs keep sleeping in WFI (the owner), so cuts are software only.
- A fresh-page fault spends 0.27 of its 0.93 µs scanning fs's mappings
  linearly (`handleFault`, `mapPresent`).
- The floor's stdout mixes the lines of a process's threads printing at
  once (one line buffer, locked a character at a time).
- `port.wake_p99` (V2's exit, 14.7 µs against 9.1), to compare
  interleaved; arm64's and rv64's RTCs; the warm boot's return in two
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
