# D61. The Venus ring is an exception to the one ring (2026-10-16, proposed)

The Venus client driver sends through a ring in shared memory whose
layout (Mesa's, in todhchai's `td_venus_ring.h`) is fixed by the protocol
the host's renderer speaks. Principle 6 allows one ring format.
- **It is allowed as an external protocol,** as virtqueues are: it lives
  only inside the Venus driver, and nothing else in the tree may use it.
- **Our own GPU system drivers' submit rings are the one ring** (D43),
  with counters as doorbells (D46).
