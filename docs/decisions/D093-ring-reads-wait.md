# D93. A ring read of a stream waits, as a plain read does (2026-10-17, decided; amends D67, extends D84)

D84 lets a plain Node read of a stream wait until it has bytes. D67's
ring answers every SQ entry at once, so a read of a stream through the
ring returns nothing when nothing is there, and a channel's own stream
(`NodeStream(perChannel:)`) reads nothing at all through it. The net
class's `data` (ether(3)) and the network stack's conversations are
streams whose readers move many frames, the ring's case. The owner's
direction (2026-10-17): ring reads wait too.

- **A read entry on a stream with nothing there is held,** not
  answered: the server takes it from the SQ and keeps it, and when the
  stream says it is `ready`, it answers the held reads in the order they
  came, each with what the stream gives, as many as the CQ has room for.
  An empty answer means the stream ended, as for a plain read.
- **Completions may come out of order.** A held read's CQ entry follows
  later entries' (a write behind it is answered at once); the tag, as
  ever, says which entry it answers. Clients match by tag already.
- **A channel's own stream reads through its ring** with that channel's
  `take`, as a plain read on the channel does.
- **Held reads are bounded by the SQ**: a client holds at most as many as
  it has slots, and they go with the ring when its channel closes.
- **Files and text leaves still answer at once**; only streams wait.
- One mechanism still: the held read is D84's, met from the ring
  instead of a call.

Rejected: a ring read that polls (the reader spins or sleeps on a timer,
D84's reason for waiting at all), and a separate notification ring for
"a frame came" (a second mechanism for what the held read already says).
