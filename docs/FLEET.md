# Fleet: Plan 9's machines, on a homelab's network

**Written before the code.** Every other plan in this tree is for one
machine. This one is for several, and for what Plan 9 was built to do. A
terminal on the desk, a CPU server in the rack, and a file server that
holds the one tree. A namespace reaches across all of them one mount at a
time. The machines are of three architectures and nobody notices.

`docs/HANDOFF.md` section 6 points here, and `docs/HARDWARE.md` step 3
builds the wire this runs over.

The audience is a person with a homelab. A PC, a board or two, and a
laptop that runs QEMU. They want the fleet to look like one machine. A
build goes to the fast one and a game to the one with the screen, and one
`ps` shows every process in the house.

**What the review found.** The foundations are in place. The wire is
9P2000.L with pending requests and flush, and a server cannot tell which
transport it answers from. A mount is a posted connection, which is Plan
9's `srv` and `mount` arc. Every device is messages, so every device can
cross a mount.

What is absent is the whole layer above that. Vectra only ever dials and
never serves. It has one user with no way to prove it, no machine that
plays the file server, and names a host by its address. Two plans add
local-only fast paths without a file fallback. This document is the layer,
the fallback rule, and the authentication milestone two documents
promised.

## 1. What is taken, and from where

**From Plan 9, the shape of a fleet.** Three roles, and any machine can
play any of them. A terminal has the screen and the keyboard and runs the
window system. A CPU server has cores and memory and runs programs for
terminals. A file server has the disk and the one tree. A role is a
namespace and an init script, not a kernel.

`cpu` runs a shell on a server with the terminal's devices mounted at
`/mnt/term`. A program on the server then draws on the terminal's screen
and reads its mouse. `exportfs` serves a process's namespace to another
machine, and `import` mounts a piece of a remote one. `/net` is the
network as files. `cs` turns a name into an address, and `ndb` is the
database that names the machines. A machine with no disk boots with its
root on the file server.

`factotum` holds a user's keys and does every authentication on a
program's behalf, so a program never sees a secret. `listen` runs a script
per port, so a new network service is a new file in a directory.

**From 9front.** The rule that the password protocol Plan 9 shipped with
is dead, and the willingness to replace it. `ndb` as it stands there.
And `/n` as where remote trees go.

**From the Noise protocol framework.** A handshake with a name, `IK`,
in which each side proves a static key and both get transport keys. The
server's key is known in advance, from `ndb`, the way an SSH host key is.
`core:crypto` ships it, with argon2id, X25519, ChaCha20-Poly1305, SHA-256
and HKDF beside it, so nothing is ported and nothing is invented.

**From SSH, one thing.** A user is a key pair, and the server holds a
list of public keys. Not the protocol, which carries bytes rather than
files and composes with nothing.

**Kept as it is.** The wire, the namespace, `/srv`, `/proc`, the draw
protocol, and the fault rule. Nothing below this document changes for a
machine that never joins a network.

**Not taken.** NFS, SSH, X11, Kerberos as a system, containers and their
orchestrators, and a cluster scheduler. Section 2 says what each got
wrong.

## 2. The models this refuses, and what each got wrong

**NFS.** A file protocol beside the operating system's own, with a
server that must forget its clients and clients that must guess. A
namespace was never part of it, so a mount is the machine's and not the
process's. Here there is one file protocol, and it is the one every
local device already speaks.

**SSH.** A terminal is bytes on a stream, so a remote program has a
console and nothing else. Every other resource it wants is a special
case, port forwarding, agent forwarding, X forwarding, each a feature
because the model could not compose. `cpu` gives a remote program the
terminal's whole `/dev` as files, and a program that wants the mouse
opens it.

**X11.** A display protocol as a thing apart from files. Its server is not
a file server, and its client library is not a file library. The draw
server here is a directory. A program on another machine writes verbs into
it through a mount, and nothing else exists to make that work.

**Kerberos.** The right idea, an agent that holds keys and tickets that
prove them. It comes wrapped in a realm, a database and a protocol suite
of their own. `factotum` is that idea as a file server with two files. The
keys here are public keys rather than tickets, which removes the ticket
server, and section 4 says what that costs.

