# D19. Ports become rings (2026-10-15, decided)

The kernel writes port packets into a mapped ring in the one format
(architecture §3), with the consumer cursor in user memory. A thread
drains pending events with no syscall and calls `port_wait` only when the
ring is empty. This is done in V1 after the cuts and `object_bind`, so
that it is built on the reduced set of event sources. D44 settles how: a ring
on request, the port's queue as its overflow, and port_wait as the
reader's sleep.
