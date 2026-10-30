# pjdfstest over a v9fs mount (D148 §3)

How a VectraOS export does as a Linux file system, as D148 asks: pjdfstest
over a Linux `v9fs` mount with `version=9p2000`, through 9gate's plain
listener (9gate(4)). Its failures are listed by cause; what 9P2000 has no
word for is listed as outside it, not failed silently, and each cause
names the `.L` messages a translator would speak to answer it (D78).

## The run

2026-10-30: pjdfstest's C version from FreeBSD's `contrib/pjdfstest`
(changed there last 2026-02-14; `makedev` from `sys/sysmacros.h` to build
on glibc), on the dev machine (Fedora 44, Linux 7.2), as root in a
directory of the Orange Pi 6 Plus's `/data`, a Taisce volume, through
`mount -t 9p -o trans=tcp,version=9p2000`. All 230 files ran, none
timed out: 2772 checks passed, 6015 failed.

The first run found two faults of the export, both fixed (745a753): v9fs
names itself as the muid of every rename's wstat, which the export
refused, so no rename worked; and v9fs takes only error strings it knows
(any other is ESERVERFAULT, errno 526), where the export sent `directory
not empty`, `operation not supported` and `wstat can't change that`.

## The failures, by cause

A failure counts once, under the first cause that explains it. A cascade
is a check whose own call worked but whose file an earlier check failed
to make: most follow a symlink, fifo, device or socket that couldn't be
made.

| Cause | Failures | Outside | `.L` messages it needs |
|---|---:|---|---|
| Symlinks, fifos, devices, sockets, hard links | 1845 | 9P2000 and Node | Tsymlink, Treadlink, Tmknod, Tlink |
| Numeric owners: chown, uid and gid, a test run as another user | 1630 | 9P2000 and Node | Tgetattr, Tsetattr (uid, gid) |
| Modes and permissions: chmod, a mode read back, EACCES and EPERM | 1550 | Node | Tgetattr, Tsetattr (mode) |
| Cascades | 780 | | |
| pjdfstest's own comparisons (ctime moving, nlink) | 160 | 9P2000 and Node | Tgetattr |
| Times: atime set, nanoseconds, times past 2^32 seconds | 26 | 9P2000 (ns, 64 bits), Node (atime) | Tgetattr, Tsetattr |
| POSIX leaves open (pjdfstest's TODO) | 24 | | |

Not counted as failures, as v9fs answers them itself on 9P2000: a rename
between directories (EXDEV), and chflags (Linux has none).

Each cause is outside Node as well as 9P2000 but for the times, so `.L`
alone answers none of them: Node keeps a name, a modification time and a
size (gate(2)), every file `none`'s, a file 0664 and a directory 0775,
and checks no permission (capabilities say who may do what, principle
26). Numeric owners stay outside by D78 (no numeric ids anywhere); modes
and string owners come when Node gains them, as 9P2000's (D78), and then
reach v9fs without `.L`. Symlinks and special files, and atime, wait on
deciding whether Node keeps them at all; until then no `.L` message is
spoken toward Linux.

## Reproducing it

On the node, with a volume at 9gate's `/data` and its ctl reachable:

    echo plain tcp!*!564 /data 192.168.0.15 >/svc/9gate/ctl

On the Linux machine (192.168.0.15 here), pjdfstest built from FreeBSD's
tree (`autoreconf -ifs && ./configure && make pjdfstest
CFLAGS='-O2 -include sys/sysmacros.h'`):

    mount -t 9p -o trans=tcp,port=564,version=9p2000 NODE /mnt/vnode
    mkdir /mnt/vnode/pjd && cd /mnt/vnode/pjd
    for t in PJDFSTEST/tests/*/*.t; do timeout 120 bash $t; done

Each `.t` prints TAP; there is no `prove` needed.
