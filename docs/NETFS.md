# The ring 3 network stack

`servers/netfs` is the IPv4 and TCP stack, in ring 3, serving `/net`. The card
is the kernel's, as `#E` at `/dev/ether`. Everything above it is here: ARP,
IPv4, ICMP, UDP and TCP over `sys/libnet`'s wire formats, and the `/net` files a
program reads. `docs/FLEET.md` step 0 is the plan it grows under, and
`cmd/netecho` with `sys/libnet`'s `dial` are what cross a line over it.

Much of the stack was brought in line with 9front's, read side by side. The ARP
hold, the retransmit, the synchronous connect, the listener close, the
conversation reclaim, and the flow control each match that stack. This document
records what does not yet, so a later session finds it rather than the code
alone.

## Deferred work

Each item names what is here, what 9front does instead, and what it waits on.

### Wants a real clock

`docs/DEVTOOLS.md` step 1 gives `/dev/time`. Three things wait for it, because a
round of the ether thread's loop is the only clock the stack has now.

- **Retransmit backoff.** A segment is sent again after a fixed count of
  rounds. 9front measures the round trip and doubles the wait each try, bounded.
  Without a clock the timer is coarse, and it cannot tell a slow link from a
  lost segment.
- **`Time_Wait`.** A closed conversation has no timer to leave `Time_Wait` on,
  so it rests there until a new `clone` reclaims its slot. A real close waits
  two segment lifetimes and then frees itself.
- **A conversation abandoned mid-close.** One left in `Fin_Wait` or `Close_Wait`
  with no descriptor is reclaimed only once it reaches `Closed` or `Time_Wait`.
  A timer would reap it on its own, as a crash leaves it hanging otherwise.

### Efficiency, not correctness

The stack is correct without these. Each is a round trip or a packet it could
save.

- **Fast retransmit.** Three duplicate acknowledgements mean a segment was
  lost, and 9front sends it again at once. Here the retransmit timer is what
  notices, which is slower.
- **Delayed acknowledgement.** Every segment with data draws an
  acknowledgement of its own. One acknowledgement for two segments, on a short
  timer, would halve the traffic back.
- **Nagle.** A write goes on the wire as its own segment. Holding a small write
  briefly, for the bytes behind it, would fill segments better on a slow
  stream.
- **Silly window avoidance.** A read reopens the window by whatever it freed,
  down to one byte. 9front holds the reopening back until it is worth a
  segment, so a slow reader does not draw a run of tiny ones.

### Not yet built

- **Congestion control.** `docs/FLEET.md` step 0 wants it. There is no
  congestion window and no slow start, so the stack sends as fast as the far
  end's window allows and no slower.
- **A send buffer.** A write is sent from the caller's bytes, and a write the
  window stops is held or answered short. A buffer would take the whole write
  and drain it as room opened, so a caller never waited.
- **Partial overlap on receive.** A segment that starts before the stream and
  carries new bytes past it is dropped whole, and the far side sends it again.
  9front trims the old front and keeps the new tail.
- **UDP conversation reclaim.** A TCP conversation's slot is reclaimed when it
  is finished and unreferenced. A UDP conversation has no finished state to key
  that on, so its slot is not yet reclaimed the same way.

### The rest of step 0

`docs/FLEET.md` step 0 is more than this stack. The bench crosses a line
between two machines by name, but both are amd64. The boot line wants two
architectures. `cmd/ipconfig`, `servers/dns` and `servers/etherfs` are named in
the plan and not yet written.

## See also

- `docs/FLEET.md` -- the plan this stack grows under, step 0.
- `docs/TRANSPORT.md` -- `kernel/mnt`, the client a mounted `/net` reads
  through, and where an interrupted read keeps a reply that raced its flush.
- `docs/VECTRA9.md` -- the 9P dialect the files are served over.
- `docs/DEVTOOLS.md` -- the `/dev/time` that three of these wait for.
