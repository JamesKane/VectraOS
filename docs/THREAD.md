# Threads: Plan 9's library, one privilege level out

`sys/libthread/`, `sys/lib9p/`, `tests/thread/`, and the five programs
on them: `servers/consrv`, `servers/kbdfs`, `servers/eiafs`,
`servers/intuition`, `apps/terminal`.

`docs/PROCS.md` step 4, the last of four. The first three made a process
cheap and gave it `rendezvous` and its kin. They also let a 9P server
answer a request later rather than fork a process to park on it. This is
what those were for. A program on this library is procs for what blocks
and threads for what does not, and they talk through channels. A server
on it needs no lock.

## 1. What was wrong, and what Plan 9 does

Every server with two blocking sources forked a reader over `RFMEM` and
met it in shared memory. The meeting place was a ring with volatile
counters and three spinlocks: over the fid table, over the wire, and
over the ring's consumer end. A flag said when to shut down.
`servers/intuition` had all of those and a torn-read argument for its
focus. The terminal had two processes and two locks for one grid. Each
was correct, each was hand-written, and the next server would have
written them again.

Plan 9 has the same kernel rule -- a process waits on one thing -- and
answers it once, in `libthread`. A *proc* is a kernel process. A *thread*
is a coroutine inside one, switched in user space when it blocks on a
channel or a lock. No thread preempts another thread of its proc.

What must block in the kernel gets a proc of its own and sends what it
reads on a channel. Everything else is one proc of threads. Inside that
proc nothing interleaves with a thread until it blocks, so its state
needs no lock. `rio` is a keyboard proc, a mouse proc, a proc reading the
9P pipe, and one proc of threads that owns every window.

## 2. The vocabulary

    proc         `proccreate(fn, arg, stacksize)`. A kernel process made by
                 `rfork(RFPROC | RFMEM)`, sharing this program's memory.
                 Its first thread runs `fn`.
    thread       `threadcreate(fn, arg, stacksize)`. A coroutine in the
                 calling proc, with a stack from the heap. `yield` lets
                 the others run. `threadexits` ends it.
    channel      `chancreate(elemsize, nbuf)`. `send` and `recv` copy one
                 element. A buffer of zero is a meeting, and parks the
                 first side until the second arrives. `nbsend` and `nbrecv`
                 refuse to wait. `alt` waits on several arms at once.
    QLock        a lock a thread may hold across a wait, handed over in
                 arrival order. `Rendez` is a condition under one.
    main         `libthread.main(fn, arg)`, from `_start`: the calling
                 process becomes the first proc and `fn` its first thread.

Every procedure is `contextless`, like `sys/libuser`'s. A thread that
wants a heap behind `context` builds one with `libuser.heap_context` on
its first line, and a thread's procedure is a `proc "contextless"` too.

## 3. The switch

A thread's saved state is a `Label`: the callee-saved registers and the
stack pointer, in an order `thread_<arch>.S` fixes. `vectra_thread_switch
(from, to)` stores into `from`, loads from `to`, and returns -- into
whatever `to` was doing when it was saved. The caller-saved registers
need no saving, because the compiler already assumes a call clobbers
them. That is Plan 9's `gotolabel` and `setlabel` in one procedure.

`label_init` builds a new thread's label, per architecture, so the first
switch into it *returns* into `thread_launch`. On amd64 the address is
the top word of the stack. The stack pointer sits eight below a
sixteen-byte boundary, where a `call` would have left it. On arm64 and
riscv64 the address is the link register. `thread_launch` calls the
thread's procedure and then `threadexits`. There is no special case in
the switch for a thread that never ran, which is the same rule the
kernel's scheduler keeps.

It is a `.S` file rather than an `asm` block for the reason the kernel's
stubs are. A block cannot define a symbol. A switch that returns out of
the middle of a compiled procedure cannot be written inside one either.
`build.odin` assembles the file once per architecture and links it into
every ring 3 program, a hundred bytes each. A table column for the few
programs that import the library would cost more than that.

## 4. A proc, and the two things it has to be careful about

