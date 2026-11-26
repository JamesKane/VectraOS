# Audio: one graph for players, gamers and the home studio

A high-level design (2026-11-21, draft). It surveys how other systems
do audio and asks what semi-professional musicians and gamers need from
each. It then proposes one audio subsystem for VectraOS that serves
both groups with the same mechanism.

Nothing here is decided. §11 lists the decisions it needs, and §12 the
open questions. It fills in what the roadmap already commits: V6f item
3 (an audio class fed by a ring, HDA with the ALC269, DisplayPort
audio), V9 (audio output for the reference game, virtio-snd, HDA on
amd64), V14's player and V15's mixer and per-application taps
(`docs/studio.md` §4, §10).

## 1. Goal and scope

**Goal:** one audio path that a home studio trusts at 64 frames and a
gamer never has to configure. The same path plays a song, carries a
voice chat, renders a game's 3D sound and records a guitar, and it never
makes the user choose between "shared" and "exclusive".

- **The two groups:**
  - **Semi-professional:** home studios, streamers who also make music,
    podcasters. They own a class-compliant USB interface (two to
    eighteen channels), maybe MIDI controllers, and run a DAW with
    plug-ins. They need low and steady latency, no dropouts under load,
    routing between programs, sample-accurate timing and MIDI.
  - **Gamers:** a USB or analogue headset, maybe HDMI or DisplayPort to
    a TV or AV receiver, a voice chat beside the game. They need
    positional sound on headphones, the game and the chat apart (two
    volumes, two destinations, one stream without the other), a clean
    microphone, and devices that just work when plugged in.
- **In scope:** the device classes and drivers, the system's audio
  service and its graph, the client API, realtime scheduling for audio,
  routing and capture, MIDI, spatial rendering, voice processing, the
  budgets and the diagnostics.
- **Later:** network audio between machines (AES67 over the swarm,
  §8.4), the Sky1's HiFi5 DSP (§8.3), Bluetooth (no board has a radio;
  roadmap, "Wi-Fi and Bluetooth").
- **Out of scope:** Thunderbolt and PCIe interfaces with vendor-only
  register sets (RME, UAD, Avid): there is no public spec to write
  their drivers from. FireWire. Surround *encoding* for receivers
  (Dolby Digital Live, DTS Connect) is licensed; passthrough of an
  already encoded stream is in (§7.4).

## 2. The field

Each system below is assessed on what the two groups get from it, what
it costs them, and what VectraOS should take or leave.

### 2.1 Windows

Windows has the largest audience in both groups, and the most layers.

| Layer | What it does | Strength | Weakness |
|---|---|---|---|
| **WASAPI shared mode** through the audio engine (`audiodg.exe`) | Mixes every application, runs OEM effects (APOs), resamples to one device format | Per-application volume (Vista), per-application output device (Windows 10 1803), process loopback capture (Windows 11) | A default period of 10 ms. `IAudioClient3` allows smaller shared periods only when the driver supports them. OEM APOs ("audio enhancements") add latency and bugs the user can't see |
| **WASAPI exclusive mode** | One application owns the device; no mixer | Low latency and bit-perfect output | Every other program goes silent: the chat, the system sounds, the browser |
| **ASIO** (Steinberg), the musician's de facto standard | A per-vendor driver that hands one application the device's buffers | Low, steady latency with a good vendor driver | Third-party, per device, usually single-client. The in-box USB Audio Class 2 driver (`usbaudio2.sys`) has none. Microsoft has announced an in-box ASIO and low-latency UAC2 driver with Qualcomm and Yamaha, aimed at Windows on Arm, in preview in 2026 |
| **MMCSS** | Raises a registered thread's priority ("Pro Audio", "Games") | Simple to use | Priority, not a deadline. A badly behaved driver's DPCs still cause dropouts. Users debug them with LatencyMon, by guessing |
| **Spatial sound** (`ISpatialAudioClient`: Windows Sonic, Dolby Atmos for Headphones, DTS Headphone:X) | Object-based rendering for games | Games send objects; the system renders them for headphones or speakers | The good renderers are paid add-ons, and few games use the object API |
| **Communications ducking** | Lowers other sounds by 80% when a "communications" stream opens | — | On by default, and surprises gamers mid-match |
| **Windows MIDI Services** | MIDI 1.0 and 2.0, multi-client, loopback endpoints | Generally available since February 2026, after years with single-client WinMM | New; device support is still arriving |

**What gamers do about it:** they install third-party routers (Voicemeeter,
SteelSeries Sonar, Elgato Wave Link) to get a game mix and a chat mix,
a stream mix without the chat, and an equaliser. A whole product
category exists because the system mixer has no routing.

