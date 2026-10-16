# D28. The bring-up calls are cut: debug_write and vmo_map (2026-10-15, decided)

The seventh of V1's cuts (`docs/syscall-audit.md` §2): two calls,
107 → 105. Both were scaffolding from before the mechanism that replaced
them.
- **debug_write** (1) printed a user string on the kernel console, from
  K6, before debuglogs (K8a). `debuglog_write` is the one way to log.
  Every program the kernel or userboot starts gets a debuglog as fd 1;
  the runtime's stdout drops its output without one.
- **vmo_map** (43) mapped a VMO into the calling thread's address space
  "until VMARs (K7)". `vmar_map` is the one way to map. usertest.c's
  process modes map stacks in their root VMAR (`map_stack`). Its child
  processes have no VMAR handle, so `make_child` maps a region of five
  stacks and `child_thread` takes one by index.
- **The boot's assembly user test** (`usertest.S`) used debug_write, and
  still used the clock syscall D26 cut, so since D26 it had printed
  "null syscall 0 ns". It now checks only that registers survive 1000
  null syscalls. m2's `syscall.null` budget times them.
- **Tests:** mode 0's size and mapping checks (169, 181, 20–22) moved to
  the vmo suite. Check 25, debug_write's bad pointer, went; the vmo_read
  and vmo_write bad-pointer checks stay until those calls are cut.
- **Lost:** a program with no debuglog can't print. The kernel and
  userboot always hand one over.