**Containers and orchestrators.** A namespace per process was missing from
the operating system, so it was rebuilt above it in a hundred thousand
lines. An image format, a registry and a scheduler came with the rebuild,
to manage it. This tree has the namespace. A job on a fleet is a shell
script that runs `cpu`, and section 7 shows one.

**A cluster scheduler.** Plan 9 never had one, and a homelab of four
machines does not need one. A queue is a directory and a worker is a
loop. The day a fleet has a hundred machines is the day this is
revisited, and the reversal is named in section 9.

## 3. The network as files

`servers/netfs` is an empty directory, and was one at the first commit. It
becomes `/net`, Plan 9's file set, on a driver that serves an `ether`
directory.

    /net/ether0/       the card: clone, addr, stats, and a directory per
                       open conversation, with data and ctl
    /net/ipifc/        the interfaces: clone, and a directory per one
    /net/arp           the table, readable and writable
    /net/iproute       the routes
    /net/tcp/clone     read it for a new conversation's number
    /net/tcp/N/ctl     connect addr!port, announce port, hangup
    /net/tcp/N/data    the bytes
    /net/tcp/N/listen  read it, and it answers a new conversation's
                       directory when a connection arrives
    /net/tcp/N/local   this end
    /net/tcp/N/remote  the far end
    /net/tcp/N/status  the state
    /net/udp/          the same shape, a datagram per read and write
    /net/cs            write a dial string, read the addresses to try
    /net/dns           write a name, read the records
    /net/ndb           what this machine knows about itself

**The driver.** `servers/etherfs` over `virtio-net` on QEMU, on the PCI
code `docs/DISK.md` already has, and over the board's PCIe card as
`docs/HARDWARE.md` section 9 plans. A packet is a read of the
conversation's `data`, whole.

**The stack.** IPv4, ARP, ICMP, UDP and TCP, as one `libthread` program.
A proc reads the card, a proc runs the timers, and one proc of threads
owns every conversation, so the stack holds no lock. TCP is the size of
the step, about two thousand lines for congestion control, retransmit
and the window. IPv6 waits for a homelab that has it.

**`cs`, and `ndb`.** `servers/cs` serves `/net/cs`. A program writes
`tcp!fs!9fs` and reads `/net/tcp/clone 10.0.0.2!564`. The name comes
from `/lib/ndb/local`, a text file of attribute lists as 9front keeps
it, and the service name from `/lib/ndb/common`. `sys/libndb` reads the
file and answers a query, and `cs` and `dns` are its two callers.

    sys=fs ip=10.0.0.2 ether=525400123456
        fs=fs auth=fs
        cputype=amd64
    sys=big ip=10.0.0.3
        cpu=
        cputype=arm64
    sys=desk ip=10.0.0.4
        terminal=
        cputype=amd64

**DHCP and DNS.** `cmd/ipconfig` asks for an address on an interface and
writes it into `/net/ipifc` and `/net/ndb`. A machine whose router hands
out addresses then needs no line in `ndb`. `servers/dns` serves `/net/dns`
and asks the servers `ipconfig` learned. Both are clients of `/net/udp`
and nothing else.

**`sys/libnet`.** `dial(addr)` writes `cs`, walks the addresses, and
answers a descriptor on `data`. `announce(addr)` and `listen(conv)` are
the server side, and `accept` and `reject` finish it. Plan 9's five
calls, over the files above, in a page.

**The bench is two machines on one laptop.** `build.odin` grows a `fleet`
target. It boots two QEMU machines, of two architectures, with a socket
network between them and a user-mode network to the host on each. The
serial lines go to files, and a host script drives both shells. Every
check in this document runs there before it runs on a board.

Proves: two machines of two architectures ping each other by name. One
announces, the other dials, and a line crosses. `ipconfig` gets an
address from QEMU's router.

## 4. Users, and proving one

