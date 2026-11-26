# D180. An audio device's buffer is the hardware's, not a ring: the driver owns one cyclic buffer a stream, in the hardware's layout, whose position comes from the device's clock; the audio service is lent it, and the one ring carries clients' streams only (2026-11-26, decided by the owner; states principle 6's scope)

Principle 6 makes the one ring (D43) the bulk path between processes.
An audio device's DMA buffer looks like a candidate and isn't one: it
has no cursors. The hardware reads (or writes) it in a cycle at its own
rate, and the only position is the device's, read from its clock, as an
NVMe queue's layout is the controller's (audio.md §5.2, §11.4).

## The decision

- **One cyclic buffer a stream, the driver's.** A driver keeps, for each
  playback and capture stream it runs, one buffer of N periods in the
  hardware's layout: interleaved frames as the BDL, the I2S DMA or the
  USB endpoint sees them, in memory the device reaches through its BTI.
  It is not a ring in D43's sense and carries no ring header.
- **The position is the device's.** It advances when the hardware says a
  period is done (an interrupt, a completion, `SDnLPIB`), with the
  monotonic time it was seen. Nothing else moves it.
- **A writer's lateness is silence, not a stall.** The hardware never
  waits: a period that comes due before its frames are written is
  played as silence where unwritten (an underrun, counted), and the
  writer resumes at the next period. Capture is the same in reverse: a
  reader that falls a buffer behind loses the oldest periods (an
  overrun, counted).
- **Devices whose queue takes buffers** (virtio-snd) are driven the same
  way: each period of the cyclic buffer is handed to the device in turn,
  a fixed number ahead, so the driver's model is one model for every
  device.
- **The audio service is lent the buffer** as a VMO mapped in both, and
  writes the device's frames there itself, reading the position from
  the device timeline (audio.md §11.2, still open). Until the service exists,
  `data` copies a plain write or read into the buffer behind or ahead
  of the position, one copy, the same as a pipe's.
- **The one ring carries clients' streams**, between a program and the
  audio service, where both ends have cursors: push streams and pull
  clients (audio.md §5.5).

## What it replaces

Nothing: it states where principle 6 stops. Without it, each driver
would choose between wrapping its DMA buffer in a ring header the
hardware can't read and copying from a ring into it every period.

## Consequences

- audio(3) states the class's model: the buffer's periods, the lead
  handed to the device, the underruns and overruns, and the stream that
  stops itself once it has drained.
- virtio-snd(3) is the first driver on it, and HDA's BDL (sky1-audio 02)
  is the same cyclic buffer with the position read from `SDnLPIB`.
