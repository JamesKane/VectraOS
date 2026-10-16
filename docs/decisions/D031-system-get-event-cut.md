# D31. system_get_event is cut; the root account reports memory levels (2026-10-15, decided)

The tenth of V1's cuts (`docs/syscall-audit.md` §2): one call, 101 →
100.
- **system_get_event** (235) handed out five kernel event objects, one
  per memory level. Accounts already report their pressure through
  object_bind, so the system's levels became the root account's: one
  mechanism for memory pressure, a packet per change.
- **The root account** is made at boot and never freed. Userboot (and
  the Swift suites) get it as CROI_PA_ROOT_ACCOUNT, with no CHARGE right,
  so nothing charges it. Its level is the memory watchdog's, with two
  levels past CRITICAL (IMMINENT_OUT_OF_MEMORY, OUT_OF_MEMORY); its
  limit is the RAM and its charge the RAM in use. Its limit can't be set.
- **A PRESSURE binding reports the level at once** unless it is normal,
  on any account. An event was a level a new waiter saw at once; a
  binder must not wait for a change to learn it.
- **port_cancel removes a PRESSURE binding.** A binding left on the
  root account would keep its port alive forever.
- **Event objects go.** The kernel's self-tests signal counters.
- **Tests:** usertest.c's checks 615–619 moved to a Swift `memory`
  suite, which also checks the binding's first report and port_cancel.
- **Lost:** an account takes one PRESSURE binding at a time, so only
  one service hears the system's levels (Fuchsia let any holder of the
  root job wait on them). That service passes them on.
