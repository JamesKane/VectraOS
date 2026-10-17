# The pty service

Pseudo-terminals for terminals and rc, on the one ring (D46).

`bin/pty` (`services/pty`, in every arch's bootfs, its manifest
`pty.manifest`) serves `PtyIPC.Factory` at `/svc/pty/pty` (idlc's outputs
in `services/pty/idl`). A terminal opens a pty and gets its side: its keys
(a descriptor it writes) and screen (one it reads), and `Device`, to set
the window's size and make the client end, once. The client end is a
program's descriptors 0 to 2, each the child side of a ring the pty is
the other side of (Sys's `StreamParts`: a starter adds them to a Startup
as they are), and `Control`: the mode, the window's size, and the events
the keys make (`interrupt`, `quit`, and `end` for a controller that takes
ends with `takeEnds`; otherwise ^D on an empty line ends the program's
stdin), and `hangup` when the terminal goes (its keys end; version 2).
rc on a pty takes them as notes: `sigint`, `sigquit`, `sighup`. A ring
has one writer, so a pty has one client: a shell on it relays to its
programs (rc does, `shell/rc/native/Terminal.swift`).

The line discipline (`lib/LineDiscipline.swift`, lifted from todhchai as
it was, tested alone by PtyTests): canonical mode with echo, erase by
UTF-8 character, ^U, ^W, ^C, ^\, ^D, CR as NL; raw mode; output's NL as
CR NL. The server (`lib/Server.swift`) runs a thread for each ring it
reads, its IPC on the dispatcher's. launch-test (boot-launch) types to a
pty as its terminal and program both, and, where tier 1 is built, to rc
on one.

## Temporary: the pty goes for Plan 9's way

The pty is a stopgap, lifted so rc had a terminal in V2. Its line
discipline is Unix's tty (termios's cooked and raw modes, kept in a
service between the terminal and the program), and we mean to eject it
for Plan 9's approach, as rio does it:
- **The window is the terminal.** Whatever shows a program's text (a
  rio window in Radharc, V5, D75; before then the console, and a
  cpu session's terminal, D77) is the other side of the program's fds 0 to 2 itself, with
  no pty between them, and serves `/dev/cons` and `/dev/consctl` in the
  program's namespace, as rio serves each window's.
- **Editing is the window's.** Text is edited in the window, anywhere
  before the last newline, and a line goes to the program when it is
  sent; `rawon` and `rawoff` written to `/dev/consctl` take the place of
  raw and cooked modes. No line discipline, no termios state, no CR NL
  translation in a service.
- **Interrupts are notes.** The window posts `interrupt` to its
  programs, as rio does on DEL, in place of the pty's Control events.
  This waits for notes between processes, which croi doesn't have yet.

What goes with it: `services/pty` (its line discipline, server and IDL),
rc's relay of the terminal to its foreground program
(`shell/rc/native/Terminal.swift`), and `CROI_PA_PTY_CONTROL`. Remote sessions
have no pty either: Plan 9's cpu imports the terminal's `/dev/cons`, from
the dev machine's `vx cpu` in V3 and between our nodes (D75, D77). The rings
stay (D46): fds 0 to 2 are still byte rings, with the window on the
other end. Open: how tier 1's POSIX programs that ask for termios or
`isatty` see a window (the libc mapping them onto `/dev/consctl`, as
Plan 9's APE does, is the likely answer). When: V3 (D77), once cpu's
session and the console serve `/dev/cons`; until then, don't build new
things on the pty's Control or its modes.
