# Studio: streaming for creators

A vision and design (2026-10-17, proposed; D96). Neither NeoVectra
nor todhchai planned a stack for live streaming. todhchai came closest
with Radharc's `capture` service and a Recorder planned as its reference
program (`desktop.md`). Studio does what OBS does, built the system's
way: our own code, speaking the protocols that streaming services and
players already use (`docs/apps.md` §1). It is proposed for V15
(`docs/apps.md` §9).

## 1. What it is

Studio is a service and an application for people who stream or
record what they make: games, code, music, drawing, talk. It:

- takes sources (screens, windows, games, cameras, microphones,
  application audio, media files, remote guests);
- arranges them into scenes;
- mixes their audio;
- encodes the result once;
- sends it to one or more destinations: a streaming service, a server
  of the creator's own, and a file on disk.

The Recorder is Studio with only a file as its destination.

It is for the people the vision names. Indie game developers stream
their games and devlogs. Makers stream builds, with a board's camera
as a source. Systems hackers stream their code. The frame loop's
guarantees (principle 11) are what keep a game smooth while the stream
encodes.

## 2. The rules it lives under

Studio adds no mechanism the system lacks. Each part is an existing
mechanism used for one more purpose.

| Need | The mechanism it uses | Principle |
|---|---|---|
| Frames and samples between stages | the one ring | 6 |
| Buffers | VMO, format descriptor and timeline fence | 8 |
| Pixels from the screen | Radharc's `capture` service, after a trusted prompt | 26 |
| Stages | processes, one per source, encoder and output | 4 |
| Filters and effects | plug-in processes | D92 |
| Scenes and settings | Taisce files with attributes | 18 |
| Control | `/svc/studio`'s node tree, rc and the plumber | 5, 19 |
| Stream keys | factotum | D75 |
| Timing and scheduling | `realtime` and `frame` intents, admission-tested | 11 |
| Latency and drops | trace events, read as budgets | 13, 14 |
| A second machine | the swarm and 9gate | V7 |

Four rules follow from these:

- **Off means absent.** When nothing is live or recording, Studio costs
  nothing: no capture is held, no encoder is open, nothing wakes.
- **No pixel crosses the CPU.** Capture, compositing, conversion and
  encoding stay on the GPU and the video unit, as V8's camera path
  does.
- **Capture is visible.** Something being captured shows a lamp, as
  the Ghost's egress does.
- **A scene file can be shared.** A scene holds no secret; keys live in
  factotum.

## 3. Shape

```
sources                         compositor            encoders        outputs
 screen / window (capture) ─┐
 game (scanout buffers)     ├─▶ scene graph on GPU ─▶ video encoder ─┬─▶ RTMP(S)  → Twitch, YouTube, Kick, PeerTube
 camera (UVC)               │   (Vulkan, NV12 out)   (HW, else SW)   ├─▶ SRT      → a producer, a relay
 media file (V14 decoders)  │                                        ├─▶ WHIP     → WebRTC ingest
 remote: SRT, WHIP, swarm  ─┘                                        ├─▶ HLS      → the creator's own node
 mic, app audio, remote ───────▶ mixer (realtime) ──▶ audio encoder ─┤
                                                                     ├─▶ file     → fMP4 or Matroska in Taisce
                                                                     └─▶ replay   → the last N seconds, on demand
```

- **Each box is a process** with its own namespace, holding only what
  it was given.
- **`studio` serves `/svc/studio`.** That covers the scenes, the live
  state, each output's status and the `ctl` file. It starts the stage
  processes and joins them with rings.
- **The Studio application is a view** of `/svc/studio`, as
  `docs/apps.md` §3 has every application be one. The same control is
  open to rc, the plumber, a control surface or the Ghost:

```
echo scene gameplay > /svc/studio/ctl
echo live twitch youtube > /svc/studio/ctl
echo replay save > /svc/studio/ctl
cat /svc/studio/outputs/twitch/status   # bitrate, dropped, rtt
```

- **Fan-out.** The one ring has one consumer, so an encoded stream goes
  to several outputs through the encoder writing one ring per output.
  There is no broadcast ring.

## 4. Sources

- **Screens and windows** come from Radharc's `capture` service
  (todhchai `desktop.md`). It hands over whole outputs, single windows
  or view subtrees, with damage regions. A grant takes a trusted
  prompt, and Deskbar shows who holds one. Secure surfaces, such as
  factotum's prompt and the trusted path, come out black. Today only
  whole-screen `frame()` exists; windows, subtrees and damage are this
  milestone's work.
