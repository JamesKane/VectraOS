# The process device

`kernel/procfs/` is `#p`, bound at `/proc`: a directory per live process,
named by pid. Each holds the files a shell needs and the files a debugger
needs.

    /proc/n/status    name pid parent state notegroup held|detached directory user
    /proc/n/ns        the mount table, as bind and mount lines
    /proc/n/note      a write posts a note, and a read takes the note pending
    /proc/n/ctl       write `kill`: end the process at its next boundary.
                      `stop`: park it there until `start`. The debugger's
                      words are below
    /proc/n/args      the arguments it was started with, as one line
    /proc/n/mem       the address space, read and written at the address as the offset
    /proc/n/regs      the saved frame, read and written while stopped
    /proc/n/fpregs    the floating-point image, the same way
    /proc/n/text      the program's file, read through the process's own namespace
    /proc/n/segment   one line per segment: kind, first address, end, holders
    /proc/n/fd        the directory, then one line per descriptor: number, server, qid, cursor
    /proc/n/wait      the exit record of a child, as `await` gives it, and a read waits for one

`ps` reads the first, `ns` reads `ns`, and `kill` writes `ctl`, or `note`
with `-n`. `rc` sets `$pid` from the new `getpid` call, so `ns` with no
argument is the caller's own. The rest are `docs/DEVTOOLS.md` section 5, the
kernel's half of a debugger, and `kernel/user/debug.odin` is the door each
one opens.

## Doors, not pointers

The device imports `kernel/user` and reads the table through the doors in
`procinfo.odin` and `debug.odin`. Those are a snapshot of one record, the
next live pid after a given one, a note, a kill, the namespace written out,
and the debugger's reads and writes. Each takes the table lock only while it
copies, and the device holds no process pointer across a message. A fid
names a pid and a file. A pid that is gone answers `no such process`, and a
listing paced across an exit is a shorter listing. The cookie of `/proc` is
the pid, which never comes back.

A read of `mem` walks a space a collector could be freeing. So a debugger's
door *pins* the record for the length of one copy, and `collect` waits for
the pin to drop. A pinned process may still run and exit. Its pages stay
until the read is done.

## What `ns` says

The vfs had no names in its mount table -- a mount point is a server and
a qid, which is what a walk needs and nothing a person can read. Each
member now keeps the two names its bind was made with and whether it was
a `mount` of a served connection, and `vfs.ns_describe` writes them back:
the first member of a point as `bind source target`, the rest with `-a`,
`-c` where the member may create. Replaying the lines in order rebuilds
the union in the same order. Ninety-six bytes of each name are kept, and
a longer one prints with `...`.

    bind #/ /
    bind #c /dev
    bind #b /bin
    mount /srv/memfs /mnt

## Stop and start

`stop` parks a process at its next boundary and `start` lets it go, and
`status` says `Stopped` in between. The boundary is the door or the tick,
as for a note. At the door the thread sleeps on a rendezvous until the ask
is withdrawn; a note posted meanwhile waits for the start, and a kill does
not. A thread the tick catches in ring 3 is parked from interrupt context
the way `block` parks one -- off every queue, its frame in its record --
and `start` readies it by hand. The wake that asks for a stop is a note's
wake, so the record remembers the flag was raised for a stop, and the
boundary takes it down again rather than deliver a note that was never
posted.

Every stop keeps the program's own frame beside it, at the door or in the
tick, and that frame is what `regs` reads and writes. A stop counts. So a
word that starts a process and waits for the next stop can tell it from the
one it started from.

`args` is what the kernel now keeps of a program's arguments: the words
joined by spaces, cut at 256 bytes, set when they are staged and copied
across a fork. `ps -a` shows them.

## The debugger's words

`ctl` takes these past `kill`, `stop` and `start`. Each ask is one stop:
the boundary that honours it takes it down.

    startstop     run, and stop before the next note is delivered. Answer then
    waitstop      answer when the process has stopped, or EIO if it ended
    hang          stop at the next exec, before its first instruction, until `nohang`.
                  A fork carries it, so a watched program's children stop too
    nohang        withdraw that
    startsyscall  run, and stop at the next system call's entry. Started again,
                  stop once more before it returns
    step          run one instruction and stop, where the architecture has a step

A trap is an ending for a program nobody watches, as `docs/USER.md` argues.
Under `startstop` it is a note instead, and the process parks before the
note lands. The note is `sys: breakpoint` for the instruction a debugger
planted, and `sys: trap: fault addr=... pc=...` for the rest. A read of
`note` takes the note away, so the process can be started without it.
Started with the note still pending, it meets it at the next boundary and
ends as it always has.

The kernel knows nothing about breakpoints. One is bytes written through
`mem`, and the trap they raise is the CPU's. A fork's child shares its
parent's text, and a write into shared text gives the process its own copy
first. So the breakpoint reaches one process and no other. On amd64 the
breakpoint's gate opens to ring 3. `int3` is a software interrupt, and the
CPU refuses one through a gate below the caller's ring.

`regs`, `fpregs` and a write of `mem` want the process stopped, or not yet
launched. The frame is on the thread's own stack, and a write of text is a
write of what the thread is running. A frame written back is rebuilt rather
than believed, the way a frame handed back through `noted` is. The layout
is the architecture's own trap frame, `arch.FRAME_REGS_SIZE` bytes, which
is what a debugger for that architecture reads.

`step` is the trap flag on amd64. On arm64 it waits for the scheduler to
carry `MDSCR_EL1.SS` to the core that resumes the thread. riscv64 has no
step in the base architecture. Both answer EOPNOTSUPP, and the boot line
says so where it would have stepped. `watch` waits for the debug registers.

## Kill and note

`ctl` takes `kill` too, and does what `user.end` does without the
wait: the kernel's word is set, the thread is woken, and the process ends
at its next boundary whether or not it registered a handler. The note it
carries is `sys: killed`, which is what its parent's `await` repeats.
`note` posts any text and the process may handle it, as `docs/USER.md`
describes. The host owner's processes may do either to any process, and a
process may reach only its own user's. `user.may_control` is the one check.

## Checked by

Five lines of `tests/tools.rc`: `ps` finds the shell running it, `ns`
finds `bind #b /bin`, `kill` ends a `sleep 100 &` whose `wait` then
answers `sys: killed`, `args` reads `sleep 100` back, and `stop` sees the
sleep `Stopped` and then `Blocked` again after `start`.

And `verify_debug` in `kernel/user/verify.odin`, the debugger's loop with no
debugger. A held program gets a breakpoint through `mem`, and `startstop` is
asked before it launches. `note` says `sys: breakpoint`, and `regs` shows
the counter past it and a write takes it back. `mem` restores the
instruction, `step` runs it alone, and `start` lets the program end. A
second program is stopped at a write's entry and its return by
`startsyscall`, with the number and then the answer on the frame. A third,
from a file, is read through `text` and stopped for `waitstop`.

The control removes the check before
delivery, and the breakpoint ends the program: `startstop` answers EIO and
the checks after it fail.

## Not yet

`hang` is checked by `tests/dbg.rc`, the debugger's script, whose `run` is a fork that writes `hang` to its own ctl and execs. `watch`, `notepg` and `profile` wait for a tool that wants them.
