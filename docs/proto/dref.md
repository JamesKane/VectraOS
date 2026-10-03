# 9Px extension `dref`

Status: draft, M5 step 5d. Frozen when M5 lands (02 §3.3).

Data by reference (02 §3.3): a read or write whose bytes are in a VMO of the client's, its `Buffer`, not in the message. One message moves any amount, whatever the msize, and the client's bytes are copied once, by the server, between the file and its VMO. A connection asks for it in `Tversion` (`9P2000.x/1 +dref`); `fsd` has it, and no other server yet.

## The client code that uses it

vx-9p's ring client (`p9c_readref`, `p9c_writeref` in `lib/vx-9p/ring.c`), for native programs with a `Buffer`. POSIX's `read` and `write` stay `Tread` and `Twrite`: their buffer is no VMO.

## Messages

| Message | Fields |
|---|---|
| `Treadref` 160 / `Rreadref` 161 | `fid[4] offset[8] count[4] roffset[8]` / `count[4]` |
| `Twriteref` 162 / `Rwriteref` 163 | `fid[4] offset[8] count[4] roffset[8]` / `count[4]` |

- **The VMO** comes beside the request: on the ring transport, in one of the ring's handle slots (`ring_xfer_handles`), which the submission names (`VX_SQE_HANDLES`, `handle_slot`; lib/vx-9p/ring.c). The client sends a duplicate and keeps its own; the server closes what it was sent once it has answered. `Treadref` needs it writable, `Twriteref` readable.
- **`roffset`** is where in the VMO the data goes, or comes from; `count` bytes of it, which must lie within the VMO.
- **The rest is `Tread`'s and `Twrite`'s:** the fid must be open, and not a directory, for reading or for writing as the message does; `offset` `P9_OFFSET_CURRENT` uses and moves the open file's offset (docs/proto/posix.md), and a write to a file that appends goes to its end.
- **Short counts.** A read past the end of the file answers what there was, or 0. A failure part way through answers what was done, if anything was; otherwise its error.

## Semantics

- **How the server copies.** `fsd` copies between the volume and the client's VMO through a buffer of its own (`vmo_rw`), a chunk at a time, rather than mapping the VMO. A client could hand it a VMO of `fsd`'s own page cache (docs/proto/map.md), and `fsd` mapping that would fault to itself; `vmo_rw` refuses pages not there instead, and the request fails.
- **Coherence** is `Tread`'s and `Twrite`'s: a read of a mapped file sees what its mappings wrote, and a write reaches them (docs/11 §8).
- **Other regions.** 02 §3.3's other kinds of region (the bytes after the message on TCP, an RDMA key) come with those transports.