There is one user, `glenda`, and uid zero on the wire. Every file is
hers, and any process may stop any other, which `docs/PROC.md` and
`docs/PROCS.md` both say is true until processes have owners. On one
machine that was a fair reading of a hobby kernel. On a network it means
anyone who reaches a port owns every file and every process in the
house.

**A user is a name and a key pair.** The private key is derived from a
passphrase with argon2id, salted with the user's name and the fleet's
domain, so it lives nowhere. A user types the passphrase once, into
`factotum`, at the start of a session. The public key is in
`/adm/keys` on the file server, one line per user, and that file is the
whole user database. `/adm/users` names the groups.

    glenda  d4f1...  adm sys
    jkane   9a0c...  sys

**A host is a user too.** Each machine has a host owner, `#c/hostowner`,
and a host key. A machine with a disk keeps the key in `/adm/hostkey`. A
diskless one derives it from a passphrase typed at boot, which is what a
Plan 9 terminal did. The public half is the host's line in `ndb`, `key=`,
and that is the trust root. A client dials a host whose key it knows,
and a server names a client by a key it finds in `/adm/keys`.

**The handshake is Noise `IK`.** The client knows the server's static key
from `ndb`, sends its own under encryption in the first message, and the
second message completes it. Both sides then hold transport keys and a
name for the other. Three round trips, one of them the TCP one. A server
that cannot find the client's key in `/adm/keys` names the client `none`.
A service decides what `none` may have, as Plan 9's file servers do.

**The conversation happens before 9P, on the raw stream.** Plan 9's
`exportfs -a` and `cpu` did the same. `sys/libauth` has two calls,
`auth_client(fd, host)` and `auth_server(fd)`. Each runs the handshake
through `factotum` and answers the far side's name and a new descriptor.
The new descriptor is a pipe, and behind it two procs from the library
carry frames between the pipe and the connection under ChaCha20-Poly1305.

Every stream in this document is sealed that way, so a file's contents
cross the LAN encrypted and a passphrase never crosses it at all. The
price is a copy per frame, in a process. Section 10 says what would
reverse that.

**`factotum` is a file server with two files.** `servers/factotum` posts
`/srv/factotum`, mounted at `/mnt/factotum`. A key is a line written to
`ctl`, `key proto=noise user=glenda dom=home !passphrase=...`. The private
key is derived on that write and the passphrase forgotten.

A handshake is a conversation on `rpc`. The library writes what arrived
and reads what to send, so the library holds no key and a program holds
nothing. `factotum` is per user, started when a session starts, and a
child inherits the mount as it inherits everything.

**What the kernel learns.** A process has a user, set at boot to the host
owner. Only a write to `/proc/n/ctl` changes it, with `auth_server`'s
answer, and only the host owner's processes may write it. `/dev/ user`
reads it. `rfork` and `exec` keep it. A note, a `kill` and a `stop` check
it, and `docs/PROC.md`'s line that says there are no owners retires.
`Tattach` carries the name it always has, and the kernel's `mnt` sets it
from the process rather than from a constant.

**What the file system learns.** `kfs` grows owners, groups, modes that
mean something, and dates, which `docs/KFS.md` lists as what is not
there. A `Tattach` from `exportfs` names the user the handshake proved,
and the server checks every open against the mode.

**Enrolment.** `auth/newuser name` appends a line to `/adm/keys`, an
ordinary write that the mode restricts to `adm`. The build stages the
first user's line, the way it stages `/lib/init`, so a fresh file server
knows its owner. `auth/passwd` derives a new key and rewrites the line.

Proves: a mount from `desk` to `fs` attaches as `jkane`, and a file made
0600 by `glenda` refuses to open. A dial from a host whose key `ndb`
does not know is refused before 9P starts. A `kill` from one user of
another's process answers permission denied. And one control, the
handshake skipped, so the attach names `none` and the private file
refuses.

## 5. 9P across the wire, both ways

`kernel/mnt` is the only 9P client, and it reads whatever descriptor is
posted. The wire's I/O is a pair of procedures over a chan. A posted
`/net/tcp/N/data`, or the sealed pipe in front of one, is therefore a
wire. Whether the byte reader today assumes a pipe end or any chan is the
first thing step 1 finds out. Either answer is a small change in one file.

