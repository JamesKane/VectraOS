# D137. The wire format has no cancel or epitaph until something sends one (2026-10-25, decided; amends D6)

The wire format (D6, wire(6)) defines five message kinds. Two have never
been sent: a **cancel** (a client abandoning one call, answered by the
call's reply or a reply with `canceled` set, as 9P's flush) and an
**epitaph** (a status written before a channel closes). `IPCWire` encodes
and decodes both (`system/ipc/wire/Control.swift`), and the header has
the `canceled` flag, but no client cancels, no server answers a cancel,
and no service writes an epitaph: a call ends with its reply or its
channel's closing, and a peer that goes is seen as `peerClosed`. An
unused part of the one wire format still has to be kept right in Swift,
C (`td_wire.h`) and the manual.

- **Cancel and epitaph go:** their message kinds, the `canceled` flag,
  `Control.swift`'s encoders and decoders, their tests, and wire(6)'s
  section on them. Their kind values (4 and 5) and the flag's bit stay
  reserved, so a receiver rejects them as it rejects any unknown kind.
- **A call ends with its reply or its channel.** A client that no longer
  wants a reply drops it, or closes the channel.
- **They come back with their first sender,** as specified in wire(6)
  today: the flush rule (exactly one of the normal reply or a canceled
  one, never both, never neither) is the one to bring back.
  `docs/architecture.md`'s line on Tflush says so instead of describing
  them as present.

Rejected: keeping them for completeness (principle 1: a mechanism with
no job is still kept right); a timeout-driven cancel in its place (D135
rejected deadlines on calls for the same reasons).

Covers: system/ipc/wire (Control.swift, the header's kinds and flags),
system/ipc/c/include/td_wire.h, idlc's C output, the IPC tests, man/6/wire,
docs/architecture.md. About 100 lines. Tests: the IPC and IDL host tests,
and boot-ipc.
