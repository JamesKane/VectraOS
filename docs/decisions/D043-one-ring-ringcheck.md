# D43. The one ring: Ring.swift, ring.h, and RingCheck on both (2026-10-15, decided)

Roadmap V1 item 4: architecture §3's ring, in Swift and as a C23 header,
with a model checker. Doorbells are counters (D20's CHANGE binding).
- **One format, two implementations.** `lib/ring/ring.h` defines it and
  implements it for C-side drivers; `lib/ring/Ring` (Ring.swift,
  RingMemory.swift) is the Swift one, built into user programs as it
  stands (no Foundation, no ARC types) and into the host package. A host
  test (`RingTests.oneFormat`) pins every constant and the header bytes
  equal. The layout is §3's, with what it left open settled: each side's
  128-byte line holds its u64 cursor and, at +8, a u32 waiting word; the
  header at 256 is magic "VRNG", version 1, flags, slot size (a multiple
  of 8, up to 64 KiB), slot count (a power of two, up to 2^20) and the
  format descriptor (a u64 both sides agree on).
- **The protocol is NeoVectra's vx-ring's, both ways.** A side about to
  sleep sets its waiting word, fences (seq_cst), and looks again; the
  other side fences after moving its cursor and rings only if the word is
  set. So the consumer sleeps on an empty ring and the producer on a full
  one, and neither enters the kernel while both are busy. The calls are
  batch-first (principle 12): `space`/`ready` say how many, `publish`
  and `release` move the cursor by a count, and each says whether to
  ring the other side's doorbell. Shared memory is hostile: the header is
  validated once against what the side expects and used from a private
  copy, every slot is copied out exactly once, and a cursor that runs past
  the other's breaks the ring for good.
- **OVERWRITE is a header flag** (D38): the writer never waits, readers
  keep their cursors to themselves, and each slot starts with its u64
  sequence, all ones while it is written. A reader keeps a copy only if
  the sequence read its cursor before and after; anything else drops that
  one record, so a writer stopped halfway never holds a reader up.
- **RingCheck runs the real code** (the owner's choice over checking a
  hand-written model, as vx-check did). Ring is generic over
  `RingMemory`, and ring.h's atomics and slot copies are macros; the host
  check build sends both to the checker (`CheckedMemory`, and
  CROI_RING_CHECKED's hooks). Model threads run as coroutines (a small C
  shim over ucontext; Swift can't call makecontext), and every memory
  operation is a point where the checker chooses what happens next. It
  explores every order depth first, replaying each from the start, and
  prunes a state it has reached before. Its memory model lets stores
  reach memory out of order, as arm64 does, except where release orders
  and fences forbid it; loads are never reordered, so it can't show that
  an acquire, or the consumer's release (its copies before its cursor),
  is needed. Coroutine code runs without Swift's runtime exclusivity
  checks, whose record of accesses switching stacks would break.
- **What it checks, on both implementations alike:** the wakes (one and
  three entries through two slots, so that the producer waits too: about
  124,000 states for three), and OVERWRITE with a lapping writer (no
  torn record kept, in order, kept plus dropped equals written). Broken
  on purpose, each must fail: no producer fence, no consumer fence, a
  relaxed publish (the consumer reads a slot before its bytes land), no
  recheck, and a writer without its release orders (a torn record kept).
  The model tests take about 40 s in a debug build.
- **On the target:** a `ring` suite (two threads, a VMO, counters bound
  CHANGE as doorbells; refusals, 20,000 entries checked, a consumer asleep
  first woken), and m2's budgets from performance.md: `ring.per_1000_slots`
  (limit 10 µs: 100 M slots/s, 64-byte slots, across cores),
  `ring.round_trip` (submission and completion, both busy: limit 300 ns)
  and `ring.kicks` (doorbells rung, both busy: 0). KVM, one run: 6.3 µs,
  100 ns and 0.
- **Not yet:** the kernel produces no ring until item 5 (ports, D19; the
  debuglog, D38), and ring.h isn't on a target include path until a
  C-side driver uses it (V2). The byte-stream mode audit §4 mentions for
  pipes comes with them.