**`srv`, the client side, in one command.**

    srv tcp!fs!9fs fs        dial, authenticate, post /srv/fs
    mount /srv/fs /n/fs      and mount it, as any posted service is
    9fs fs                   the two lines as a script, at /n/fs

**`exportfs`, the server side, as a program.** `cmd/exportfs` answers
9P for its own namespace, on `sys/lib9p`. A walk is `stat`, a read is
`pread`, a directory read is `dirread`, and every answer is a `Dir` the
tree already has. It serves the tree at `-r path`, or the whole
namespace, and it authenticates the stream first with `auth_server`.
What it exports is what its own namespace holds, so a `bind` before it
starts decides what a client sees. That is the whole access model, and
it is Plan 9's.

**`listen`, and a service per port.** `cmd/listen` announces every port
that has a script in `/rc/bin/service`, and runs the script for each
connection with the stream as descriptors zero and one. `tcp564` is
`exec exportfs -r /`. `tcp17010` is `cpu`'s server side. A new service
is a new file. The scripts run as the host owner, and the first thing
each does is `auth_server`.

**`import`, the reverse of `exportfs`.** `import big /proc /n/big/proc`
dials `big`, authenticates, asks its `exportfs` for `/proc`, and mounts
the answer. It is `srv` and `mount` with the tree chosen on the far
side, and `-a`, `-b` and `-c` are the mount's flags.

**The host is a file server too.** `tools/9pserve` on macOS, from
`docs/HARDWARE.md` step 3, serves the checkout to a board. It learns
`auth_server` in Odin, from the same library, so the host is one more
machine in `ndb` with a key.

Proves: `desk` imports `big`'s `/proc` and `ps` lists a process on the
other architecture. `big` mounts `fs` and reads a file `desk` wrote a
moment before. A `Tflush` crosses the wire and a parked read on the far
side is cancelled.

## 6. Roles, boot, and one tree for three architectures

A machine's role is its `init` script, chosen from `ndb`. The kernel and
the image are the same on every machine of an architecture.

**`/lib/init` reads the machine's line.** `terminal=` starts `kbdfs`,
`intuition` and Workbench, as `docs/INIT.md` and `docs/WORKBENCH.md`
have it. `cpu=` starts `listen`. `fs=` starts `kfs` on the disk and
`listen` with `tcp564` in front of it. A machine may be more than one.
A laptop under QEMU is a terminal and a CPU server at once, and a board
with a disk is all three.

**Root over the network.** The kernel embeds `/bin` and `/lib` from its
image, and the boot's first script runs from there before any disk. So a
diskless machine's `init` starts `etherfs`, `netfs`, `ipconfig` and
`factotum`, and dials the file server `ndb` names. It binds `/n/fs` as its
root and execs the real `init` from there.

That is Plan 9's `boot`, and the pieces are already in the image. A
machine with a disk does the same with `/srv/kfs`. `docs/BOOT.md`'s Limine
configuration carries `root=` so a machine can be told, and `ndb` says
otherwise.

**One tree, three architectures.** The file server holds a directory per
architecture, and every machine binds its own over `/bin`.

    /amd64/bin  /arm64/bin  /riscv64/bin     the compiled tools
    /rc/bin                                  the scripts, for all three
    /amd64/lib/debug ...                     the .vxd files, per arch
    /sys/src                                 the tree, for the tools
    /lib, /adm, /usr                         one of each

The kernel sets `$cputype` in `#e` at boot. `/lib/namespace` is the bind
list every process starts from, and `newns` in `sys/libuser` replays it
from the lines `ns` already prints.

    bind /$cputype/bin /bin
    bind -a /rc/bin /bin
    bind -a /$cputype/lib/debug /lib/debug
    mount /srv/factotum /mnt/factotum

`build.odin` stages `build/tree/<arch>/bin` per architecture into one
tree, so one disk image or one host directory serves the fleet. A machine
finds its own tools by its own name for itself.