`proccreate` builds the record, the first thread, and a stack for the
proc's scheduler, readies the thread on the new proc's queue, and forks
through `vectra_proc_fork`, which is `rfork` with the child moved onto the
scheduler's stack *before it touches memory*. The caller runs on a
thread's stack in the heap, and the heap is shared. A child that pushed
one word there would push it under the parent. The kernel copies the
stack *segment*, and a thread does not run there. So the child's first
instruction after the door is the stack switch, and the parent's is the
return.

**How a proc finds itself.** Every global is shared, so "the current
proc" cannot be one. It is a word in the stack segment, the one segment
`RFMEM` never shares. The word is a local in `main`'s frame. Every proc
holds its address in `slot`, and each proc's private copy of the stack
decides its contents. A new proc writes its record there first. Plan 9's
`_privates` is the same trick.

**A rendezvous group of its own.** `main` calls `rfork(RFREND)` before
anything else, as Plan 9's `libthread` does. A proc sleeps on a tag that
is its record's address. Every program's heap starts at the same address,
and a fork or an exec inherits the rendezvous group. Two servers started
by one shell would therefore park on equal tags in one group.

A wake meant for one would then take the other, which dequeues from an
empty ready queue and faults. That was the first bug this library had,
and section 11 says how it showed.

A proc made by the first proc is not `RFNOWAIT`, and the first proc waits
for it at the end. A proc made by any other proc is detached. Its maker
may be gone before it is, and a wait nobody makes is a leak.

## 5. Scheduling

A proc's life is `sched`: take the head of the ready queue, switch to it,
and when it switches back deal with what it left. A thread that blocked
set its state and put itself where its waker will look. A thread that
yielded readied itself first. The scheduler frees a thread that exited,
because a thread cannot free the stack it stands on.

A proc with nothing to run parks in `rendezvous` on its own address.
`threadready`, from any proc, takes the proc's lock and appends the
thread. If the proc is asleep it clears the flag and meets it at the
rendezvous *without letting go of the lock*. The lock passes to the
sleeper, which takes the head and releases it. That is Plan 9's
`_threadready` and `runthread`.

It is sound because the sleeper is already on its way to the rendezvous
when the waker takes the lock. A rendezvous cannot be lost, since
whichever side arrives first waits for the other. A note cuts one short
with nothing exchanged, and both sides ask again. A proc with no handler
then dies at that boundary, which is what `threadexitsall` counts on.

A thread may be readied before it switches out, when a thread in another
proc executes its channel arm between its unlock and its switch. That is
harmless. The ready queue is the proc's, the proc runs one thread at a
time, and the scheduler only looks at the queue after the switch.

Thread stacks come from the heap, so a thread that overruns one corrupts
the heap rather than faults. The word at the bottom of every stack is a
mark. The scheduler checks it on every switch back, and a changed mark
ends the program with `thread stack overflow` in its status. That catches
the plain overrun and not a wild pointer. A guard page is the fix the day
one is needed.

## 6. Channels and alt

9front's `channel.c`, with one lock. A channel is a queue of `nbuf`
elements of `elemsize` bytes, or a meeting when `nbuf` is zero. It also
holds a queue of waiting `Alt` records for each direction. `alt` takes
`chanlock` and looks at every arm. It executes one if it can, at random
when several can go, so no channel starves another. Otherwise it hangs
the thread's arms on their channels and parks.

Whoever executes an arm later copies the element and removes *all* of
that thread's arms from their queues, under the same lock. It records
which arm went and readies the thread. The records are on the parked
thread's stack. That is safe because the thread is parked until every
record is off every queue.

`chanlock` is `libuser.Spin`, held for the length of a copy and never
across a wait. A thread in another proc may be inside it, and the only
way to wait for that is to yield the core. `send`, `recv`, `nbsend`,
`nbrecv`, `sendp`, `recvp`, `sendul` and `recvul` are `alt` with one or
two arms.

An arm that would meet its own thread is skipped, so an `alt` that sends
and receives on one channel does not pair with itself.

## 7. QLock and Rendez

