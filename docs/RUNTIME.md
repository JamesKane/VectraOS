# The userland runtime: Odin in ring 3

`sys/abi/`, `sys/libuser/`, `servers/ramfs/`, `servers/consrv/`,
`servers/kbdfs/`, the `VECTRA02` format, and the user half of `build.odin`.

Milestone 16. Every program before it was a page of assembler, because a page
was all the loader could carry. This milestone is the runtime that ends that.
Programs are written in Odin, compiled and linked by the build driver, and
loaded by segments with real permissions. What they link against is the same
library shape the kernel's own servers use. `servers/ramfs` is the proof, and `servers/` is empty no
more.

The chain, end to end:

    odin build ──▶ ld.lld ──▶ elf_to_image ──▶ /bin/ramfs ──▶ load_v2 ──▶ ring 3
    (servers/ramfs)  (link_user.ld)  (build.odin)   (#load, #b)   (segments)

## `sys/abi`: the numbers both sides include

Until this package, the call numbers lived in `kernel/user/syscall.odin` and
every program wrote them again as immediates -- the honest arrangement while
every program was assembler, which cannot share a constant with Odin. An
Odin program ends the excuse. The kernel's dispatcher and `sys/libuser` now
read the same constants from `sys/abi`, so the two sides of a system call
cannot drift. The blobs still carry immediates, with the old defence: the
checks fail loudly when a number moves.

What belongs there is exactly what crosses the door -- numbers, flag words,
answer packings -- and nothing that behaves. The package imports nothing.

## `sys/libuser`: the door's other side, and a serve loop

`sys.odin` is one wrapper per call and the two loop helpers every byte-moving
caller needs. The wrappers are `contextless`, allocate nothing, and interpret
nothing: the answer is the kernel's signed number, untranslated. The asm
constraints say what the door promises, which is that `rax`, `rcx` and `r11`
change and nothing else does. `probe` checks that promise from ring 3 on
every boot.

`serve.odin` is what `/bin/niner` bought. `post` is Plan 9's arc as one call:
pipe, create, write the digits, close both spent descriptors. `serve` is the
frame loop: read a request, decode it, hand it to a handler, encode the
answer, write it back. **The handler is a `vectra9.Handler`**, the same
signature every kernel server implements. A handler therefore cannot tell
whether it answers from ring 0 behind a transport or from ring 3 behind a
pipe. That is the claim `sys/vectra9` opens with, now true across the
privilege boundary.

A server stops two ways, and the result says which. One is a `Tremove`
answered and then obeyed, which is `niner`'s rule kept. The other is a pipe
that ended.

## `serve_mux`: a worker per request that parks

`serve` answers one request at a time, so a read that parks holds every
other client behind it. That was `consrv`'s wart for two milestones: a read
of `/line` had to answer empty rather than wait, because waiting would freeze
the loop. `serve_mux` is the fix, and it is Plan 9's shape -- a process per
blocking request.

The caller supplies one thing the loop cannot know: a `blocks` predicate,
true for a request that might park. The loop reads a request. If `blocks`
says so, it copies the request into a free worker slot and forks a worker to
own it -- `RFPROC | RFMEM | RFNOWAIT`. The main loop reads the next request at
once. A request that does not park is answered inline, exactly as `serve`
does, and a pool with no free slot answers inline too. That bounds the
workers the way `kernel/devfs`'s threads bound its parked readers, in
userland, and raised by adding a slot rather than a thread.

**Three shared things the concurrency needs, and each is a decision:**

- **The copy before the fork.** The worker shares memory with the parent, so
  the request bytes it decodes are the ones the parent wrote -- but only if
  they are copied into the worker's slot first. The instant the fork returns,
  the main loop may overwrite its own frame with the next request. A worker
  that read the parent's frame would then decode whatever arrived next. The
  copy is what makes the borrow rule survive a second reader.
- **The write lock.** Two workers, or a worker and the main loop, can finish
  two replies at once. A pipe write is not atomic across a full ring, so two
  interleaved replies are a frame of garbage the wire cannot resynchronise. A
  `Spin` held for the length of each write serialises them. It is the first
  lock ring 3 has, over `lock cmpxchg` -- the one instruction that makes a
  read-modify-write atomic without a privilege.
- **`RFNOWAIT`, so nobody waits.** A worker is the kernel's to reap the
  moment it exits. A serve loop that had to `wait` each worker would be
  serial again. The reaping is lazy. `reap_orphans` runs whenever a process
  wants a slot, so a server that forks a worker per request never fills the
  table with the dead ones.

`Spin` may never be held across a park. A worker parked in a device read with
the write lock held would stop every other reply. The rule is `kernel/sync`'s,
kept by hand where ring 3 has no `can_sleep` to check it.

## VECTRA02: segments, because compilers make shapes

VECTRA01 says `one page of text`, and the blobs are exactly that. A linked
program is text to execute, rodata to read, and bss to write, each wanting
its own permissions on its own pages. The second format is a segment table
-- the useful rows of an ELF's program headers, and nothing else:

    +0  magic "VECTRA02"   +8  entry   +16 nsegs (1..4)   +24 reserved (0)
    each row: vaddr, filesz, memsz, flags (bit 0 write, bit 1 execute)

`build.odin` converts the linked ELF: it takes the `PT_LOAD` rows, refuses a
segment that starts off a page boundary, and writes the table and payloads.
`sys/libuser/link_user.ld` is why the refusal never fires. The script aligns
every change of permission to a page, because the kernel maps pages and a
mid-page segment would share one across permissions.

The loader's judge, `image2_read_segs`, holds the format to rules the loader
then relies on. Segments are page-aligned, ascending, and non-overlapping.
Everything lands clear of the stack. The entry sits inside an executable
segment. And **no segment is both writable and executable**, which makes W^X
a property of the format rather than a habit of its builders.

The self-test holds a crafted table to every refusal, and then asks the
running process's page tables directly. The entry's page executes and refuses a write, and the
stack's page is the reverse.

Two loader details cost a real debugging session each, recorded here so they
cost nobody another:

- **The stack arrives tilted.** The SysV ABI enters a function with the
  return address already pushed, so compiled code assumes `rsp + 8` is
  16-byte aligned and spills SSE registers on that belief. A blob never
  held the belief, so only `load_v2` enters at `STACK_TOP - 8`. Without the
  tilt, the program faults on the first aligned spill, three calls deep in
  the runtime.
- **A deliberate exit closes its descriptors, and a control forced it.**
  `sys_exit` runs in thread context, where a clunk is legal, and it is the
  last moment one ever runs for that process. Before the change, a server
  that exited mid-request left its pipe open: not dead but *quiet*. Its
  client sat parked on a request nothing would answer, and the only thread
  that could have run the teardown sat parked with it. A faulting process
  still holds its descriptors until `destroy`, which is the note's job to
  finish.

## `servers/ramfs`: the proof, and the first resident

Plan 9 keeps a tiny ramfs as its teaching server, and this one takes the same
job. It is the smallest complete answer to `what does a file server
implement`, in the handler shape the kernel's own servers use. Two files,
chosen to prove the loader. `/hello` answers out of the program's rodata.
`/note` is writable storage in its bss, zero on arrival, which is what a
zeroed mapping means. The note is also larger than the kernel's one-call copy
bound, so serving it whole is what proves the library's read and write loops.

The image is 54 KB in three segments, thirteen times the size of a blob.
`/bin` serves it beside the blobs, in the other format, through the same
`#b`. The kernel mounts `/srv/ramfs`, reads and writes through it, lists it,
and removes to stop, with every byte crossing ring 3 twice.

## `servers/consrv`: two processes, one server

The rfork milestone's program, and the first server that waits on two
things at once. `main.odin`'s comment tells its own story. What belongs
here is what it proved about the runtime:

- **`libuser.rfork(RFPROC | RFMEM)` from compiled code works as Plan 9's
  does.** The child continues from the call site on a private copy of the
  stack. An ordinary `if pid == 0` branches the two lives -- no entry
  function, no stack juggling, no allocator.
- **Shared bss is a real meeting point.** The child parks reading
  `/dev/cons` and publishes bytes into a producer-consumer ring of two
  monotonic counters. Workers drain it from their reads.
  `intrinsics.volatile_load`/`store` order the counter against its bytes.
  The producer stays lockless, because the child is the only writer of
  `head`. The consumer end is under a lock now, because `serve_mux` gives the
  ring many readers where it once had one.
- **The note is a teardown a program can drive.** On `Tremove` the parent
  notes its reader out of a parked device read, and exits zero only if the
  wait answered EINTR. `libuser` grew `rfork` and `note` wrappers for it.

**`consrv` reads `/line` with a parked read now**, through `serve_mux`. A
read with nothing typed waits in a worker of its own, and the main loop
answers another client while it waits. The zero-bytes wart is gone.

What consrv adds on top of the library is two locks and a flag. The write
lock `serve_mux` needs, and a state lock over the fid table and the ring's
consumer end. The flag is for shutdown. A worker parked on an empty ring at
teardown reads it and leaves, rather than polling for a byte the torn-down
console will never send.

## `servers/kbdfs`: a kernel service, rebuilt as a program

The userland devfs the handoff pointed at, and its first tenant. `kbdfs`
reads `/dev/scancode` -- the raw make and break codes the tap serves -- runs
the scancode state machine, and serves the characters it makes on `/kbd`. The
translation is `kernel/drivers/kbd`'s, byte for byte. The two US-layout
tables, shift, caps, control, the extended prefix, and the rule that a
release makes no character. A scancode becomes a byte on `/kbd` here, where
the kernel would have made it one on `/dev/cons`. Nothing but the address
space it runs in is different.

The shape is `consrv`'s, because the problem is the same. A reader child
parks on a device that blocks, the parent serves 9P through `serve_mux`, and
a read of `/kbd` parks in a worker. Opening `/dev/scancode` is what diverts
the raw stream to the program. Until it does, the kernel translates the
scancodes itself.

Three things this proved about the runtime:

- **The raw halves are reachable.** `/dev/scancode` opens, diverts, and reads
  from ring 3 like any file. `kbdfs` stands exactly where the kernel's
  keyboard driver stood, one privilege level out.
- **A program carries an initialised table.** `PLAIN` and `SHIFTED` are the
  first static arrays a program in this tree relies on. The compiler puts
  their bytes in the image and the loader maps them, so a program reads one
  as readily as the kernel does.
- **The flush order was wrong, and `kbdfs` found it.** A device read that
  drained before checking the flush lost a keystroke to a flush racing its
  arrival, about one boot in three. The read consumed the bytes into a reply
  the client had already given up on, and `kernel/mnt` dropped it. Both
  device-read loops check the flush first now. `docs/DEVFS.md` owns the fix.

## `servers/eiafs`: the port, served both ways

The userland devfs's second tenant, and the first server whose `Twrite`
reaches hardware. `eiafs` opens `/dev/eia0`, which diverts the port's bytes
to it, and serves them raw on `/eia0`. There is no translator, because the
wire's bytes are already the content. `kbdfs` proved the read side. This
one proves the write side: a client writes the served file, and the bytes
go down the shared descriptor and out the port.

The shape is `consrv`'s with one divergence. The open takes `O_RDWR`, and
the shared descriptor table splits the directions. The child reads the one
descriptor for its whole life, and the parent's handler writes it on a
client's behalf. A write never parks, because the UART drains its FIFO at
its own pace. So the serve loop answers a `Twrite` inline and spends no
worker on it. `blocks` stays what it was, true only for a read of the
served file.

Three things this proved about the runtime:

- **The raw device files work in both directions from ring 3.** `kbdfs`
  read a tap. `eiafs` reads one and writes the device behind it, through
  the same descriptor, and the kernel's console count never moves.
- **The shared descriptor table is load-bearing, not a convenience.** One
  open before the fork hands both halves the number. Each half uses its own
  direction, and neither closes it -- the exit is the close.
- **The teardown protocol has a hang behind it, and the control found it.**
  A parent that leaves without noting its reader strands the child parked
  in a device read. The orphan holds the shared descriptor group, the
  posted pipe never hangs up, and the boot hangs at `pipe.quiesce`. The
  child-first rule is not a courtesy. It is what lets the machine finish.

## The build, and where the image goes

`build.odin` compiles each entry in `user_programs` with the kernel's own
compiler and vets, links it with `link_user.ld`, and converts it to
`build/user/<name>.vx`. The kernel's compile then embeds the image with
`#load` and `bin_init` publishes it. User programs build *before* the
kernel for exactly that reason: what `/bin` serves is what was just built.

A tree checked before the image was ever built still compiles. The `#exists`
fallback publishes one fewer file, the boot line counts honestly, and the
self-test fails loudly on the absence. `make check` also checks every
`servers/` package on its own, so the user side keeps the kernel's vets.

## The controls

Twelve mutations and one flake, each observed on a real boot. Three are the
concurrent serve loop, two are `kbdfs`'s translation, and three are
`eiafs`'s port. The copy-before-fork
invariant is not among them. A single-client test leaves too wide a gap
before the next request for a worker to lose the race. That one is argued
rather than tripped, the distinction `docs/TESTING.md` draws between a control
that cannot be expressed and one that fails to fire.

| Mutation | Result |
|---|---|
| the stack tilt removed | caught -- seven failures, first `and it posts /srv/ramfs through the library`, which is how the tilt was found |
| `read_full` made one call | caught -- `a note longer than one copy bound lands whole`. **The first run hung the boot instead**, and the hang was the finding: an exited server's descriptors stayed open until `destroy`, so its client parked on a quiet pipe. `sys_exit` closes descriptors now, and the same mutation fails fast |
| an executable segment mapped writable | caught -- `the entry's page executes and refuses a write`, asked of the page tables directly |
| segment pages not zeroed | **not caught** -- the free list happened to hold clean frames, so the bss check passes whether or not the loader zeroes. The same shape as the freed-slab note in `docs/HANDOFF.md` section 5: reuse has to be forced before absence is visible |
| the `/line` read answers empty rather than parking | caught -- `the read parks on the empty line, rather than answering empty` |
| `blocks` never defers, so the read runs inline | **the boot hangs** -- the inline read polls forever and freezes the serve loop, so the concurrent stat is never answered. The hang is the finding, the way `read_full`'s was |
| the worker never writes its reply | caught -- `the parked read wakes when the line is typed`, which it never does |
| `kbdfs` ignores shift | caught -- `carrying the characters the state machine made`, because the shifted `1` reads back as `1` not `!` |
| `kbdfs`'s reader pushes the raw scancode | caught -- the same check, because a make code is not the character it names |
| `eiafs`'s Twrite forward dropped, the refusal restored | caught -- `a write through the mount takes every byte, out the wire`, the one check no earlier server has |
| `eiafs`'s `drain` reads the producer's counter as its own | caught -- `the parked read wakes when the wire speaks`, which it never does |
| `eiafs`'s parent exits without noting its reader | **the boot hangs** at `pipe.quiesce` -- the orphaned child holds the shared descriptor group, so the posted pipe never hangs up. The third hang-as-finding, and the reason teardown is child-first |

And the flake: a one-in-twenty boot printed a program's line half-staged,
with zeroes for a tail. `load` started the thread, and the self-tests staged
the data page after it. The program lost that race for two milestones, until
this milestone's timing let it win. `load_held` and `launch` split the call
now, so staging happens while there is no thread to race. A rule enforced by
ordering beats the same rule kept by luck.

## Known warts

- **No allocator in ring 3.** The nil allocator makes an accidental `new`
  fail loudly, and everything real is static. Right for a server of this
  size, and the first program that wants a heap will want `sys/libuser` to
  grow one deliberately.
- **`_start` is each program's own three lines.** The runtime start, the
  post, the serve call. A shared crt-style entry wants arguments and an
  environment to justify it, and nothing passes either yet.
- **`serve` still answers one request at a time**, and it is the right loop
  for a server whose every answer is a table lookup, like `ramfs`. A server
  with a request that parks reaches for `serve_mux` instead. Only the main
  loop reads the pipe under either, so `read_full`'s non-atomic read is
  never raced -- the workers write, they do not read.
- **A flushed worker keeps polling.** `serve_mux` forks a worker for a read
  that parks, and a client's `Tflush` cancels the request on the wire but
  not the worker behind it. The worker polls until its data arrives or the
  server shuts down. `kernel/mnt` has the same shape for a moment on the
  kernel side, and Plan 9's simple servers do too. Flush that reaches the
  worker is a later refinement.
- **The converter trusts `ld.lld` about overlap.** It refuses misalignment
  itself, and the loader's judge re-checks everything else. A malicious
  image never reaches further than the judge, which the crafted-table
  checks hold to each refusal.

## See also

- `docs/USER.md` -- the door, the loader's callers, and the seven ring 3
  milestones.
- `docs/PIPE.md` -- the pipe under `post`, and the wire that mounts it.
- `docs/VECTRA9.md` -- the codec a ring 3 server now links.
- `docs/TESTING.md` -- the discipline the controls above follow.