**Lesson:** Windows splits one job, playing sound, across three
mechanisms (shared, exclusive, ASIO) and makes the user pick, with
latency on one side and sharing on the other. Its priority-based
realtime has no admission and no attribution, so a dropout has no
culprit. Its gamers buy back the routing the system left out.

### 2.2 macOS and iOS

| Pattern | Strength | Weakness |
|---|---|---|
| **One HAL path** for every application. Each client's IO proc runs in its own process, on a time-constraint thread, woken from the device's clock | Low latency (32 to 64 frames) is the normal path, shared by every program. Class-compliant USB interfaces work with no vendor driver: this is why home studios buy Macs | — |
| **The device's clock as timestamps:** the driver publishes "zero time stamps" (a sample position and the host time it happened) and the HAL extrapolates; it doesn't need an interrupt per period | Few interrupts; clients schedule against a predicted position | Drivers whose timestamps jitter cause glitches |
| **Aggregate devices** with drift correction | Two interfaces, or an interface and a headset, used as one device | Set up by hand in Audio MIDI Setup |
| **Audio Workgroups** (macOS 11) | A DAW's worker threads join the device's realtime deadline, so the scheduler knows the whole render is one job | Only for programs that adopt it |
| **AudioServerPlugIn** (user-space drivers) and Audio Units v3 (out-of-process plug-ins) | Virtual devices and plug-ins can't crash the audio server or the host | AUv3's out-of-process cost made many developers stay with in-process AUv2 |
| **Hog mode** | Bit-perfect exclusive output when asked | Rarely needed, because shared output is already good |
| **Process taps** (macOS 14.2) | Capture one application's output | Arrived late; before them, streamers needed third-party loopback drivers |

**Weaknesses for these groups:** no per-application volume or routing
in the system (third-party apps such as SoundSource and Loopback fill
it), and little for gamers beyond spatial audio on AirPods. iOS shows
what the same model does on hardware the vendor controls: low latency
on every device.

**Lesson:** one low-latency path for everyone is possible, and it is
the reason musicians trust the platform. Take the clock-as-timestamps
model, the per-client render thread woken by the device clock, the
workgroup that joins a program's threads to the device's deadline, and
out-of-process drivers and plug-ins. Leave out the missing routing.

### 2.3 Linux: ALSA, PulseAudio, JACK, PipeWire

| Generation | Strength | Weakness |
|---|---|---|
| **ALSA** (kernel drivers, `dmix` in the library) | Broad hardware, mmap access to the DMA buffer | Without a server, one application per device. Complex per-board configuration (UCM) |
| **PulseAudio** (desktop server) | Per-application volume and moving streams between devices; timer-based scheduling for power | High latency, unsuitable for music |
| **JACK** (pro server) | A graph of clients, sample-synchronous, low latency, any program's output to any program's input | Takes the device away from the desktop; set up by hand; the two servers bridged clumsily |
| **PipeWire** (2017 on, default in most distributions) | One graph for both: a driver node per clock, followers woken each cycle, an adjustable quantum, adaptive resampling between clocks, the PulseAudio and JACK APIs served natively. 1.6 (February 2026) reworked link negotiation so threads synchronise without eventfd and epoll | Its policy (WirePlumber, scripts) is hard to understand and debug. Realtime threads go through rtkit, a broker, because the kernel has no admission. Configuration lives in many files |
| **PREEMPT_RT**, in mainline since 6.12 | Bounded kernel latency for anyone who enables it | Still priority-based; distributions ship it separately |

**Lesson:** PipeWire is the closest thing to the right answer, a single
graph serving both groups. It got there by absorbing two earlier
servers and keeping both their APIs, so it is large and its policy is
scattered. VectraOS can start from its shape (driver and followers, the
quantum, adaptive resampling between clocks) without the compatibility
it carries, and put admission in the kernel where rtkit can't.

### 2.4 Android

AudioFlinger's mixer made Android unusable for music for years. AAudio
(Android 8) added **MMAP mode**: the application, or the mixer, writes
straight into the device's DMA buffer, using a position the driver
publishes. Latency now depends on the phone: the "pro audio" feature
flag promises 20 ms round trip at most, and many devices miss it.

**Lesson:** the DMA buffer shared with the writer, read against a
published position, is what made low latency possible. Lack of control
over drivers and vendors is what still makes it uneven. VectraOS writes
its own drivers, so it can hold every driver to the same budget.

### 2.5 Consoles

From the NeoDarwin API study (`../NeoDarwin-workspace/NeoDarwin-api-study/platforms/consoles-modern-SUMMARY.md`)
and the public PS5 and Xbox material:

- **A system mixer with a fixed period** (NDSP's 4.9 ms, the Switch's
  audren at 5 ms). The game feeds buffers at an ordinary priority and
  never schedules a realtime thread: the system owns the deadline.