`libuser.Spin` parks nothing, and a thread that held one across a channel
wait would stop every thread in the program that wants it. `QLock` is the
other kind. A waiter parks the thread and the proc goes on. `qunlock`
hands the lock to the oldest waiter and readies it, from whichever proc
lets go. `Rendez` is a condition under a `QLock`: `rsleep` lets the lock
go and parks until `rwakeup`, and holds the lock again on return. A wake
is a hint and the caller re-checks, which is the same line
`kernel/sync` draws.

Nothing in the tree holds a `QLock` yet. The servers turned out not to
need one, for the reason section 9 gives, and the terminal neither. The
test program holds and hands one over so that the day something does, it
works.

## 8. Ending

`threadexits` ends the calling thread, and the proc when it was the last.
A proc other than the first exits at once. The first waits for the procs
it made, because a parent that exits first leaves an orphan the kernel
cannot collect. `threadexitsall` ends the program: it notes every other
proc, waits for the ones the caller made, and exits with the status. A
noted proc with no handler dies at its next kernel boundary, which is the
read or the rendezvous it is parked in. That is `stop_child`'s
note-and-wait, which every server did by hand.

Only the first proc calls `threadexitsall` in this tree. From another
proc it would note the first, which would die without waiting for its
children. A note handler in the library, Plan 9's `threadnotify`, is the
fix, and it waits for a caller.

## 9. lib9p: a server that needs no lock

`serve_mux` kept a request it could not answer yet in a slot in shared
memory, and the reader process answered it under the write lock. `lib9p`
is the same loop in the library's shape:

    the reader   a proc parked in `read` on the pipe. Each frame becomes a
                 `Req` on the heap -- the bytes, the decoded message, and
                 `msize` bytes of payload -- and goes down a channel.
    the loop     a thread in the program's proc. A request off the
                 channel, the handler, the reply. A handler that cannot
                 answer yet calls `hold`, and the loop keeps the record
                 on a list and takes the next.
    the answer   `respond`, from any thread of that proc, when what the
                 request waited for arrives. `held` finds the oldest
                 held request a caller can answer.

The handler, the held list, the reply buffer and the server's state are
all one proc's, so none of it is locked. The reply's write is the one
call the loop's proc makes into the kernel, and a pipe write copies and
returns. `Tflush` never reaches the handler. A flush that names a held
request drops it and answers `Rflush` in one step. That keeps
`kernel/mnt`'s rule that `Rflush` follows the flushed request's fate.

The handler is still `vectra9.Handler`, the signature every kernel server
implements. A server on `lib9p` moved its `hold` and `respond` calls and
nothing else.

**What it costs.** One proc more than `serve_mux`, and an allocation per
request. The reader proc exists because the proc of threads cannot park
in `read` -- every thread of it would park too -- and the alternative,
the handler running in the reader proc and the device proc answering held
requests across the proc boundary, is the design with the locks. A
request's record is a few kilobytes from a first-fit heap with one lock,
which the draw server takes once per batch of commands.

## 10. The programs

`consrv`, `kbdfs` and `eiafs` are one shape. A reader proc parks on the
device and sends a read's worth of bytes on a channel. A thread receives
them into the ring and answers held reads. The serve loop answers the
rest.

The bytes cross as a chunk rather than one by one. A read of the served
file answers what one read of the device delivered, and for a cooked
console that is a whole line. The first version sent bytes, and the user
suite's `carrying the whole line` said so.

`intuition` is the reader proc, a key thread, and a thread per window
slot. The key thread hands each byte to the window in front, on that
window's own channel. The window's thread cooks the byte into the
window's line and answers a held `cons` read when the line completes.

The key thread reads the focus per character, in the proc that moves it. The
torn-read argument `focus_win` used to make is gone with the volatile
loads it made it with. A window's queue that is full drops the byte
rather than parks the key thread. So a window nobody reads cannot stop
the keyboard for the rest.

The terminal is two reader procs and one thread. The procs read the
shell's output pipe and the window's `cons`, and send chunks on two
channels. The thread `alt`s over both and does everything else: the grid,
the line, the draw stream, and the ending when the shell's chunk is
empty.

**The count.** Two shells are thirteen processes:

    fatfs, kfs        one each
    the serial shell  one
    kbdfs             a proc of threads, a reader for the pipe, a reader
                      for the scancodes
    intuition         the same three
    terminal          the same three, and its rc

