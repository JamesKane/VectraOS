# D145. FDIO reads a file fs maps from its mapping, not through fs (2026-10-27, decided)

At matched clocks under KVM, `read_4k` (a 4 KiB `pread` of a cached
file) is 402 ns on Fuchsia and 615 on VectraOS
(`bench/peers/2026-10-26-fuchsia-kvm`, 2026-10-27). VectraOS's read is
a ring entry to fs and back; Fuchsia's never reaches Fxfs: `zx_stream_readv`
copies from the file's pager-backed VMO in the kernel.

D131 puts a file's bytes in a pager VMO that fs serves and clients map
(`File.map`, a REFERENCE child, and the volume's slot table), but leaves
FDIO's reads going to fs. The owner was asked how far the pager-backed
reads should go: D131's steps alone, those and FDIO reading through the
mapping, or those and a kernel stream object as Fuchsia's.

**The owner's choice (2026-10-27):** D131's steps 2 to 4, and FDIO reads
through the mapping: one mechanism, the one `FileCache` and the
`fs.read_4k` budget already use, and no new kernel object.

- A description reads from the file's mapping once it has a channel to
  the file (a read-write open, or a read-only one whose fid has been
  read twice beyond what its open brought) and fs has mapped the file
  for it (`map`, asked once; a server that doesn't map says so, and
  the description reads through it as before).
- A read copies between two even, equal readings of the file's slot
  (Mapped.swift): no message, no system call once the pages are
  resident; a page that isn't faults, and fs's pager thread supplies it.
- Before a read from the mapping, the description's own writes behind
  are finished (they go to fs on its ring, D103), so a process reads
  what it wrote through the same descriptor. Writes through another
  descriptor of the same file are seen once fs has them, as before.
- A slot marked gone or replaced, or bytes past what the description
  mapped (the file grew), map the file again once; if that fails, the
  read goes through fs.

**Not changed:** writes (on the ring, sent behind), `openAhead`'s first
bytes, and directories. Programs that map files themselves (tier 1's
`mmap`) are a later decision.

**Measured** (amd64 under KVM, the dev machine not held, guest
`cpu_mhz` 4,230): `read_4k` 86-88 ns, three runs (from 615 at matched
clocks; Fuchsia's 402).
