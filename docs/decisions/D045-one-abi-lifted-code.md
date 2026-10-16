# D45. One ABI: lifted code includes VectraOS's headers (2026-10-15, decided)

todhchai reaches croi through hardcoded syscall numbers: ten files hold
number tables or bare literals (the floor, Sys's native backend, the
pthread platform, the dynamic linker, the trace session, a test), with
packet, call-argument and vDSO layouts inlined in Swift. V1 kept several
calls' numbers while changing their arguments to arrays (handle_close,
vmar_map, vmar_unmap, vmar_protect, port_queue, port_wait, channel_read,
channel_write), so an old caller still builds and fails quietly: an old
`handle_close(h)` passes the handle as a pointer with a count of 0.
- **The headers are the one source.** Lifted code takes numbers, items
  and layouts from `user/include/croi` and `kernel/include` (the
  `CroiAbi` module for Swift, as user programs here already do). V2 deletes
  todhchai's number tables rather than updating them.
- **Each changed call's wrapper is rewritten, not patched.** Wrappers take
  arrays where the call does (principle 12), with one-item helpers as in
  syscall.h.
- **Rejected:** keeping todhchai's tables in step by hand (a second
  definition of the ABI, and this hazard again at the next change).
