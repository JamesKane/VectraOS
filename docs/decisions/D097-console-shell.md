# D97. The console's shell is rc on kbdfs's /dev/cons, in kbdfs's note group (2026-10-17, decided; extends D77, D83, D87)

D77 removes the pty in V3, "with cpu's session serving `/dev/cons` and
the console serving it too". V2 gave kbdfs `/dev/cons` (D83) and the
console its screen, but nothing joined them: no rc ran on the console,
cons's writes and echo went to the debuglog and reached the screen only
as log records, and Delete flushed the line without interrupting
anything. This is the console's half of D77's condition.

- **rc opens /dev/cons itself.** A `shell` service runs rc with no
  stdio; rc, finding none and a `/dev/cons` in its namespace, opens it
  as its terminal, as Plan 9's init opens `#c/cons`. Its fds 1 and 2
  write `/dev/cons`. No relay process sits between rc and kbdfs.
- **The terminal is lent as on a pty.** rc reads `/dev/cons` from one
  thread and gives what comes to the program that has its stdin (rc's
  Terminal), so a foreground program's ring is fed without a second
  reader of cons. A read of nothing is ^D: the end of that program's
  input, or of rc's. The pty's Control goes with the pty; this path
  stays.
- **kbdfs's writes and echo go to the console's `write`**, mounted at
  `/mnt/console` in kbdfs's namespace; the debuglog only while there is
  none. The console's backspace erases, as Plan 9's screen does.
- **Delete interrupts kbdfs's own note group**, as 9front's kbdfs does
  (`procopen(getpid(), "notepg")`): kbdfs writes `interrupt` to its
  `/proc/N/notepg`, takes its notes, and ignores that one. 9front's
  boot puts the console's rc in kbdfs's group; the launcher gives each
  service a job of its own, so a manifest directive does it here:
  **`notegroup SERVICE`** makes the service's job under that service's
  (which starts first). The shell says `notegroup kbdfs`. The launcher's
  memory lines count a service in another's group once, as itself.

The owner chose the note group (2026-10-17). Not chosen: kbdfs starting
the shell itself (bootrc's role folded into the keyboard service, which
would then need rc's whole namespace), and rc telling kbdfs its group
through a `consctl` command that Plan 9's consctl doesn't take.
