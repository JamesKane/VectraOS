# D72. A process says why it ended: an exit string on a status page, Plan 9's exits (2026-10-16, decided)

Plan 9's processes end with a string (`exits("errors")`), and rc's
`$status` for a program is its wait message, `ls 1234: errors`: the
program's name, its pid, and why. croi's processes end with a number
alone (Zircon's return code), so rc made `1` of every failure, and
9front's commands, whose statuses are their words (`usage`, `errors`,
`can't open f: ...`), couldn't say them.
- **A status page (`CROI_PA_VMO_STATUS`, 0xF6):** a parent that wants
  its child's exit string gives it a VMO in its Startup. One message per
  process, written once, as it ends, with no IPC at exit.
- **The child's side is the floor's `td_exits(message)` (td_floor.h):**
  the message, NUL-terminated and cut to Plan 9's ERRMAX (128 bytes with
  its NUL), written to the page if there is one; then `td_exit` with 0 for
  none, a number below 256 as itself (so a code still says it to a parent
  that reads codes alone, as the launcher does), and any other 1.
- **The parent's side is Sys's `ExitString(for: startup)`**, which makes
  the page and gives it, and whose `read()` gives the message once the
  child has ended ("" if it said none).
- **rc gives every program one, and makes `$status` Plan 9's wait
  message:** `name koid: why`, why the exit string, or a program's code if
  it said none (`killed` for one killed), "" if it succeeded. rc ends with
  its own status as its exit string, so an rc it runs reports it upward
  (`rc 5678: ls 1234: errors`), as on Plan 9. The shell's commands end
  with 9front's strings.
- **Rejected:** a message over stdio's rings at exit (stdio would carry
  something that isn't a stream, and a process with no stdio couldn't
  say why); numbers only, with rc formatting them (`ls 1234: 1`: Plan 9's
  shape without its words).