- **A system spatial renderer** that games feed objects to: the PS5's
  Tempest 3D AudioTech (HRTF with selectable profiles, hundreds of
  sources), Xbox's Windows Sonic and Atmos. The game describes sounds;
  the system renders them for what the player is wearing.
- **Chat as a system service**, mixed apart from the game, with its
  own volume on the controller.

**Lesson:** games want to push buffers and objects, not run realtime
code. The system should own the deadline and the spatial renderer, and
keep the chat apart from the game by construction.

### 2.6 Fuchsia (our kernel's ancestor)

Zircon's audio driver protocol (`fuchsia.hardware.audio`) gives the
client a **ring-buffer VMO**, position notifications, the driver's
external delay and FIFO depth, and a **clock** (a Zircon clock object
with recovery from the device's position). `audio_core` mixes clients
with a policy by **usage** (media, game, communication, system) rather
than by device. Its default latency is far above what a studio needs.

**Lesson:** the driver interface is right for a capability system: a
VMO, a position and a clock. Usages are a better policy unit than
devices. Neither the latency nor the policy's opacity should follow.

### 2.7 Plan 9 and 9front

9front's audio(3) is a directory: `/dev/audio` takes 16-bit stereo at
44.1 kHz, `/dev/volume` takes lines like `audio 80 80` and `speed
48000`, and `/dev/audiostat` reports buffering. `mixfs` binds over
`/dev/audio` to mix several writers. `cat song.pcm >/dev/audio` plays.

**Lesson:** this is the control surface D82 already chose. Because each
process has its own namespace, a mixer that binds a fresh `/dev/audio`
into each one gives every program, however naive, its own stream with
its own volume. Plan 9 had per-application routing before anyone named
it.

### 2.8 BeOS and Haiku

The Media Kit was a graph of nodes, each in its own thread, with
latency negotiated between nodes and every buffer stamped with its
performance time. It was ahead of its time for timing, and its
thread per node cost a context switch per node per buffer.

**Lesson:** explicit times on every buffer, and latency as a property of
the graph, are worth having. A thread per node is not.

### 2.9 What the survey settles

| Need | Best today | Weakest today |
|---|---|---|
| Low latency for every program at once | macOS, PipeWire | Windows (shared or exclusive, not both) |
| Class-compliant interfaces with no vendor driver | macOS, Linux | Windows (ASIO per vendor; in-box ASIO only announced, and for Arm) |
| Dropouts explained | none | all: LatencyMon and `pw-top` show symptoms, not the culprit |
| Realtime without a broker | consoles (the system owns the deadline) | Linux (rtkit), Windows (MMCSS is priority) |
| Per-application volume and routing | PipeWire | macOS (none), Windows (volume only, routing bought) |
| Capture one program, not another | Windows 11, macOS 14.2 | Linux (possible, by graph links) |
| Spatial sound on headphones | consoles, PS5 especially | Linux (none in the system) |
| Chat apart from the game | consoles | every desktop |
| MIDI 2.0 | Windows (2026), macOS, PipeWire 1.4 | — |
| Policy you can read | 9front (files) | PipeWire (scripts), Windows (registry) |

The intersection the two groups share is larger than their
differences: both want one path with low latency, devices that work
when plugged in, and routing between programs. The musician cares
about the floor of latency and dropouts; the gamer about the spatial
renderer, the chat and the microphone. None of those conflict, and no
system offers all of them.

## 3. What VectraOS already gives audio

Most of what the others had to build or broker exists here:

| Need | Other systems | VectraOS |
|---|---|---|
| A realtime deadline that is admitted | MMCSS priority, rtkit broker, Mach time-constraint threads | `realtime(period, budget)` intent, EDF with CBS and admission (principle 11, architecture §2) |
| Waking a thread from the device with its deadline | Interrupt, then a priority boost | K10c: an interrupt or counter wake lends its deadline to the thread it wakes, or runs it on a named scheduling context |
| A chain of work across processes judged as one job | Audio Workgroups (adopted per program) | Deadline donation over `channel_call` and counter waits; plug-ins on a donated context (`docs/plugins.md` §3.1) |
| A clock with a shared page | HAL zero timestamps, Zircon clocks | The display timeline (K10b): a kernel object a driver advances, with a read-only page of last time, period and count |
| Bulk between processes with no syscall while busy | Shared memory plus eventfd, Mach semaphores | The one ring (principle 6), `ring_kicks = 0` |
| Per-application routing | A server's link policy | Per-process namespaces: each program's `/dev/audio` is whatever was bound there |
| Capture consent | OS prompts | The trusted prompt (D111), the capture lamp in Deskbar (studio.md §4) |
| Dropout attribution | none | The trace (D50, D102): every cycle, wake and overrun is an event (principle 14) |
| Overrun detection | none | `thread_bind_overrun_port`: the kernel reports a budget overrun to a port (K10d) |

So the audio subsystem is mostly policy and DSP on top of mechanisms
that already pass their budgets. The new kernel work is small (§6).

## 4. Principles for audio

1. **One path.** Every stream goes through one graph. There is no
   exclusive mode and no second driver model: a program that wants the
   device's own format and no processing asks for a direct stream
   (§5.4), which is a property of a link, not a separate mechanism.
2. **The device's clock drives the graph.** The graph runs once per
   quantum, woken from the device's clock, and everything in it is
   timed in that device's samples.
3. **Low latency is the default path, not a mode.** The quantum
   follows the smallest any active client asks for, inside what the
   graph's admission allows (§5.3). Power is saved by a larger
   quantum when nobody asks, and by stopping when nothing plays.
4. **The system owns the deadline.** A game pushes buffers and objects
   and never needs a realtime thread. A program that renders per cycle
   gets one, admitted, from the audio service.
5. **A dropout has a name.** Every missed cycle is traced to its cause:
   a late interrupt, a client over its budget, a plug-in, a page fault,
   another process on the CPU.
6. **Routing is the namespace.** What a program hears and what it may
   capture is what its namespace holds. Policy is files, readable and
   writable by rc.
7. **Nothing on the realtime path allocates, faults or waits on a
   lock.** Checked at compile time and counted at run time
   (`docs/performance.md` §2, `@AudioRenderer`).

## 5. Shape

```
  ┌───────────────┐ ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐
  │ game          │ │ DAW            │ │ voice chat   │ │ cat x.pcm        │
  │ push: objects,│ │ pull: render   │ │ push + mic   │ │ >/dev/audio      │
  │ deep ring     │ │ per cycle, RT  │ │              │ │ (Node write)     │
  └──────┬────────┘ └──────┬─────────┘ └──────┬───────┘ └────────┬─────────┘
         │ ring             │ ring + counter    │ rings             │ ring
  ───────┼──────────────────┼───────────────────┼───────────────────┼──────────
  ┌──────▼──────────────────▼───────────────────▼───────────────────▼────────┐
  │ the audio service: /svc/audio                                            │
  │   per-process /dev/audio, /dev/volume, /dev/midi (bound by the launcher) │
  │   the graph: streams → usages (game, chat, media, system, studio)        │
  │              → spatial renderer, voice processing, plug-ins (D92)        │
  │              → device mixes → links (adaptive resampling across clocks)  │
  │   one realtime thread per clock domain, admitted                          │
  └──────┬──────────────────────┬─────────────────────────┬──────────────────┘
         │ DMA buffer (lent VMO) │ + device timeline page   │
  ┌──────▼──────┐  ┌─────────────▼───────┐  ┌──────────────▼──────────────┐
  │ hda(3)      │  │ usbaudio(3)          │  │ virtio-snd(3), sky1-i2s(3)  │
  │ ALC269, HDMI│  │ UAC1, UAC2, MIDI 2.0 │  │ DisplayPort audio           │
  └─────────────┘  └──────────────────────┘  └─────────────────────────────┘
        audio class (D82): /dev/audio*, /dev/audioctl, /dev/volume per device
```

### 5.1 The device class

The audio class follows D82: each device serves 9front's directory,
bound by devmgr under `/dev/audio/N/` (the device's own, which only the
audio service is given):

- `ctl`: Plan 9's lines where they exist (`speed 48000`), and the
  class's own for the rest: `format s32 2`, `period 64`, `start`,
  `stop`, the jack state.
- `volume`: 9front's lines, mapped to the codec's amplifiers.
- `stat`: 9front's `audiostat`, then the class's lines: formats and
  rates supported, channels, external delay (converter and FIFO), the
  clock domain.
- `data`: the stream. For rc and the self-tests it is a plain Node
  write or read. For the audio service, `attach` returns what a
  low-latency writer needs (§5.2).

### 5.2 The DMA buffer and the device timeline

The audio service writes the device's own cyclic DMA buffer, as
AAudio's MMAP mode and Core Audio's HAL do:

- **The driver lends the DMA buffer** to the service as a VMO, mapped
  in both. Its layout is the hardware's (interleaved frames, as the
  BDL or the USB endpoint sees them), as an NVMe queue's is. It is not
  a ring in principle 6's sense, because it has no cursors: the
  position comes from the clock.
