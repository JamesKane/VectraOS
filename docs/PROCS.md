# Processes and threads, Plan 9's way

**Written before the code.** `docs/SHELL.md` ended with a machine that
boots to two shells and spends thirteen processes doing it, and named the
bill: a process here cannot wait on two things, so every server with two
blocking sources forks a reader, and the serve loop forks a process for
every request that parks. That is a design that was right for a self-test
and is wrong for a running system. This is the plan to make the process and
thread system Plan 9's: processes cheap enough to be the answer they are
there, threads and channels inside a process for what does not block, and
a serve loop that answers a request later rather than parking a process on
it. `docs/HANDOFF.md` section 6 points here.

## 1. What a process costs, and what Plan 9 pays

Every number below is the tree's as of the last commit of `docs/SHELL.md`.

| Thing | Vectra today | Plan 9 |
|---|---|---|
| a process is | one kernel thread with a 32 KiB kernel stack, an address space, a 64 KiB user stack allocated up front, a slot in a table of 32 | a `Proc` from a pool sized to memory, a kernel stack of a few KiB, a stack segment that grows on demand |
| `rfork(RFPROC)` copies | every data, stack and heap page, eagerly, byte by byte -- at least 64 KiB for a tool that touched its heap | page table entries; the pages copy on the first write, if ever |
| threads in a process | one; a second thread is a second process under `RFMEM` | as many as `libthread` makes, cooperative, in one proc; procs for what blocks |
| a server with two blocking sources | forks a reader process | `proccreate`s a reader proc that sends on a channel |
| a 9P request that must wait | `serve_mux` forks a process to park on it, `RFPROC\|RFMEM\|RFNOWAIT`, one per request | is held, and answered later by whichever thread has the answer, through `respond` |
| a process waiting for another | `sleep` capped at 100 ticks, then a loop | `rendezvous(2)`, `semacquire(2)`, `sleep(2)` unbounded, `alarm(2)` |
| a note | from a parent to a child, the tick or the door delivers | from any process of the same user; `^C` at the console posts `interrupt` to the group in front |

The thirteen processes for two shells break down as: two filesystem
servers, one serial shell, a keyboard server and its reader, a draw server
and its reader and a worker per parked read, a terminal's drawer, typist
and shell. Plan 9 spends about ten on the same picture -- `rio` alone is
three procs and many threads -- and does not notice, because a proc costs
it a few kilobytes and a fork costs it nothing until a page is written.
The difference is not the count. It is that the count grows with activity
here, one process per parked request, and that each one is dear.

## 2. What is there

- **The scheduler treats a user thread as a thread**, and that is the
  design. Sixteen priorities, per-core queues, a 10 ms slice, preemption
  from the tick. Nothing here changes.
