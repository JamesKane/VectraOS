# D181. An audio device's clock is a counter, as D27 made the display's: the driver adds one for each period played or recorded, and lends the stream's buffer and that counter to one lessee through a typed `lease` node; there is no device timeline object (2026-11-26, decided by the owner; settles audio.md §11.2, after D27 and D180)

audio.md §6.1 proposed generalising the display timeline (K10b) into a
device timeline for audio clocks. That object no longer exists: D27 cut
the display timelines in V1, because a counter the driver's interrupt
thread adds to does the same job, lends a deadline to the thread it
wakes (`Profile.lend`), and leaves the time to the consumer. A second
clock object for audio would bring back what D27 removed (principle 1).

## The decision

- **The clock is a counter.** For a stream lent to a lessee, the class
  adds 1 to a counter each time the device finishes a period. The
  counter's value is the number of periods finished since the lease
  began, so period `k` of the lease is the buffer's slot `k mod
  periods`. The lessee waits on the counter, and the time is its own
  clock's when it wakes, as Radharc's is for vblanks.
- **The deadline rides on the counter.** The lessee's mixing thread
  runs on an admitted deadline profile (`Profile.deadline`, under the
  system resource) and the counter lends it at each wake
  (`Profile.lend`), as K10c designed.
- **The lease is a typed node.** Node files carry bytes and, for
  `memory`, a VMO, but not a counter. Each audio(3) directory therefore
  serves `lease`, a `vectraos.audio.lease` protocol node (like the display
  class's `display`), whose one call lends the playback stream: its
  buffer's VMO, the counter and the layout. The lease lasts while its
  channel is open; when the channel closes the stream stops.
- **A lent stream is the lessee's.** It runs without a break from the
  lease to its end. The class hands periods to the device `lead` ahead
  as before, but it writes nothing into the buffer, never drains and
  never stops by itself. The lessee writes each period before the class
  hands it. While a stream is lent, `data` and the format lines of `ctl`
  are refused.
- **The audio service is the lessee** (D179). Clients never lease: they
  push streams to the service.

## What it replaces

The device timeline object of audio.md §6.1 and §11.2, never built. In
D180, "reading the position from the device timeline" becomes "waiting
on the device's counter".

## Consequences

- No kernel work: counters, deadline profiles and their lending exist.
- The service's latency is the class's `lead` plus the periods it writes
  ahead, a few quanta; audio(4) states it.
- Capture is lent the same way when a client needs it, the counter
  counting periods recorded.