Ten after step 1, thirteen now, and the three are the pipe readers. That
is the shape's price and Plan 9 pays it too: `rio` alone is more procs
than this whole picture. What changed is what the count buys. No server
holds a lock, no server forks per request, and the next server with two
blocking sources is a `proccreate` and a channel.

## 11. Checked by

`tests/thread` is `/bin/threadtest`, spawned by `verify_threads` in the
user suite, and its word is the check. The steps, in order:

- Two threads take turns under `yield`.
- A meeting delivers five numbers in order, and refuses a non-blocking
  receive when empty.
- A buffer of three takes three, refuses a fourth, and drains in order.
- `alt` answers -1 with a `Noblock` arm and nothing ready. It picks the
  one ready arm. It parks on two arms until a thread fills one.
- A proc sleeps in the kernel for twenty ticks and then sends its pid,
  while this proc's threads yield a hundred times and more.
- Three threads queue on a held `QLock` and take it in order.
- A `Rendez` sleeper stays asleep through two yields and wakes on
  `rwakeup`.
- `threadexitsall` ends the program with a proc still parked in `sleep`,
  and the suite checks that no process is left behind.

The checks the five programs had check them still: `verify_consrv`,
`verify_kbdfs`, `verify_eiafs`, `verify_draw` and `verify_terminal`, each
unchanged and each green on the three architectures. The serial shell's
`ps` is the check the suite could not make, and it found the bug in
section 4. The suite spawns every program from the kernel, and a
kernel-spawned program has a rendezvous group of its own. `init` starts
two servers from one shell into one group. The symptom was two `Faulted`
mains with their readers still parked, and `/proc/n/status` said nothing
more. A scratch line in the fault path would have said the address was
zero.

Three controls are not yet run. `threadready` letting go of the lock
before the rendezvous, which the test cannot reach without a second core
in the wake. The arms left on their queues after `alt`, which a second
`alt` on the same channels would trip over. The stack mark unchecked,
which nothing tests, because a thread that overruns its stack here
corrupts the heap in a way no check can name.

## 12. Decisions taken here, and what would reverse them

- **A proc per blocking source, and a proc of threads beside them.** Three
  processes per server rather than two. A kernel `select`, or a read that
  does not park the whole process, would fold the pipe reader into the
  proc of threads. That would be a different kernel.
- **The private word in the stack segment.** A per-process register the
  kernel keeps for ring 3 would replace it, and cost a system call to set.
  Nothing needs one until something wants per-proc data the stack cannot
  hold.
- **Stacks from the heap, marked at the bottom.** A stack from `segalloc`
  with a guard page under it faults on overrun rather than corrupts. It
  costs a segment per thread, and the draw server would hold eleven.
- **One `chanlock`.** A lock per channel would let two procs on unrelated
  channels proceed at once. Nothing here contends for it.
- **No preemption between threads.** A thread that computes for a long
  time starves the others of its proc, as on Plan 9. A tick handler that
  switched threads would need every thread's state to be safe at any
  instruction. The reason to want one is a program this tree does not
  have.
- **`threadexitsall` from the first proc only**, for section 8's reason.
- **`RFREND` in `main`, always.** A program that wanted to rendezvous with
  its parent through the library's own group cannot. None does, and Plan 9
  makes the same choice.

## 13. What is not here

`threadnotify` and a note handler. `threadkill` and `threadint`. A name
in `ps` for a thread, which `/proc` cannot show because a thread is not
the kernel's. A per-thread `context`, which a thread builds for itself. A
channel with a lock of its own. And `threadexitsall` from a proc other
than the first.

## See also

- `docs/PROCS.md` -- the plan, and the three steps before this one.
- `docs/RUNTIME.md` -- `sys/libuser`, whose heap took the lock this
  library needed, and whose `serve` loop is still the one for a server
  whose reads never park.
- `docs/DRAW.md` -- the draw server's keyboard, sections 13 and 14, which
  the window threads now carry.
- `docs/INIT.md` -- the process count at the prompt.