- **Games** in game mode hand Studio their scanout buffers, with no
  copy and no readback.
- **Cameras** use the USB Video Class (UVC): MJPEG, YUY2 and NV12
  from USB webcams and capture cards. This is the system's first
  camera code. A board's MIPI cameras follow with its ISP, as V8's
  camera path has it.
- **Microphones and line inputs** come from `/dev/audio` (D82).
- **Application audio** is one application's output tapped as a
  source, with the same grant and lamp as screen capture. This lets the
  stream carry the game but not the voice chat.
- **Media files** are played through V14's decoders.
- **Overlays.** An overlay is native: a small UI Kit view, drawn from
  data. Examples are the chat's live query, a follower alert from a
  service's events, a timer or a now-playing line. It is never a web
  page. Overlays are application interfaces, and the web is not how
  VectraOS delivers those (`docs/apps.md` §1). That rules out OBS's
  browser source and the script-driven overlay services built on it.
  An overlay is a plug-in process (D92), so a creator's own overlay is
  compiled code, as any plug-in is.
- **Remote sources:**
  - a guest or a phone's camera arriving over SRT or WHIP;
  - another VectraOS node's capture over the swarm (§8).

## 5. Scenes and audio

- **A scene is a directory** of source files in Taisce. Each file's
  attributes hold placement, crop, scale, opacity, filters and
  visibility. Studio edits scenes, and so can rc, the Ghost or a
  shared scene pack. Scenes switch through transitions (cut, fade,
  wipe, stinger) within one frame.
- **The compositor** is a Vulkan pass that turns the scene into the
  encoder's format (NV12, or P010 for 10-bit). todhchai reserved those
  buffer formats for exactly this hand-off.
- **Filters** are plug-in processes on rings (D92). Examples are
  colour correction, chroma key, sharpening, and on V8's NPU,
  background removal as a `.vxm`. A filter that misses its deadline
  is bypassed and reported, never left to stall the scene.
- **The mixer** runs under a realtime intent, admission-tested
  (principle 11). It handles:
  - per-source gain, mute, monitoring and a sync offset;
  - filters: noise gate, compressor, limiter, and noise suppression,
    which may run on the NPU;
  - loudness measured to ITU-R BS.1770 and shown against the
    destination's target (EBU R128 or a service's own).
- **Control surfaces.** Stream-deck-style keypads are USB HID and send
  plumb messages or `ctl` lines. MIDI faders are USB MIDI, for the
  mixer. Neither needs code of its own.

## 6. Encoding

There is one encoder interface: a process takes raw frames on a ring
and returns packets on another, with its controls in a node (codec,
rate control, bitrate, keyframe interval, profile). Behind that
interface sit the following.

