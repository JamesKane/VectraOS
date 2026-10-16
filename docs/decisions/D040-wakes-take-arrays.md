# D40. The wakes take arrays: port_queue, port_wait, counter_add, interrupt_ack (2026-10-15, decided)

The second family of V1's batched forms (`docs/syscall-audit.md` §3,
roadmap V1 item 3). The count stays at 92: each array form replaces its
single form.
- **port_queue(port, packets, count)** (32) queues up to 64 user packets
  to one port, in order, and stops at the first that fails (SHOULD_WAIT
  when the port is full; the packets after it would fail too, and their
  order matters). It returns how many it queued, or the first packet's
  status if that one failed: a packet has no status of its own to write
  back (its `status` field is the receiver's payload). The packets are
  only read, so no writable precheck: an unreadable one stops the batch.
- **port_wait(port, deadline, packets, count, leeway)** (33) waits only
  while the port is empty, then takes up to `count` (64 at most) without
  waiting again, and returns how many. The leeway moves to the fifth
  argument. A packet popped but not copied out (an unmapped page past
  the precheck) ends the batch; it is lost, as one was before.
- **counter_add(items, count)** (161) and **interrupt_ack(items, count)**
  (142) take up to 64 `croi_counter_add_item_t` (counter.h: handle,
  status, int64 amount; 16 bytes) or `croi_interrupt_ack_item_t`
  (interrupt.h: handle, status; 8 bytes). They go on past an item that
  fails, as handle_close does (D33), not stop as object_bind and
  handle_duplicate do (D39): each item stands alone and leaves nothing
  half done, and a service ringing every client's doorbell should ring
  the rest when one client has gone. Each item's status is written back;
  the call returns how many succeeded. A bad pointer or count fails the
  call before any item (`Syscalls.eachItem`).
- **Callers:** syscall.h's `croi_port_queue`, `croi_port_wait`,
  `croi_counter_add` and `croi_interrupt_ack` are the one-item forms;
  usertest.c, the suites, m2 and userboot use them. m2's wake budgets
  match counter_add's trace records by their first argument, now the
  item's address, so the measured adds go through one static item.
- **Port batches are interim** (audit §3): ports become rings (D19, V1
  item 5), and then a wait drains the ring.
- **Tests:** the objects suite's `packetBatches`, the counters suite's
  `batch`, and a batch ack in the interrupts suite's state machine.