- **The driver advances a device timeline** at each period interrupt
  (or each USB frame's completion): the stream's sample position and
  the monotonic time it was read, written to the timeline's read-only
  page. On the Sky1 the position comes from `SDnLPIB`
  (`sky1-audio` 02 §2.2.4). The service extrapolates the position at
  any moment from the last pair and the measured rate, as the HAL does,
  and never reads a register (D167: one owner a register page).
- **The graph's thread is woken by that timeline,** at a configured
  offset before the hardware reaches the next quantum, with the graph's
  deadline (K10c). The offset (the "safety offset") is the driver's
  reported FIFO depth plus a measured margin.
- **Capture** is the same in reverse: the service reads the capture
  buffer behind the position.

This is the one new kernel use: the timeline was made for displays. §6
proposes it becomes a device timeline any driver may advance.

### 5.3 The graph and its quantum

- **One graph per clock domain.** A clock domain is a device, or
  devices that share a word clock. Each domain has one realtime thread
  in the audio service, admitted as `realtime(quantum, budget)` where
  the budget is the sum of the measured costs of everything in its
  graph plus a margin. A new client or plug-in that would push the
  total past the admitted budget is refused at link time, not
  discovered as a dropout.
- **The quantum** is the graph's period in frames, a power of two from
  32 to 2048 at the device's rate. It is the smallest quantum any
  active stream asks for, or 256 (5.3 ms at 48 kHz) when none asks.
  It changes between cycles without a gap, as PipeWire's does, and
  only when the new graph is admitted at the new period.
- **Samples in the graph** are 32-bit float, non-interleaved. Formats
  are converted at the edges: a client's ring, a device's buffer.
- **Each cycle,** in order: read every capture device; wake the pull
  clients (§5.5) and wait for their counters, each with a deadline
  inside the cycle; mix each usage; run the spatial renderer and the
  plug-in chains; mix each device's output and write its buffer; trace
  the cycle.
- **A late client is skipped, not waited for.** If a pull client hasn't
  signalled by its deadline, the graph uses silence for it this cycle,
  counts a client xrun against it, and goes on. Only the service's own
  work can make a device xrun. This is what JACK did not do and what
  makes a misbehaving plug-in host survivable.
- **Other clock domains** link through an adaptive resampler, whose
  ratio follows the two timelines' measured rates, as PipeWire's and
  Core Audio's aggregate devices do. Two interfaces used together are
  an aggregate made by a link, not by a settings dialog.

### 5.4 Streams, usages and links

- **A stream** is one client's output or input: a format (rate,
  channels, sample format, channel layout), a usage, and a ring.
