# The userland runtime: Odin in ring 3

`sys/abi/`, `sys/libuser/`, `servers/ramfs/`, `servers/consrv/`, the
`VECTRA02` format, and the user half of `build.odin`.

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
  monotonic counters. The parent drains it from its serve loop.
  `intrinsics.volatile_load`/`store` order the counter against its bytes,
  and each side owns exactly one counter. That is the only concurrency
  discipline ring 3 has, and enough for this shape.
- **The note is a teardown a program can drive.** On `Tremove` the parent
  notes its reader out of a parked device read, and exits zero only if the
  wait answered EINTR. `libuser` grew `rfork` and `note` wrappers for it.

A read of `/line` with nothing arrived answers zero bytes, which a client
cannot tell from EOF. The wart is deliberate: parking the Tread would hold
the serve loop's one request while the keyboard is silent, starving every
other client. A serve loop with a thread per request is the fix, and the
argument for the next milestone.

## The build, and where the image goes

`build.odin` compiles each entry in `user_programs` with the kernel's own
compiler and vets, links it with `link_user.ld`, and converts it to
`build/user/<name>.vx`. The kernel's compile then embeds the image with
`#load` and `bin_init` publishes it. User programs build *before* the
kernel for exactly that reason: what `/bin` serves is what was just built.

A tree checked before the image was ever built still compiles. The `#exists`
fallback publishes one fewer file, the boot line counts honestly, and the
self-test fails loudly on the absence. `make check` also checks
`servers/ramfs` on its own, so the user side keeps the kernel's vets.

## The controls

Four mutations and one flake, each observed on a real boot:

| Mutation | Result |
|---|---|
| the stack tilt removed | caught -- seven failures, first `and it posts /srv/ramfs through the library`, which is how the tilt was found |
| `read_full` made one call | caught -- `a note longer than one copy bound lands whole`. **The first run hung the boot instead**, and the hang was the finding: an exited server's descriptors stayed open until `destroy`, so its client parked on a quiet pipe. `sys_exit` closes descriptors now, and the same mutation fails fast |
| an executable segment mapped writable | caught -- `the entry's page executes and refuses a write`, asked of the page tables directly |
| segment pages not zeroed | **not caught** -- the free list happened to hold clean frames, so the bss check passes whether or not the loader zeroes. The same shape as the freed-slab note in `docs/HANDOFF.md` section 5: reuse has to be forced before absence is visible |

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
- **One request at a time, by design.** `serve` answers in order, so a slow
  file holds the connection the way any synchronous server does. The wire's
  deadline and flush cover the client side. `rfork` gave a server more
  processes, and `consrv` waits on two things with two. One *serve loop*
  still answers one request at a time. Two processes must not `serve` one
  descriptor, because `read_full` is not atomic. A concurrent serve loop
  is its own milestone.
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