**Time.** A fleet needs one clock, for `mtime` and for logs. `cmd/
timesync` reads `/dev/time` and sets it from the file server's, or from
NTP over `/net/udp`. `/dev/time` is `docs/DEVTOOLS.md` step 1's, and a
real-time clock driver feeds it on a machine that has one.

Proves: a diskless arm64 machine under QEMU boots to a shell with its root
on the amd64 machine's `kfs`, and runs `ls` from `/arm64/bin`. The amd64
machine runs `ls` from `/amd64/bin` off the same tree.

## 7. `cpu`, and the terminal that stays a terminal

`cpu -h big` runs a shell on `big` with this terminal's devices in its
namespace. It is the command Plan 9 users never gave up, and it is what
makes a fleet feel like one machine.

**The conversation.** The terminal dials `big`'s `tcp17010`, and the two
sides authenticate. The terminal then runs `exportfs` on the stream,
serving its own namespace, with itself as the 9P server. The far side
mounts that at `/mnt/term`, binds `/mnt/term/dev` before `/dev`, binds
its own `/n/fs` as before, and starts `rc` with `/mnt/term/dev/cons` as
its console. A program in that shell that opens `/dev/mouse` reads the
terminal's mouse. One that opens `/srv/draw` claims a window on the
terminal's screen through `/mnt/term/srv/draw`, and its verbs cross the
wire.

**Interrupts cross as a file.** A `^C` at the terminal posts `interrupt`
to the terminal-side `cpu`'s note group, and nothing on the terminal can
post to a process on `big`. So the terminal-side `cpu` serves one
synthetic file in what it exports, `/mnt/term/dev/cpunote`, and a proc on
the far side parks on a read of it. The note's text arrives as the read's
answer, and the far proc posts it to its own group with `notepg`. That
is a read that parks, `sys/lib9p`'s shape, and it is how Plan 9 did it.

