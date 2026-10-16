# D46. Byte streams on the one ring (2026-10-15, decided; amended 2026-10-16)

V1 cut sockets (D21). todhchai uses them for every byte stream: the
floor's stdio (fds 0–2), rc's `pipe()` and its relays for files and
backquotes, and the pty (two per pty). A socket has properties the ring
lacks: several writers (rc and its children share fds 0–2), an end of
input (`set_disposition` write-disabled), and peer death as a signal.
- **The ring's byte-stream mode** (audit §4, D43's "not yet"): a header
  flag, slots carrying a length and bytes, so a writer may put any amount
  and a reader take any amount. RingCheck covers it like the other modes.
- **One writer per ring.** A child gets rings of its own; whoever shares
  a terminal (rc, the pty) relays. stdio is a ring pair the floor maps at
  start, handed over in processargs instead of socket handles.
- **End of input is an end mark** in the stream (a flag on the last slot),
  so EOF is ordered with the data. **Peer death** comes from a channel
  that travels with the rings: its PEER_CLOSED, bound to the reader's
  port, as for every other object.
- **Doorbells are counters** (D43), bound CHANGE to the sleeper's port.
- **Flow control is ring fullness.** The pty's `set_disposition` and its
  WRITABLE watches go.
- **Rejected:** a multi-producer ring (a second protocol to check), and
  bringing sockets back (D21).

**A ring per descriptor (2026-10-16).** A child got one ring pair: stdin,
and stdout with stderr in it, so a program's fd 2 couldn't be told from
its fd 1 and fds above 2 couldn't be given at all (rc dropped them, and
`<{}` had no way to reach a program). Each descriptor a parent gives is
now one ring of its own, one way, in a VMO of its own with its doorbells
and channel: CROI_PA_STDIO's argument carries the fd and the part
(`td_stdio.h`: `td_stdio_arg`, up to 16 descriptors below 64). stderr is
fd 2's ring when given, stdout's otherwise; Sys's ChildStdio gives fds 0
and 1 unless asked for more, so a parent that drains only stdout can't
stall a child on a full stderr. FDIO reads and writes inherited rings by
their numbers, keeps its own files off them, and opens `/dev/fd/N` as
descriptor N; rc gives a child every descriptor its table has and relays
each one. Chosen over passing a file as its own node (Fuchsia's PA_FD):
that is a second kind of inherited descriptor, and tier 0 programs know
only rings.
