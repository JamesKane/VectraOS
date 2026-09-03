# The process device

`kernel/procfs/` is `#p`, bound at `/proc`: a directory per live process,
named by pid, and in each the four files a shell needs.

    /proc/n/status    name pid parent state notegroup held|detached directory
    /proc/n/ns        the mount table, as bind and mount lines
    /proc/n/note      write: post a note; read: the last note posted
    /proc/n/ctl       write `kill`: end the process at its next boundary;
                      `stop`: park it there until `start`
    /proc/n/args      the arguments it was started with, as one line

`ps` reads `status` for every pid, `ns` reads `ns`, and `kill` writes
`ctl`, or `note` with `-n`. `rc` sets `$pid` from the new `getpid` call,
so `ns` with no argument is the caller's own.

## Doors, not pointers

The device imports `kernel/user` and reads the table through five
procedures in `procinfo.odin`: one record as a snapshot, the next live pid
after a given one, a note, a kill, and the namespace written out. Each
takes the table lock only while it copies, and the device holds no process
pointer across a message. A fid names a pid and a file; a pid that has
gone answers `no such process`, and a listing paced across an exit is a
shorter listing. The cookie of `/proc` is the pid, which never comes back.

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

`args` is what the kernel now keeps of a program's arguments: the words
joined by spaces, cut at 256 bytes, set when they are staged and copied
across a fork. `ps -a` shows them.

## Kill and note

`ctl` takes `kill` too, and does what `user.end` does without the
wait: the kernel's word is set, the thread is woken, and the process ends
at its next boundary whether or not it registered a handler. The note it
carries is `sys: killed`, which is what its parent's `await` repeats.
`note` posts any text and the process may handle it, as `docs/USER.md`
describes. There are no owners yet, so any process may do either to any
other; Plan 9 checks the user here, and so will this, the day processes
have one.

## Checked by

Five lines of `tests/tools.rc`: `ps` finds the shell running it, `ns`
finds `bind #b /bin`, `kill` ends a `sleep 100 &` whose `wait` then
answers `sys: killed`, `args` reads `sleep 100` back, and `stop` sees the
sleep `Stopped` and then `Blocked` again after `start`.

## Not yet

`fd`, `segment`, `wait`, `notepg` and `profile`, each of which waits for a
tool that wants it.