- **Hardware first.**
  - The Orange Pi 6 Plus's Mali-V encodes H.264, HEVC, VP8 and VP9 in
    firmware, which is listed under `firmware/` (AbyssBSD's `vpu.md`).
    It has no AV1 encoder.
  - Desktop GPUs' video engines (AMD's VCN, Intel's, NVIDIA's) come
    with their GPU drivers (D62's desktop track). Both memory models
    are covered.
- **Software encoders:**
  - **Opus** (RFC 6716) for audio, checked against the RFC's reference
    code on the host.
  - **AV1** as the royalty-free video path. It is slower, so it is
    used for recording and for lower resolutions live.
  - **AAC-LC**, only if a destination still requires it (§9).
- **Rate control for streaming** is constant bitrate with a fixed
  keyframe interval (2 s by default), as ingest services expect. A
  recording may use constant quality instead.

## 7. Outputs

Every protocol here is an existing one. Each output is a process that
holds its destination's key through factotum and reaches the network
through `/net`.

- **RTMP and RTMPS**, carrying FLV, is the ingest that every major
  service takes (Twitch, YouTube, Kick, Facebook), and so do PeerTube
  and Owncast. **Enhanced RTMP** carries HEVC and AV1, and Opus,
  where a service accepts them.
- **SRT** is for links to a producer or a relay, and for remote
  guests, recovering lost packets. It is an open specification, an
  IETF draft rather than an RFC.
- **WHIP** (RFC 9725) is WebRTC ingest, under a second of latency. It
  needs only WebRTC's media path: ICE, DTLS-SRTP and RTP, which V16's
  calls share. There are no data channels, no SCTP, and none of the
  browser's WebRTC API. **WHEP**, its
  playback side, lets a creator preview their own stream.
- **HLS** (RFC 8216, including low-latency HLS) with fMP4 segments is
  served by a VectraOS node acting as the creator's own origin. Any
  player can watch it, and V12's ActivityPub service announces that
  the stream is live. That is the self-hosted case (Owncast's model),
  and with the swarm the origin can be another of the creator's
  machines.
- **Recording.** Recordings are fragmented MP4 or Matroska, so a crash
  still leaves a playable file. A recording is a Taisce file with
  attributes: the scene, the game and the markers, which become
  chapters.
- **The replay buffer** keeps the last N seconds of encoded packets in
  a ring in overwrite mode, the same protocol the trace rings use.
  Saving it writes a file without touching the live stream.
- **Multistream.** One encode can feed several outputs. Separate
  encodes, for different resolutions per service, can also run when
  the hardware has room.

## 8. Two machines

A common setup is one machine that plays and another that encodes and
sends. On VectraOS that is the swarm (V7). The game machine's capture
ring is bridged to the encoding node, whose Studio treats it as a
local source.

Raw 1080p60 NV12 is about 1.5 Gbit/s, so the link needs 2.5 GbE or
better (the RTL8125 is 2.5 GbE and the RTL8126 is 5 GbE), or a light
intra-frame codec on the game machine. This is the roadmap's open
question 3 (a transport for remote rings) with a concrete workload.

## 9. Open questions

1. **Patented codecs.** RTMP to most services means H.264 and AAC.
   Should H.264 and HEVC use only hardware encoders, and AV1 be the one
   software video encoder? Is AAC-LC written at all, or do we prefer
   Enhanced RTMP with Opus where services accept it?
2. **Platform APIs.** Twitch's chat is IRC with IRCv3 tags, so V12's
   IRC service reads it. Follows, subscriptions, YouTube's chat and
   stream metadata (title, category) are each vendor's own documented
   HTTP API, not an open standard. May a protocol service speak a
   vendor's documented API, or does Studio leave them out?
3. **Cameras in `/dev`.** Cameras need a device-directory row in D82's
   table (`/dev/video` or `/dev/camera`, with its ring), and so do
   hardware encoders.
4. **A ready-made set of overlays.** Overlays are native plug-ins
   (§4). Which ones ship with Studio (chat, alerts, timers, now
   playing, a webcam frame), and how a creator restyles them without
   code? A theme's roles (D91) are the likely answer, since they
   would add no format.
5. **The transport for bridging raw frames** between nodes (§8).
6. **Oracles for the encoders.** An encoder has no single right
   output. Its tests decode with the reference decoder and judge
   quality (PSNR or SSIM against the source) and conformance, not
   bytes.

## 10. What earlier milestones should design in now

- **V5:** `capture` grants per window and per subtree, with damage
  regions; a capture lamp in Deskbar; NV12 and P010 kept in the
  graphics buffer formats.
- **V5 and V14:** audio taps per application in the audio service,
  with the same grant as capture.
- **V7:** remote rings sized for raw video, which ties to open
  question 3 in the roadmap.
- **V8:** the camera path's sources and the NPU filters use the same
  ring and buffer formats Studio's sources do.

## 11. Budgets

The checks below are proposed and land with V15. Each is read from
trace events.

| Budget | What it measures | Proposed limit |
|---|---|---|
| `studio.capture_to_encode` | a captured frame to the encoder's input | 1 frame (16.7 ms at 60 fps) |
| `studio.frames_dropped` | frames dropped in a 1-hour 1080p60 stream on the Orange Pi 6 Plus | 0 |
| `studio.av_drift` | audio against video at the output | 20 ms |
| `studio.cpu_pixel_copies` | pixels copied by the CPU between a source and the encoder | 0 |
| `studio.audio_xruns` | mixer underruns and overruns in that hour | 0 |
| `studio.scene_switch` | a scene switch command to the first frame of the new scene | 1 frame |
| `studio.glass_to_glass_lan` | camera to a WHEP viewer on the LAN | 500 ms |
| `studio.idle_wakeups` | wakeups while not live or recording | 0 |
| Size | each of `studio`, the mixer, the compositor, each encoder and each output | a line ceiling set at V15's start (`docs/apps.md` §3, rule 8) |
| `game.frame_budget_live` | the reference game's frame budget while streaming it | unchanged from V9 |
