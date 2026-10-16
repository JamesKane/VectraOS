# D44. Ports as rings: CROI_PORT_RING (2026-10-15, decided)

Roadmap V1 item 5, D19's half. A thread drains its port's packets from
the one ring with no syscall, and calls port_wait only when the ring is
empty. The owner's choices, of three questions D19 left open:
- **A ring on request.** `port_create(CROI_PORT_RING, uint32_t out[2])`
  writes the port's handle and its ring VMO's (READ, WRITE, MAP and
  GET_PROPERTY: the reader's cursor is in it). Other ports are as they
  were, so a port made for one sleep doesn't cost a page. The ring is
  one page: 64 slots of `croi_port_packet_t` (48 bytes), format "PORT",
  no flags; the kernel is its producer, the reader its consumer. Rejected:
  a ring on every port (a page and a pin for each, most never mapped).
- **The port's queue is the overflow.** A packet goes into the ring when
  it is queued, if the ring has room; otherwise it waits in the port and
  goes in, in order, at the next packet or port_wait. So coalescing,
  port_cancel and an enqueue that never fails (packets preallocated per
  binding) all keep working on what isn't delivered yet; a delivered
  packet is the reader's, and port_cancel no longer reaches it.
  Interrupts' packets go first, as they are read first now. Rejected: the
  ring as the only queue (a full ring would drop or refuse packets, and
  coalescing would stop at the ring).
- **port_wait only waits.** `port_wait(port, deadline, nullptr, 0,
  leeway)` delivers what fits and returns 0 once the ring isn't empty
  (TIMED_OUT at the deadline, BAD_STATE once the reader has broken the
  ring). A ring port refuses a count, and any other port a count of 0,
  so each ring has one consumer. No doorbell counter: the kernel is the
  producer, and port_wait is the sleep (§3's waiting word is unused).
  Rejected: port_wait copying packets out and moving the reader's
  cursor (two consumers of one SPSC ring).
- **The kernel side.** The ring is a pinned page of a contiguous VMO,
  written through the physmap: pinned, the reader can't decommit it (its
  page would be lent while the kernel writes it) or change its cache
  policy. The kernel writes with Ring.swift under the packets lock, and
  hands delivered records back to their sources once that lock drops, in
  batches of eight. Under the scheduler lock (kernel sources firing
  there) a packet only queues; port_wait or the next packet delivers it.
  The reader's cursor is hostile: one past the kernel's breaks the ring
  for good, and its packets stay queued until the port goes.
- **Tests:** the `portring` suite: refusals (a count on a ring port, 0
  on another, decommitting the page, unknown options); packets in the
  ring at once, in order, with no syscall; a hundred packets through 64
  slots, the rest delivered by port_wait, in order; a CHANGE binding's
  packet per add while there is room, and one packet for three adds
  while the ring is full; a reader asleep woken by another thread's
  packet; a broken ring refused. The interrupt suite's option check moved
  to bit 2.
- **Not yet:** a budget. m2's `ring.kicks` measures user rings; a ring
  port's drain under load (the exit's `ring_kicks = 0`) gets a budget
  with its first user, todhchai's services at V2. Bindings stay a
  syscall each (D20), and channels keep their own queue.
