# D30. thread_raise_exception is cut (2026-10-15, decided)

The ninth of V1's cuts (`docs/syscall-audit.md` §2): one call, 102 →
101.
- **thread_raise_exception** (236) offered ZX_EXCP_USER to every job
  debugger up the tree. Nothing raises one: Fuchsia's use is its process
  name change notice, and VectraOS has no debugger yet. One comes back
  with the debugger that needs it.
- **Job debuggers stay.** They still see PROCESS_STARTING, and walking
  their list still prunes closed channels.
- **Tests:** usertest.c's `user_exceptions` (623–627) tested the call
  itself and went. It was also the only test that delivered to a job
  debugger, so the objects suite gained one: two job debuggers see a new
  process's PROCESS_STARTING in turn, then no longer count once closed.
  Suites now get the root job as a startup handle (PA_JOB_DEFAULT).
- **Lost:** a program can't tell a job debugger something on its own.