**A window from the desktop.** Workbench's first menu grows `Shell
on...`, which lists the machines `ndb` marks `cpu=`. Picking one opens a
terminal window whose shell is a `cpu`. The window is local, and every
program in it runs on the server.

**`rx`, for one command.** `rx big mk all` is `cpu -h big -c 'mk all'`
with the terminal's descriptors for its three. A pipeline can then have a
remote stage.

**The fallback rule, stated once.** A program on a CPU server has files
and no segments. So every local-only fast path in this tree keeps its file
path whole. A library tries the segment and falls back to the file without
a word.

- `docs/DEVTOOLS.md` section 4's window store. `present` attaches the
  store when `segattach` answers, and writes the frame through `data`
  as verbs when it refuses, which it does through a mount.
- The clock. `/dev/time` is read through the mount, and the cycle
  counter is the terminal's own and never used for a remote clock.
- The GPU queue, `docs/HARDWARE.md` section 7. A directory with no
  `doorbell` a process may attach is a GPU a program cannot use, and
  the pixels are the path. That is what happens under QEMU today.
- The kernel's `/dev/fb` itself. It is the terminal's, `intuition`
  holds it, and no remote program ever needs it.

Proves: `desk` runs `cpu -h big`. A program started in that shell opens a
window on `desk`'s screen, reads its mouse, and exits on a `^C` typed at
`desk`. The process was on the other architecture. The `libapp` program of
`docs/DEVTOOLS.md` section 4 runs in the same shell with no change and
paints through the verbs.

## 8. Managing a fleet, and distributing work

Every operation on a fleet is one that exists on a machine, with a path
in front of it.

**Seeing.** `import` every machine's `/proc` under `/n/<host>/proc`,
and `ps` and `kill` take a directory argument, so `ps /n/big/proc` is
the rack. `fleet/ps` is the script that does it for every `cpu=` line in
`ndb`. `docs/DEVTOOLS.md`'s debugger attaches by path, so `attach
/n/big/proc/12` debugs a process on `big` from a window on `desk`, with
the `.vxd` from `/arm64/lib/debug`, because the engine is files.

**Sending work.** `rx` sends one command. `fleet/each cmd` runs it on
every CPU server and joins the output. `fleet/on arch cmd` picks a
machine by `cputype=`, which is how the tree builds itself. Each
architecture's bin is built on a machine of that architecture, from the
one `/sys/src`, into the one tree, in a script of ten lines.

**A queue is a directory.** `fleet/queue` is a directory on the file
server. A job is a file in it. A worker on each CPU server is a loop. It
moves a job into `running`, runs it with `rx`, and moves it into `done`
with its output beside it.

`mv` is an atomic rename on `kfs` the day `kfs` has rename, which
`docs/KFS.md` lists, and the queue is what asks for it. That is a
scheduler in a page of `rc`, and it is enough for a homelab.

**Heterogeneous means two things here.** Architecture, which the bind in
section 6 hides. And capacity, which `ndb` names in a line. A script can
then send a build to the twelve-core board and a game to the machine with
the screen. Nothing else in the fleet knows.

Proves: `fleet/each hostname` answers three names from three machines.
A job written into the queue runs on a CPU server and its output lands
in `done`. The amd64 machine builds `/arm64/bin` by sending the build to
the arm64 machine.

## 9. The order

Each step ends with a boot line on the two-machine bench, and each is
usable before the next starts. Step 0 replaces `docs/HARDWARE.md` step
3's network half, so the two documents build one stack rather than two.

### Step 0: the network

`servers/etherfs`, `servers/netfs`, `servers/cs`, `servers/dns`,
`sys/libndb`, `sys/libnet`, `cmd/ipconfig`, `build.odin`. About 7,500
lines, most of it TCP. Needs `docs/DISK.md`'s PCI code and nothing else.

Boot line: two machines of two architectures on the bench ping each
other by name, and a line crosses a TCP conversation.

### Step 1: 9P both ways

`cmd/srv`, `cmd/exportfs`, `cmd/listen`, `cmd/import`, `/rc/bin/9fs`,
`/rc/bin/service`, `kernel/mnt`, `tools/9pserve`. About 2,400 lines.
Needs step 0.

Boot line: `desk` imports `big`'s `/proc` and `ps` lists it. A flush
crosses the wire.

### Step 2: users

`kernel/user`, `kernel/procfs`, `servers/kfs`, `servers/factotum`,
`sys/libauth`, `cmd/auth`. About 3,600 lines. Needs step 1, and
`core:crypto` in a freestanding build, which is the first thing to
check.

Boot line: an attach names the user the handshake proved, a private
file refuses, and a stranger's dial is refused before 9P.

### Step 3: roles and boot

`build.odin`, `/lib/init`, `/lib/namespace`, `sys/libuser`, `cmd/
timesync`, the real-time clock. About 1,400 lines. Needs step 2.

Boot line: a diskless machine boots with its root on the other, and
each runs its own architecture's `ls` from one tree.

### Step 4: `cpu`

`cmd/cpu`, `cmd/rx`, `sys/libapp`'s fallback, Workbench's menu. About
1,200 lines. Needs step 3 and `docs/WORKBENCH.md` step 4 for the menu.

Boot line: a program on `big` opens a window on `desk` and dies of a
`^C` typed there.

### Step 5: the fleet's tools

`cmd/ps`, `cmd/kill`, `servers/dbgfs`, `/rc/bin/fleet`. About 750
lines. Needs step 4, and `docs/DEVTOOLS.md` step 5 for the debugger.

Boot line: a job in the queue runs on a CPU server, and the tree builds
one architecture's bin on a machine of that architecture.

### Deferred, with the reason written down

- **WiFi.** The board's module needs a firmware blob and a driver of
  its own, and a homelab has a cable.
- **Reconnect.** Plan 9's `aan` keeps a `cpu` session across a dropped
  connection. It is a proxy on each end, and it waits for a dropped
  connection that matters.
- **An archive.** Plan 9's `venti` kept every day's tree for ever. `kfs`
  has no snapshot. A daily `cp` to a second disk is the homelab's answer
  until a file system of this tree's own has one.
- **A scheduler.** Section 8's queue is the answer for a rack. The
  reversal is a fleet whose queue directory is the bottleneck.
- **IPv6.** When a homelab has it.

## 10. Decisions taken here, and what would reverse them

- **One file protocol, across the wire as on the machine.** The
  reversal is a file server that cannot speak it, and the answer is a
  program that translates, as Plan 9's `u9fs` did.
- **Vectra serves as well as dials.** `exportfs` is a program, not a
  kernel service, because a namespace is a process's and only a process
  can serve its own. The reversal is none.
- **A user is a key pair, and there is no ticket server.** The trust root
  is a host key in `ndb` and a key list on the file server. The cost is
  that revoking a user is editing a file on one machine. A CPU server that
  cached the list keeps trusting until it re-reads. The reversal is a
  fleet too large for one file, and it is Plan 9's `authsrv` on the same
  `factotum`.
- **The handshake is Noise `IK`, from `core:crypto`.** Not a protocol
  of this tree's own. The reversal is a primitive `core:crypto` drops,
  and the handshake names its primitives so one can move.
- **Every stream is sealed.** Authentication and encryption are one
  step because the same handshake yields both, and a homelab's LAN has
  guests on it. The price is a bridge of two procs per stream and a
  copy per frame. The reversal is a measured throughput the bridge
  halves, and the answer is an `ndb` attribute that leaves a named
  host's streams clear after authentication.
- **The conversation is before 9P, on the raw stream, never on an
  afid.** One path. The reversal is a foreign 9P client that only knows
  `Tauth`, and then `exportfs` learns to answer an afid with the same
  handshake.
- **A role is a script.** Not a kernel build, not a flag. The reversal
  is none.
- **`$cputype` chooses `/bin`, and the tree is one.** The reversal is a
  machine that cannot mount the tree, and it carries its own, which is
  what every machine does today.
- **A local-only fast path keeps its file path whole.** Section 7's
  rule. A library tries the segment and falls back without a word. The
  reversal is a device with no file path, and this tree has none.
- **Interrupts are a file the terminal serves.** Not a message on the
  wire, and not a second connection. The reversal is none.
- **The bench is QEMU, two machines, two architectures.** Every check
  here runs on a laptop before a board exists. The reversal is none.

## 11. Sizes and order of dependence

    step 0  the network    etherfs 1,200, netfs 4,000, cs 400, ndb 400,     nothing before it
                           ipconfig 500, dns 700, libnet 300
    step 1  9P both ways   srv 150, exportfs 1,200, listen 300,             step 0
                           import 200, mnt 100, 9pserve 200, tests 400
    step 2  users          kernel 400, kfs 500, factotum 1,200,             step 1
                           libauth 900, auth cmds 400, tests 200
    step 3  roles, boot    build 200, init 200, namespace 300,              step 2
                           timesync 300, rtc 200, tests 200
    step 4  cpu            cpu 800, rx 100, libapp 100, workbench 100       step 3
    step 5  fleet tools    ps kill 100, dbgfs 100, scripts 350, bench 200   step 4

Step 0 and `docs/DEVTOOLS.md` steps 0, 1 and 3 are independent of each
other and of everything here. Step 2 depends on `core:crypto` in a
freestanding build, which is checked on the first day of the step and
not the last.

## See also

- `docs/VECTRA9.md` -- the wire this crosses the network with, unchanged,
  and section 6's line about a distributed namespace, which this
  document retires.
- `docs/TRANSPORT.md` -- `kernel/mnt`, the client that reads any posted
  descriptor.
- `docs/SRV.md` and `docs/PIPE.md` -- a posted descriptor as a
  connection, which `srv` reuses.
- `docs/NAMESPACE.md` -- the per-process mount table that makes a remote
  tree one more bind.
- `docs/PROC.md` and `docs/PROCS.md` -- the one-user notes this document
  retires.
- `docs/KFS.md` -- the file system that learns owners and dates.
- `docs/INIT.md` -- the boot script a role replaces.
- `docs/HARDWARE.md` -- the board's network card, and the step this
  document takes the stack from.
- `docs/DEVTOOLS.md` -- the debugger this reaches across a mount, and
  the store this gives a fallback.
- `docs/WORKBENCH.md` -- the desktop that grows a menu of machines.
