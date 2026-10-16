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