- **A usage** is the policy unit, as in Fuchsia: `media`, `game`,
  `chat`, `system`, `studio`, `alert`. Each usage has a volume, a
  default destination and a mute. Volumes and destinations are per
  usage and per program, so "chat to the headset, game to the TV" and
  "the stream gets the game but not the chat" are two lines of policy.
- **A link** joins a stream or a usage to a destination: a device, a
  virtual device (§5.7), another program's input, or a capture tap.
  Links are files (`/svc/audio/links`), so rc, Settings (D115) and the
  Ghost read and write the same thing. A program with no explicit link
  follows its usage's default, and a default follows the device the
  user last chose or plugged in.
- **A direct link** carries a stream unchanged to a device that can
  take its format: no resampling, no volume, no effects. The device
  switches to the stream's rate if nothing else plays, otherwise the
  link is refused as direct and plays converted. Bit-perfect playback
  and passthrough of encoded streams (IEC 61937 over HDMI and
  DisplayPort) are direct links. This replaces exclusive mode.
- **Moving a stream** between devices (a headset unplugged, a link
  changed) ramps out on the old device and in on the new one within
  one quantum, with no click and no program involvement.

### 5.5 Clients: push and pull

Both use the one ring; they differ in depth and in who is woken.

- **Push** (games, players, chat, `cat`): the client writes frames ahead
  into a ring several quanta deep. The graph reads one quantum a cycle.
  The client wakes on its ring's doorbell when the ring falls below a
  watermark it set, at whatever intent it runs (`frame`,
  `interactive`). While both sides are busy, no syscall (`ring_kicks =
  0`). Latency is the ring's depth, which the client chooses and
  `stat` reports. A game at the default quantum with a two-quantum
  ring hears a sound about 10.7 ms after it submits it, plus the
  device's external delay.
- **Pull** (DAWs, synthesisers, effects processors): the client renders
  exactly one quantum each cycle. Its render thread is given to it by
  the audio service's scheduling context: the graph signals a counter,
  the client's thread wakes on it with the graph's deadline lent (K10c),
  renders into its ring, and signals its own counter. The admission
  covers it. A program with worker threads (a DAW rendering tracks in
  parallel) joins them to the same context, as an Audio Workgroup does,
  so the whole render is one admitted budget.