- **`rfork` with Plan 9's flags**: `RFPROC RFMEM RFFDG RFCFDG RFNAMEG
  RFCNAMEG RFENVG RFCENVG RFNOTEG RFNOWAIT`. `RFREND` and `RFNOMNT` are
  refused. The segment rules are Plan 9's, text shared always, the stack
  copied always; only the copy is eager.
- **Notes**, with a handler, `noted`, note groups, delivered at the door
  and the tick, unwinding a parked `sleep_noted` as `EINTR`. What is
  missing is who may post one, and a console that posts.
- **A rendezvous in the kernel**, `sync.Rendez`, Plan 9's down to the
  name, with conditions as procedures and deadlines. Ring 3 cannot reach
  it.
- **A serve loop with slots and a write lock**, `serve_mux`, which already
  copies a request into a slot and answers a flush after the request's
  fate is decided. What it does with the slot -- fork a process -- is the
  one thing to change.
- **A page fault ends the program.** There is no demand paging, so there is
  nowhere yet for a copy-on-write fault to land.

## 3. The order

Each step ends with a boot line, and each is usable before the next
starts. The serve loop comes first because it is the multiplier; cheap
processes second because they are the base cost; the primitives third
because the library needs them; the library last because it is what the
first three were for.

### Step 1: answer later, not from a worker

`sys/libuser/serve.odin`, about 300 lines changed, and every server that
uses `serve_mux`.

Plan 9's `lib9p` never parks a process on a request. A `read` that has
nothing to say yet stores the request and returns; when the keyboard proc
gets a key it calls `respond` on the stored request itself, from its own
proc, under the write lock. The reply goes out from whoever has the answer.

- **`Pending`**: `serve_mux`'s slots keep the request -- tag, fid, count,
  offset -- and nothing forks. `blocks` becomes `defer`: the handler
  answers `.Later` instead of a reply, and the loop goes on to the next
  frame.
- **`respond(m, slot, reply)`**: callable from any process sharing the
  `Mux`, takes `wlock`, writes the reply, frees the slot. A flushed slot
  answers `Rflush` and nothing else, as now.
- **The producer answers**: `kbdfs`'s reader child, on a key, drains the
  ring into the oldest pending read and responds. `intuition`'s reader
  does the same per window. `consrv` and `eiafs` likewise. The
  `cons_parked`/`EAGAIN` workaround in `intuition` goes, because a pending
  read costs a slot and not a process.
- **`serve` stays** for the servers whose reads never park.

Proves: `ps` from the serial shell with a window open shows no worker,
and two shells are ten processes. The user suite's `verify_consrv`,
`verify_kbdfs` and `verify_terminal` pass unchanged, and the boot line
says how many processes the machine holds at `boot complete`.

**Where it stands.** Done. `serve_mux` keeps a request the handler holds
in a slot and reads the next frame; `libuser.held` and `libuser.respond`
let the reader child answer it from its own process; a flush of a held
request drops it and answers itself. `consrv`, `kbdfs`, `eiafs` and
`intuition` drain or hold, their readers answer what they hold, and
`intuition`'s `EAGAIN` count is gone with the worker it counted. The user
suite passes unchanged on the three boards and forks thirty-six fewer
processes doing so; `ps` from the serial shell shows two shells as ten
processes and no worker.

### Step 2: cheap processes

`kernel/user`, `kernel/mem`, about 1,200 lines.

- **Copy on write.** `fork_segments` copies page table entries and marks
  the frames shared and read-only in both spaces; a write fault on a
  shared frame copies the one page and maps it writable. This is the first
  fault a program survives, and the fault path grows one case. A frame's
  share count lives with the frame, in the PMM, which is where Plan 9's
  `Page.ref` is. `RFMEM` shares as before; the stack copies on write like
  the rest, which retires the eager pass `rfork.odin` says it keeps on
  purpose.
- **A growable frame list per segment**, which `docs/USER.md` already says
  would retire the `.Data`/`.Anon` split and the fixed 128-frame array.
- **A stack that grows.** The user stack is one page at start and grows
  on a fault below its base, to a ceiling, which is the second fault a
  program survives.
- **The table becomes a pool.** `Process` records come from the heap
  through a pid table, and `MAX_PROCESSES` becomes a ceiling of a few
  hundred set by memory rather than a static array of 32. `MAX_SPACES`,
  `MAX_SEGMENTS` and `MAX_FD_TABLES` follow it. The kernel stack shrinks
  to 16 KiB, which is what the deepest path in the tree uses with room.

Proves: `rc`'s script in the user suite, which forks twenty times, runs
in fewer ticks than before -- the number is on the boot line already --
and the tool script's exec count costs no copy. Two hundred `sleep 100 &`
from one shell are two hundred processes at once, and `ps` lists them.

**Where it stands.** Copy on write and the growable frame list are done.
A fork of a segment with one holder shares its frames read-only in both
spaces and counts the holders in the physical allocator; the first write
by either side faults into `fix_fault`, which copies that page into the
writer's own segment, or gives the write bit back when the writer is the
last holder. A segment with several holders under `RFMEM` is still copied
eagerly, and a segment about to be shared has its copy-on-write pages
resolved first, so the fault handler never reaches another process and
needs no shootdown. A page a segment names that the tables lack is
refilled, which is what let the multiprocessor shootdown test watch a
fault rather than a death. The kernel's own writes into a program --
`copy_out`, a note's frame, the self-tests' cells -- resolve the page
first. A segment's frames are a list from the heap now, and a run that
has a page replaced becomes one; `segbrk` grows and shrinks both shapes.

The user suite passes on the three boards with 636 forks sharing their
pages and about 780 pages copied on a write. The tool script fell from
4700 to 3400 ticks on amd64, 4500 to 2600 on arm64, and 6100 to 2900 on
riscv64; the shell script from 231 to 155 ticks on amd64. The stack that
grows and the process pool are the two pieces still to come.

### Step 3: the primitives a library needs

`kernel/user/syscall.odin`, `sys/abi`, `sys/libuser`, about 600 lines.

- **`rendezvous(tag, value)`**, Plan 9's: the first caller with a tag
  sleeps, the second exchanges values with it and wakes it. On
  `sync.Rendez` with the tag as the condition. This is what `libthread`
  parks a proc on.
- **`semacquire`/`semrelease`** on a word in shared memory, 9front's, so a
  lock's waiter sleeps in the kernel rather than yielding in a loop.
  `libuser.lock` becomes one.
- **`sleep` unbounded**, and **`alarm`**, which posts `alarm` to the
  caller after a time, so a program can wait with a deadline.
- **Notes by owner.** There is one user, so any process may note any
  other, which `/proc/n/ctl` already allows; `sys_note` stops asking for a
  child, and says so, until processes have owners.
- **`^C`.** A note group owns a console: `/dev/consctl` takes `notepg N`,
  a window's `consctl` the same, and a typed `0x7F` or `^C` posts
  `interrupt` to that group. `rc` sets it at startup with its own group
  under `RFNOTEG`, so the command it is running takes the interrupt and
  the shell does not.

Proves: a self-test program parks in `rendezvous` and is woken by its
partner; a `sleep 1000` in the tool script is one call; `^C` typed at the
serial shell ends a `sleep 100` and leaves the shell.

### Step 4: `libthread`

`sys/libthread`, about 1,500 lines, and the servers rewritten on it.

Plan 9's threads are cooperative coroutines in one proc, switched in user
space, talking through channels, blocking only on each other; a thread
that must block in the kernel is given a proc of its own with
`proccreate`. The library is `threadcreate`, `proccreate`, `chancreate`,
`send`/`recv`/`nbsend`/`nbrecv`, `alt`, `yield`, `threadexits`, and a
scheduler per proc that parks the proc in `rendezvous` when every thread
it has is waiting on a channel. The context switch is one small `.S` per
architecture, the shape the kernel's already has.

Then the servers: `intuition` becomes one proc of threads -- the serve
loop, a thread per window's line -- and one keyboard proc that sends
keys on a channel; `kbdfs` and `consrv` the same in miniature; the
terminal's drawer and typist become a thread and a proc with a channel
between them, and its shell a proc. The `Mux` and its slots become
`lib9p`'s request records, answered by `respond` from any thread.

Proves: `intuition`'s worker slots are gone and its `cons` reads are
answered by the keyboard proc; the terminal draws a typed line and a
shell's output from one process; and the count on the boot line is
Plan 9's.

## 4. Decisions taken here, and what would reverse them

- **Processes are the answer to blocking, as in Plan 9.** Not `select`, not
  non-blocking reads. A proc per blocking source is the design; what was
  wrong was the price of a proc and a worker per request. A kernel that
  grew `select` would let every server be one process, and would be a
  different kernel.
- **Copy on write before a growable stack, before a bigger table.** The
  copy is what makes every fork dear; the rest is sizing.
- **`respond` before `libthread`.** The serve loop's multiplier is one
  procedure, and it does not need a thread library to be removed.
- **One user, still.** Notes by owner means notes by anyone until
  `docs/HANDOFF.md`'s authentication milestone. Written down rather than
  faked with a check that always passes.
- **No priority inheritance, still**, for `docs/HANDOFF.md`'s reason.

## 5. Sizes and order of dependence

    step 1  respond      libuser 300, servers 200      nothing before it
    step 2  cheap procs  kernel 1,200                   nothing before it; beside step 1
    step 3  primitives   kernel 400, libuser 200        nothing before it
    step 4  libthread    libthread 1,500, servers 800   steps 1 and 3

Steps 1 to 3 are independent and can proceed in any order or at once.

## See also

- `docs/USER.md` -- the process as it is, and the paragraphs that already
  ask for a growable frame list and a copy on write
- `docs/SYNC.md` -- the rendezvous ring 3 will get a door to
- `docs/INIT.md` -- the thirteen processes, and why
