# D94. A write to a full stream waits, as a read of an empty one does (2026-10-17, decided; extends D84 and D93)

D84 holds a read of a stream until the stream has bytes, and D93 does
the same for a read through the ring. A write is still answered at
once, with what the stream took. The network stack's conversations
(`/net/tcp/N/data`, D79) are streams whose writes can find TCP's send
buffer full. A writer then got a short count, or none, and had nothing
to wait on but a timer: the polling D84 rejected for reads. The owner's
direction (2026-10-17): the write is held.

- **A stream's write may say "not now"**: its closure returns nil when
  it can take none of the bytes, and the server holds the call, or the
  ring's entry, with its bytes. When the stream says it is `ready`, the
  held writes are tried again in the order they came. Each is answered
  with what the stream took then, which may be less than all; the
  client writes the rest as it would after any short write.
- **One `ready` for both directions.** A stream that frees room calls
  `ready` as one that gains bytes does; the session tries its held
  reads and its held writes, each in order, and neither waits behind
  the other.
- **Writes behind a held write wait behind it**, on a channel's calls
  and on its ring alike: a stream's bytes go in order. Held entries on a
  ring, reads and writes together, are bounded by its SQ's slots.
- **Files, text leaves and writes later in a batch** are answered at
  once, as for reads; a stream's write there that can take nothing
  answers 0.
- One mechanism still: D84's held call, now for both directions.

Rejected: short writes the client retries on a timer (polling), and a
service queue past the stream's own buffer (memory without a bound, or a
bound at which writes fail instead of waiting).