- **The minimal client** is a Node write: `cat` into `/dev/audio`,
  9front's format by default, with `/dev/volume`'s `speed` and
  `format` lines. The audio service serves it a push stream with the
  `media` usage.

### 5.6 The namespace

The launcher binds the audio service's per-process files into each
program's `/dev`:

```
/dev/audio        this program's default output stream (and input,
                  if granted): 9front's format, or what ctl set
/dev/audioctl     format, usage, ring depth, pull or push
/dev/volume       this program's volume lines
/dev/midi/        the MIDI endpoints it was given (§7.3)
```

and the service's own tree:

```
/svc/audio/
  devices/N/{name,stat,clock,volume,jack}
  streams/<pid>.<n>/{program,usage,format,peak,xruns,latency}
  usages/<usage>/{volume,mute,default}
  links             one link a line; writable
  graph/<clock>/{quantum,budget,used,cycles,xruns,offset}
  taps/             capture grants in force (§9)
```

Principle 19: `cat /svc/audio/graph/*/used` is the load meter, and
`cat /svc/audio/streams/*/xruns` says who dropped out.

### 5.7 Virtual devices

A virtual device is a named mix that is not a hardware output: "Stream"
(what Studio sends out), "Recording", "Monitor". It is a node in the
graph with its own links, so a streamer can send the game and the
microphone to "Stream", the game and the chat to the headset, and never
install a router. It replaces Voicemeeter, Sonar and Loopback with the
graph's own links.

## 6. What the kernel must add

Little, by design:

1. **A device timeline,** generalised from the display timeline (K10b):
   any driver holding a device resource advances it with a hardware
   timestamp and a position (sample count, not vblank count), and its
   page carries position, time, nominal rate and a flag for a
   synthesised tick. One object type for display and audio clocks
   (principle 1). The wake with an offset ("wake me when position
   reaches N, minus this much time") is new.
2. **A scheduling context shared across processes,** so a pull client's
   threads run on the audio service's admitted context. K10c names a
   context on a wait; this needs the same for a thread that joins a
   context it was handed (a handle to it, with a right to join).
3. **Overrun attribution** in the trace: when a donated context
   overruns, the event says which thread held it.

No audio code runs in the kernel. Drivers are user-space driver hosts,
as every class is (D74).

## 7. Components

### 7.1 Drivers

In the order the roadmap needs them:

| Driver | Where | Notes |
|---|---|---|
| `virtio-snd` | QEMU, all arches | The self-tests' device. Has its own period and position model; the timeline is advanced from its completions |
| `hda` | Sky1 (`CIXH6020`, ALC269), amd64 | One controller driver with the codec as a parser of its widget graph. Sky1's deviations (`sky1-audio` 02 §2.2): 32-bit accesses only, RIRB polled, 100 µs stream reset, DMA addresses minus `0x90000000`, a pool from `RSVL`. Jack sensing by polling while the RIRB can't interrupt |
| `sky1-i2s` with DMA-350 | Sky1 DisplayPort 0 to 4 | I2S5 to I2S9 feed the DP transmitters (`sky1-audio` 03 §3.4); the ELD comes from dptx(3). Missing instances skipped |
| `usbaudio` | xhci(3), every board | UAC1 and UAC2, isochronous, asynchronous and adaptive endpoints, explicit and implicit feedback. The semi-professional's interface and the gamer's headset are both this driver. UAC3 later |
| HDMI and DP codecs on amd64 | HDA's digital pins | With the GPU's display driver for the ELD |

`usbaudio` needs isochronous transfers in xhci(3), which drives HID,
hubs and (planned) mass storage today. It is the largest piece of
driver work here and the one semi-professionals judge the system by.

### 7.2 The audio service

One process, `/svc/audio`, started on demand (D99) and stopped when no
stream has been open for a while, with devices powered down (the Sky1's
audio power domain off, `sky1-audio` 00 §0.4). Its parts:

- the graph and its realtime threads (§5.3);
- format conversion and a resampler (windowed sinc, checked against a
  reference in the host tests for passband ripple and alias rejection);
- the policy: usages, links, defaults, device choice, all in files,
  persisted as Taisce attributes on the settings node (D113);
- the spatial renderer (§7.4) and voice processing (§7.5);
- plug-in points for effects (§7.6).

### 7.3 MIDI

- **One format: MIDI 2.0 Universal MIDI Packets** (UMP), 32 to 128-bit
  words, on rings. MIDI 1.0 devices and programs are translated to and
  from UMP at the edge, as Windows MIDI Services and PipeWire 1.4 do.
- **Every message is timestamped** in the clock domain's sample
  position, so a synthesiser renders a note at the right sample within
  its quantum.
- **Endpoints** are files under `/dev/midi/` and links in the same
  `links` file as audio: a controller to a synthesiser, a sequencer to
  an external device. Multi-client by construction.
- **Drivers:** USB MIDI 1.0 and 2.0 class (with `usbaudio`), and
  virtual endpoints between programs.

### 7.4 Spatial audio and surround

- **Games submit objects:** a mono stream with a position, an extent
  and a distance model, updated per frame on the game's ring. Up to a
  budgeted number of objects (proposed: 128 dynamic objects, as
  `ISpatialAudioClient` games expect) plus channel beds up to 7.1.4.
  First-order and higher-order Ambisonics as a bed format.
- **The system renders them** for what is on the output:
  - headphones: binaural, with an HRTF chosen from a small set of
    measured sets (as the PS5 offers), shipped as data converted on the
    host from public SOFA files to our format (D4: the host tool's
    output is our format);
  - speakers: the device's layout, from the ELD or the user's setup;
  - a receiver: channels or, for encoded streams, a direct link.
- **Headphone correction:** a parametric equaliser per output, with
  profiles as data (the published measurements of common headphones).
- **The foreign layer** maps `ISpatialAudioClient` and XAudio2's 3D to
  objects (`docs/foreign.md` §6.9).

### 7.5 Voice

- **On the `chat` usage's input:** echo cancellation against what the
  graph is playing (the graph knows exactly, sample for sample, which no
  per-application canceller does), noise suppression, gain control.
  First-party DSP first; a learned suppressor on V8's NPU later.
- **No ducking by default.** A program may ask to duck other usages; the
  user's policy decides.
- **Sidetone** for headsets that lack it: the microphone into the
  headset's mix at a low level, inside one quantum.
- **Push-to-talk and mute** as `ctl` lines, so a hotkey or a headset's
  button reaches every chat program the same way.

### 7.6 Plug-ins and hosts

- **System effects** (the equaliser, a limiter, a reverb send for
  monitoring) are plug-in processes on the graph's rings (D92), run on
  the graph's donated context and counted in its admission.
- **A DAW hosts its own plug-ins.** The system's plug-in interface for
  audio effects and instruments is an IDL interface (`docs/plugins.md`
  §3.1), so a first-party DAW and the system mixer host the same
  plug-ins out of process. Whether a plug-in may run inside its host
  at very small quanta is `docs/plugins.md`'s open question 2,
  answered by measurement at V9.
- **Third-party plug-in formats** (CLAP, VST3) are third-party code on
  the device: the D4 question `docs/foreign.md` §10.1 raises for games.
  This design assumes the same answer for both.

### 7.7 The SDK

- `Audio.output(usage:)` and `Audio.input(usage:)` return push streams:
  a span to write, a commit, a doorbell that joins the program's one
  port (principle 9).
- `@AudioRenderer` (lifted from todhchai's SDK, `docs/provenance.md`)
  marks a pull render function: the macro registers it, puts
  `@_noAllocation` on it, and the SDK runs it on the thread the audio
  service lends.
- `Audio.objects` for spatial sources, `MIDI.endpoints` for MIDI.
- Within principle 21: a program that plays a tone takes at most four
  calls.

## 8. Later

### 8.1 More board audio

The Sky1's I2S0 to I2S2 (single-channel: codec, Bluetooth, loopback)
have no ACPI device on this firmware (`sky1-audio` 00 §0.6) and wait
for a board that wires them.

### 8.2 Per-board tuning

The vendor's codec verb tables (`sky1-audio` 02 §2.5) are board facts,
compiled in as D126's board rules are.

### 8.3 The HiFi5 DSP

Offloading the graph to the Sky1's HiFi5 could lower power for media
playback. It needs our own DSP firmware, built with a third-party
compiler as a host tool, and a transport over its mailboxes. It is
deferred until the CPU path's power budget says it is needed.

### 8.4 Network audio

AES67 (RTP with PTP time) between VectraOS nodes over the swarm, and to
studio equipment that speaks it. The device timeline makes a PTP clock
one more clock domain. This waits for PTP in the network service.

## 9. Security and consent

- **Output** needs no grant: a program has a `/dev/audio` unless its
  manifest says otherwise.
- **Microphones** need a grant: the trusted prompt (D111) the first
  time, a lamp in Deskbar while any input is open, and the program named
  in `/svc/audio/taps`.
- **Capturing another program's output** (Studio's application audio,
  `docs/studio.md` §4) takes the same grant and lamp as screen capture.
  Secure sounds (none yet) would come out silent, as secure surfaces
  come out black.
- **A link to another program's input** is made by the user or by a
  program holding the grant; a program can't route itself into another.

## 10. Budgets and checks

Each budget lands with its check and a milestone (`docs/performance.md`).
These are proposals, to be set from first measurements. Each check
keeps to a few minutes (the owner rejects long-running checks).

| Budget | What it measures | Proposed limit | Check |
|---|---|---|---|
| `audio.cycle_wake` | device timeline to the graph thread running, p99 | 50 µs | trace, virtio-snd in QEMU and HDA on the Sky1 |
| `audio.client_wake` | graph's counter signal to a pull client running | as `channel_call`'s wake | trace |
| `audio.roundtrip_64` | analogue in to analogue out at 64 frames, 48 kHz, through a pull client | 5 ms | a loopback cable on the Sky1's jacks (a board run, B7) |
| `audio.xruns_load` | device and client xruns at 64 frames for 3 minutes with `make -j` and a GPU load | 0 | board run; D127's "audio at 128 frames under load" against Linux |
| `audio.game_latency` | a push submission to the DAC at the default quantum | 11 ms plus external delay | trace and loopback |
| `audio.rt_allocs` | allocations, faults and lock waits on the graph and pull threads | 0 | run-time count (`docs/performance.md`) |
| `audio.move_gap` | a stream moved between devices, silence or click | one quantum, ramped | self-test with two virtio-snd devices |
| `audio.drift` | two clock domains linked for 3 minutes: buffer error | bounded, no xrun | self-test with two devices at offset rates |
| `audio.idle_wakeups` | wakeups with no stream open | 0 | as `idle.wakeups` |
| `audio.mix_cost` | graph cost per stereo stream per cycle on the Sky1's big cores | set at first measurement | bench |
| `audio.resampler` | passband ripple, alias rejection | to a reference | host test |
| Size | the service, each driver, the spatial renderer | a line ceiling at the milestone's start | `vx loc` |

## 11. Decisions this needs

1. **The audio graph** (one path, no exclusive mode, direct links,
   usages, links as files, skipped late clients). The design's core;
   amends nothing but fills D82's audio row.
2. **The device timeline:** the display timeline generalised for audio
   clocks (§6.1), one object type for both.
3. **Joining a scheduling context across processes** (§6.2), with its
   right and its admission rule.
4. **The DMA buffer is the hardware's, not a ring:** a driver lends it
   to the audio service, as hardware queues are never the one ring
   (principle 6's scope stated).
5. **UMP as the one MIDI format.**
6. **Third-party plug-ins and D4,** together with foreign.md's 10.1.
7. **The service's name** (D12), if it gets one.

## 12. Open questions

1. **Order against the roadmap.** V6f item 3 brings the class forward
   onto the Sky1 now. Proposed: the class, the service with push
   streams, virtio-snd and HDA with the ALC269 (V6f 3), DP audio with
   it; then pull clients, the device timeline and the budgets; then
   `usbaudio` and MIDI (with xhci's isochronous transfers); then the
   spatial renderer and voice for V9's reference game; taps for V15.
   Does USB audio belong in V6f (the board is feature complete without
   it) or in the backlog's "USB beyond HID"?
2. **Is HDA's period interrupt good enough on the Sky1** for 64
   frames, or does the timeline need a timer between interrupts?
   Measure `SDnLPIB` against the interrupt first.
3. **Does a pull client ever need to render in the service's process?**
   `docs/plugins.md`'s open question 2, the same measurement.
4. **The default quantum:** 256 balances power and latency on the Sky1;
   a gamer with a fast headset may want 128 always. A per-usage floor?
5. **HRTF sets:** which public sets, and how many. Personalised HRTFs
   from a photo are out of scope.
6. **The audio DSP:** does the Sky1's power at idle playback justify
   §8.3 before V14?

## Sources

- Microsoft, *Windows Music Dev blog* (2024-10-21): ASIO and low-latency
  UAC2 driver plans. Neowin, "Microsoft will release a new low-latency
  audio driver for Windows on Arm in 2026".
- Microsoft, "Making music with MIDI just got a real boost in Windows
  11" (2026-02-17).
- Phoronix, "PipeWire 1.6 Released With Many New Features"
  (2026-02-19); heise, "PipeWire 1.4: MIDI 2 and new audio codecs".
- Apple, Core Audio HAL, AudioServerPlugIn, Audio Workgroups and
  `CATapDescription` documentation.
- Android, AAudio and MMAP documentation.
- `../fuchsia/sdk/fidl/fuchsia.hardware.audio`, `../fuchsia/src/media/audio/audio_core`.
- `../9front/sys/man/3/audio`, `../9front/sys/src/cmd/audio/mixfs`.
- `../NeoDarwin-workspace/NeoDarwin-api-study/platforms/consoles-modern-SUMMARY.md`.
- `../chinese-wall/specs/sky1-audio` (00, 02, 03).
