# D179. The audio graph: one path for every stream through one audio service, driven by the device's clock, with no exclusive mode; direct links instead, usages as the policy unit, links as files, and a late client skipped rather than waited for (2026-11-26, decided by the owner; fills D82's audio row)

`docs/audio.md` surveyed how Windows, macOS, Linux, Android, the
consoles, Fuchsia, Plan 9 and Haiku do audio, and what home studios and
gamers each need. Its §11 listed the decisions the design needs. The
owner accepted its first, the graph (2026-11-26), with the fourth
(D180). The device timeline (§11.2), joining a scheduling context
across processes (§11.3), UMP for MIDI, third-party plug-ins and the
service's name stay open.

## The decision

- **One path.** Every stream, a game's, a player's, a DAW's, `cat`'s,
  goes through one graph in one audio service. There is no exclusive
  mode and no second driver model: what exclusive mode gave (the
  device's own format, no processing, bit-perfect output, encoded
  passthrough) is a **direct link**, a property of a link that the
  graph refuses and plays converted when the device can't take the
  stream unchanged (audio.md §5.4).
- **The device's clock drives the graph.** One graph per clock domain,
  run once a quantum, woken from that device's clock, its work timed in
  that device's samples, on one admitted realtime thread
  (`realtime(quantum, budget)`). A client or plug-in that would push
  the graph past its admitted budget is refused when it links, not
  found later as a dropout (§5.3).
- **Low latency is the default path.** The quantum is the smallest any
  active stream asks for (a power of two, 32 to 2048 frames), or 256
  when none asks. Power is saved by a larger quantum and by stopping
  when nothing plays, never by a second path.
- **A late client is skipped.** A pull client that hasn't signalled by
  its deadline is heard as silence for that cycle and charged a client
  xrun; only the service's own work can make a device xrun.
- **Usages are the policy unit** (`media`, `game`, `chat`, `system`,
  `studio`, `alert`): each has a volume, a mute and a default
  destination, per program as well as system-wide.
- **Links are files.** `/svc/audio/links` holds one link a line, which
  rc, Settings and the shell read and write alike. A program without a
  link follows its usage's default.
- **Routing is the namespace** (principle 6 of audio.md): what a
  program plays to and may capture is what is bound at its `/dev/audio`.
- **The device class is D82's:** each device serves 9front's audio(3)
  directory (`ctl`, `stat`, `volume`, `data`), bound by devmgr at
  `/dev/audio/N/`, which only the audio service is given in a normal
  boot. `data` takes plain Node reads and writes, so rc and the
  self-tests reach a device without the service.

## What it replaces

Nothing yet runs: this is the first audio mechanism (principle 1). It
fills the audio row D82 left as a directory shape, and it rules out the
second paths other systems grew: an exclusive mode beside the shared
one (WASAPI, ALSA `hw:` beside PulseAudio), and a separate low-latency
server (JACK beside PulseAudio).

## Consequences

- Drivers come first and are tested without the service: a device's
  `data` is enough for a test to play and record (audio(3)).
- The audio service is its own step after the first drivers: push
  streams, then pull clients with the device timeline (§11.2) and the
  budgets of audio.md §10, each with its check.
- The order is audio.md §12.1's: the class and virtio-snd, the service
  with push streams, HDA with the ALC269 on the Sky1, DisplayPort
  audio; then pull clients, `usbaudio` and MIDI.
