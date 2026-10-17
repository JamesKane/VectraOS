# D96. Studio: streaming for creators, on capture, rings and existing ingest protocols (2026-10-17, proposed)

The owner noted (2026-10-17) that NeoVectra and todhchai both missed a
stack for creators who stream. todhchai had only Radharc's `capture`
service and a planned Recorder. `docs/studio.md` is the design.

- **Studio is a service with a view.** `/svc/studio` holds:
  - scenes, as Taisce directories of sources with attributes;
  - the live state;
  - each output's status;
  - a `ctl` file.

  The Studio application, rc, the plumber, control surfaces and the
  Ghost all drive it the same way.
- **No new mechanism.**
  - Sources, the compositor, filters, encoders and outputs are
    processes joined by the one ring, over the one buffer currency.
  - Screens and windows come through `capture`, after a trusted prompt
    and under a lamp.
  - Filters are plug-in processes (D92).
  - Stream keys are factotum's.
  - The replay buffer is a ring in overwrite mode.
  - Two-machine setups are the swarm.
- **Existing protocols only:**
  - RTMP or RTMPS with FLV, and Enhanced RTMP, to the services;
  - SRT, WHIP (RFC 9725) and WHEP, and HLS (RFC 8216) from the
    creator's own node;
  - fragmented MP4 or Matroska for recordings;
  - UVC for cameras;
  - ITU-R BS.1770 for loudness.
- **Encoding is hardware first:** the Orange Pi 6 Plus's Mali-V
  (H.264, HEVC, VP8, VP9), then desktop GPUs' engines with D62's
  drivers. Opus and AV1 are first-party software encoders.
- **Budgets** (`docs/studio.md` §11):
  - no frame dropped in an hour at 1080p60 on the board;
  - no CPU pixel copies;
  - one frame from capture to the encoder;
  - no wakeups when idle.
- **Proposed placement:** V15, after V14's media pipeline. V16's calls
  reuse its encoders and its WebRTC media path. Earlier milestones
  design in, in V5:
  - per-window capture with damage;
  - the capture lamp;
  - NV12 and P010 buffer formats;
  - per-application audio taps.

Open, in `docs/studio.md` §9:

- software H.264, HEVC and AAC, given their patents;
- whether a service may speak a vendor's documented HTTP API (Twitch,
  YouTube);
- the device-directory row for cameras and encoders;
- overlays without JavaScript;
- the transport for raw frames between nodes.

Not chosen:

- Porting OBS or FFmpeg (D4).
- A web page as a source or overlay, with or without JavaScript.
  Overlays are application interfaces, so they are native plug-ins
  (D95).
- A broadcast ring for fan-out. The one ring has one consumer, so the
  encoder writes one ring per output.
