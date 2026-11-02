# D159. The ring bench publishes and releases every 64 slots, and the one ring keeps its cursors (2026-11-02, decided by the owner; amends D43's bench)

D43's throughput bench (m2, `ring.per_1000_slots`) had each side take
every slot it could before letting go: the producer filled all the free
slots and published once, the consumer drained all the ready ones and
released once. On a 256-slot ring that is lockstep. The two sides went
in 782 batches of 256 over 200,000 slots on the Orange Pi RV2, each
waiting while the other worked, and PC samples put about 45% of each
side's time in its spin over the other's cursor. A slot then costs the
producer's line miss plus the consumer's, one after the other.

Measured (2026-11-02, the RV2 notebook's "The ring bench, prefetched
and profiled"), ns a slot, 64-byte slots across two cores:

| | lockstep | 64 a batch | FastForward |
|---|---|---|---|
| rv64, Orange Pi RV2 (VectraOS) | 261 | 131 | 80 |
| amd64, KVM (VectraOS) | 4.3 to 4.5 | 2.9 to 3.1 | 2.5 to 3.1 |
| arm64, Orange Pi 6 Plus A720s (FreeBSD, a C port) | 27 to 31 | 26 to 28 | 60 to 63 |

FastForward (Giacomoni et al., PPoPP 2008: no shared cursors, each
slot's first word its flag) was the only other candidate that did
better anywhere; its round trip was 380 ns against 917 on rv64, 346 to
396 against 372 to 419 on arm64, the same on amd64. Prefetching (Zicbop)
and pushing slots out with Zicbom made the RV2 slower.

## The decision

1. **The bench's producer publishes, and its consumer releases, every
   64 slots** (`Bench.ringBatch`), not once per fill or drain. The
   limit (10 µs per 1000 slots) is unchanged; the bench now measures a
   ring whose two sides overlap, as a busy service's do.
2. **The one ring keeps its format and protocol** (D43). FastForward's
   throughput is a half to a quarter of the ring's on arm64, and a
   format must serve every arch; the owner took the one that is better
   overall.

## Consequences

- The RV2's native suite with this bench (2026-11-02): 128,239 ns per
  1000 slots (from about 262,000), a round trip 931 ns, no doorbell rung.
- The RV2 stays over both limits: about 131 ns a slot and 917 ns a
  round trip, each the X60's cross-hart line transfers (about 130 ns
  one way, with no overlap between them); no software change measured
  came near them. Accepting them as the board's is still open.
- amd64's recorded history for `ring.per_1000_slots` steps down about a
  third from this commit; `vx bench --record` takes it on a quiet machine.
- A consumer that drains a long run of slots before releasing any (or a
  producer that fills one before publishing) is in lockstep with the
  other side; a bulk user should let go as it goes.
