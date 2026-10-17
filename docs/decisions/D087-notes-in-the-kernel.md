# D87. Notes are a queue on the process, posted and taken as a property; untaken, a note kills (2026-10-17, decided)

D79 puts notes behind `/proc/N/note`, with the kernel's side a right on
a process handle and no new syscall. Plan 9 delivers a note on the
process's own stack, interrupting what it does; Zircon has nothing like
it (signals on a task carry no text, and exceptions are synchronous).
What the kernel keeps, and what acts on a note in a process that never
asked for one, needed choosing.

- **The kernel keeps a queue on the process:** five notes (Plan 9's
  NNOTE) of up to 127 bytes (ERRMAX less its NUL), oldest first, with
  `CROI_SIGNAL_PROCESS_NOTE` asserted while any wait.
- **Posted and taken as a property:** `object_set_property(process,
  CROI_PROP_NOTE, text, size)` posts, and needs `CROI_RIGHT_NOTE`, which
  a process's creator's handle has (the proc service's, by the jobs it
  holds). `object_get_property(itself, CROI_PROP_NOTE)` takes the next.
  A full queue refuses with SHOULD_WAIT. No syscall is added; the
  ceiling holds at 91.
- **A process asks for its notes** (`CROI_PROP_NOTIFY` on its own
  handle, Plan 9's notify). Sys's `Note.notify` sets it and starts a
  thread that waits on the signal and runs the handler; a handler that
  declines ends the process with the note as its exit string, Plan 9's
  NDFLT.
- **One that didn't ask dies of the first**, killed by the kernel with
  `CROI_TASK_RETCODE_NOTE_KILL`, as Plan 9's default action is. The note
  stays on the process, read from its handle once it has ended, so a
  parent can say what it died of. Nothing runs in such a process for
  notes, so spawn to main pays nothing (the floor starts no thread).
- **A blocked call isn't interrupted.** Plan 9 ends the syscall with
  "interrupted"; here the handler runs beside it. ^C reaches the whole
  foreground note group, so rc's wait for its program returns when the
  program dies. Interrupting every blocking path in the kernel would be
  a larger change, left until something needs it.

Rejected: notes outside the kernel (a channel from each parent), which
the proc service couldn't reach for processes it didn't start; and a
note thread in every process, which costs every spawn.
