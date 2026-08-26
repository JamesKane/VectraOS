# Vectra9 — the message layer and the namespace model

Status: **design**, 2026-08-26. The message layer described in sections 2 to 4
is implemented in `sys/vectra9/`. The namespace model in section 5 is on paper;
it gets built when `kernel/vfs/` does. Section 7 records four decisions that
were open and are now settled, each following Plan 9.

---

## 1. What Vectra9 is

Vectra9 is the name of Vectra's file-protocol layer. The protocol it speaks is
**9P2000.L**, unmodified.

That distinction is the whole of the design. Vectra9 is a *layer* — decoded
message types, a codec, a session, a transport boundary, and the namespace those
sessions are assembled into. 9P2000.L is a *wire format* that layer happens to
serialise to when it has to. Almost everything interesting here is about the
layer; almost nothing is about the bytes.

**Every system service is a file tree behind this.** Drivers, the network stack,
graphics, IPC, thread state. Not "can be exposed as files" — *is*. A process
reads its own thread state by reading a file, and the kernel serves that file
with the same nine operations a remote disk would.

### The constraint that shapes everything else

**Nothing is added to the wire.** Vectra9 will not invent a message type, will
not add a field to an existing one, and will not negotiate a private version
string. The version is `9P2000.L` and a stock Linux `v9fs` client must be able
to mount a Vectra server.

This is a real constraint with real costs, accepted deliberately. When a driver
needs an operation that 9P does not have, the answer is a **file**, not a
message: a `ctl` file that accepts a line of text, a `status` file that renders
state on read. That is how Plan 9 got away with nine operations for twenty
years, and it is the discipline that keeps "everything is a file" from quietly
becoming "everything is a file, plus fourteen special cases".

The payoff is not interoperability for its own sake. It is that the protocol
stops being a design surface. There is no per-subsystem negotiation about what
messages it needs, because the answer is always the same nine.

### What Vectra9 is not

- **Not a filesystem.** It says nothing about how bytes reach a disk.
- **Not an RPC framework.** The operation set is fixed and small on purpose.
- **Not a security boundary by itself.** `Tauth` exists and is plumbed, but
  authentication policy is a server's business.

---

## 2. The message layer

### 2.1 Decoded messages, and a transport that is the only thing that knows
about bytes

The central type is a **decoded** message — an Odin tagged union of the fifty-odd
9P2000.L bodies. Every participant, in the kernel or out of it, produces and
consumes those. Serialisation is not part of being a server.

```
    in-kernel:   caller ── Msg ─────────────────────────▶ handler
    to userland: caller ── Msg ──▶ encode ──[bytes]──▶ decode ──▶ handler
```

A `devfs` read of `/dev/cons` builds a `Tread`, hands it to a handler, and gets
an `Rread` back — no buffer, no parse, no copy of the payload. The same handler
behind a pipe gets the identical `Tread`, because the transport decoded it back
into one before calling.

This is the point of the design. The alternative — marshal on every operation,
kernel devices included — buys one code path at the cost of two `memcpy`s and a
parse on every read of every file in the system, and in a system where *thread
state is a file* that is the syscall path. The alternative in the other
direction — a typed device vtable in the kernel and 9P only for remote servers,
which is what Plan 9 itself does — is faster still but means two interfaces that
have to be kept in step, and a server that cannot move between kernel and
userland without being rewritten.

The transport boundary is where that trade is made, once:

```odin
Handler   :: proc(server: rawptr, s: ^Session, request: ^Msg, reply: ^Msg)
Transport :: struct {
    data: rawptr,
    call: proc(data: rawptr, s: ^Session, request: ^Msg, reply: ^Msg) -> Error,
}
```

An in-process transport's `call` invokes the handler. A pipe transport's `call`
encodes, writes, reads, decodes. Neither the caller nor the handler can tell
which one it has.

### 2.2 Borrowed buffers

**A decoded message does not own its variable-length data.** Strings and byte
slices inside a `Msg` point into the buffer it was decoded from, or — for a
message built by hand — into whatever the builder owns.

```odin
msg, tag, err := vectra9.decode(wire[:n])   // msg aliases wire
// ... use msg ...
// wire may not be reused until msg is dead
```

This is the rule that makes the fast path fast: `Rread` of 4 KiB carries a
4 KiB slice, not a 4 KiB copy. It is also the rule most likely to be violated,
so it is stated in one place — here — and enforced by convention rather than by
the type system, which in Odin cannot express it.

The bounded parts are inline rather than borrowed, because 9P bounds them:
`Twalk` carries at most sixteen names (`MAX_WALK_ELEMENTS`), so the names live
in a fixed array inside the message. That is what keeps a `Msg` a stack value.

### 2.3 Sessions, fids, tags, qids

| | What it identifies | Who assigns it | Scope |
|---|---|---|---|
| **Qid** | a file, uniquely and for all time | the server | one server |
| **Fid** | a client's handle on a file | the client | one session |
| **Tag** | an outstanding request | the client | one session |
| **Session** | a conversation with one server | — | one attach tree |

A **Session** is one client's conversation with one server: a negotiated
`msize`, a fid space, a tag space, and a transport. Two processes talking to the
same server have two sessions and two fid spaces; fid 4 means different things
to each, and neither can name the other's files.

A **Qid** is `type[1] version[4] path[8]`. `path` is the server's permanent
identity for the file — two qids with the same path are the same file. `version`
changes when the contents change, which is what makes cache validation possible
and what makes a qid unsuitable as a mount-table key (see §5.3). `type` carries
`QTDIR`, `QTSYMLINK`, `QTAPPEND` and friends.

`NOFID` is `0xFFFF_FFFF`; `NOTAG` is `0xFFFF` and is legal only on `Tversion`.

### 2.4 Errors

Two error vocabularies, deliberately not merged:

- **`Error`** — the codec's own failures. Buffer too short, message type
  unknown, string length runs past the end, walk element count over the limit.
  These mean *the bytes are wrong*, and no reply can be constructed from them.
- **`Errno`** — the protocol's, carried in `Rlerror` as a numeric code. These
  mean *the request was well-formed and the answer is no*.

They are different in kind. A `Tread` on a fid that was never opened is
`Errno.EBADF` and a perfectly ordinary reply; a `Tread` whose declared size
exceeds the buffer is a transport failure and the session is suspect. Collapsing
them would make it possible to answer a corrupt message as though it had been
understood.

`Errno` values are Linux's, because 9P2000.L's are and because libposix is a
translation runtime over this. That is a wire-compatibility obligation, not an
endorsement of errno as an error model.

### 2.5 msize and iounit

`Tversion` negotiates `msize` — the largest single message either side will
send. The default is 8 KiB, two pages, matching what Linux's `v9fs` asks for.

`msize` bounds the *wire*. It does not bound an in-process call, where there is
no buffer to overflow, and a transport that never serialises may report an msize
of whatever it likes. A correct client does not care: it asks the server for the
`iounit` on open and reads in chunks no larger than that, which is the number
that was always the real limit.

---

## 3. The message table

All of 9P2000.L, in the encoding every implementation uses:
`size[4] type[1] tag[2]` then the body. `size` counts itself. Strings are
`len[2]` then bytes, never NUL-terminated. Qids are thirteen bytes. Everything
is little-endian.

| # | Message | Body |
|---:|---|---|
| 7 | `Rlerror` | `ecode[4]` |
| 8/9 | `Tstatfs` / `Rstatfs` | `fid[4]` / `type[4] bsize[4] blocks[8] bfree[8] bavail[8] files[8] ffree[8] fsid[8] namelen[4]` |
| 12/13 | `Tlopen` / `Rlopen` | `fid[4] flags[4]` / `qid[13] iounit[4]` |
| 14/15 | `Tlcreate` / `Rlcreate` | `fid[4] name[s] flags[4] mode[4] gid[4]` / `qid[13] iounit[4]` |
| 16/17 | `Tsymlink` / `Rsymlink` | `fid[4] name[s] symtgt[s] gid[4]` / `qid[13]` |
| 18/19 | `Tmknod` / `Rmknod` | `dfid[4] name[s] mode[4] major[4] minor[4] gid[4]` / `qid[13]` |
| 20/21 | `Trename` / `Rrename` | `fid[4] dfid[4] name[s]` / — |
| 22/23 | `Treadlink` / `Rreadlink` | `fid[4]` / `target[s]` |
| 24/25 | `Tgetattr` / `Rgetattr` | `fid[4] request_mask[8]` / `valid[8] qid[13]` then eighteen 4- and 8-byte fields |
| 26/27 | `Tsetattr` / `Rsetattr` | `fid[4] valid[4] mode[4] uid[4] gid[4] size[8] atime[16] mtime[16]` / — |
| 30/31 | `Txattrwalk` / `Rxattrwalk` | `fid[4] newfid[4] name[s]` / `size[8]` |
| 32/33 | `Txattrcreate` / `Rxattrcreate` | `fid[4] name[s] attr_size[8] flags[4]` / — |
| 40/41 | `Treaddir` / `Rreaddir` | `fid[4] offset[8] count[4]` / `count[4] data[count]` |
| 50/51 | `Tfsync` / `Rfsync` | `fid[4] datasync[4]` / — |
| 52/53 | `Tlock` / `Rlock` | `fid[4] type[1] flags[4] start[8] length[8] proc_id[4] client_id[s]` / `status[1]` |
| 54/55 | `Tgetlock` / `Rgetlock` | `fid[4] type[1] start[8] length[8] proc_id[4] client_id[s]` / same, as a reply |
| 70/71 | `Tlink` / `Rlink` | `dfid[4] fid[4] name[s]` / — |
| 72/73 | `Tmkdir` / `Rmkdir` | `dfid[4] name[s] mode[4] gid[4]` / `qid[13]` |
| 74/75 | `Trenameat` / `Rrenameat` | `olddirfid[4] oldname[s] newdirfid[4] newname[s]` / — |
| 76/77 | `Tunlinkat` / `Runlinkat` | `dirfid[4] name[s] flags[4]` / — |
| 100/101 | `Tversion` / `Rversion` | `msize[4] version[s]` / same |
| 102/103 | `Tauth` / `Rauth` | `afid[4] uname[s] aname[s] n_uname[4]` / `aqid[13]` |
| 104/105 | `Tattach` / `Rattach` | `fid[4] afid[4] uname[s] aname[s] n_uname[4]` / `qid[13]` |
| 108/109 | `Tflush` / `Rflush` | `oldtag[2]` / — |
| 110/111 | `Twalk` / `Rwalk` | `fid[4] newfid[4] nwname[2] nwname*(name[s])` / `nwqid[2] nwqid*(qid[13])` |
| 116/117 | `Tread` / `Rread` | `fid[4] offset[8] count[4]` / `count[4] data[count]` |
| 118/119 | `Twrite` / `Rwrite` | `fid[4] offset[8] count[4] data[count]` / `count[4]` |
| 120/121 | `Tclunk` / `Rclunk` | `fid[4]` / — |
| 122/123 | `Tremove` / `Rremove` | `fid[4]` / — |

Notably **absent**, because 9P2000.L replaced them: `Topen`, `Tcreate`, `Tstat`,
`Twstat`, `Rerror`. Anything reaching for those is speaking plain 9P2000 and
should be told so at `Tversion` time.

### 3.1 Two rules that are easy to get wrong

**`Twalk` is not "walk one path".** It walks up to sixteen elements and returns
a qid for each element it *managed* to walk. A short `Rwalk` — fewer qids than
names — is a **success** carrying a partial result, not an error, and `newfid`
is not created. Only a zero-length `Rwalk` for a non-zero-length `Twalk` is a
failure. Getting this wrong makes every "file not found" look like a protocol
error.

**`Tflush` is not a cancellation request, it is a synchronisation point.** The
server may complete the flushed request or abandon it, but it must send
`Rflush` *after* whatever it does with the original tag, and the client must not
reuse the tag until `Rflush` arrives. This is what makes a blocked read
interruptible, and it is the one part of the protocol with an ordering
requirement the scheduler will have to respect.

---

## 4. What is implemented

`sys/vectra9/` holds the message layer:

```
proto.odin     message kinds, Qid, fid/tag types, the fifty-odd bodies, Msg
codec.odin     encode and decode, over a bounds-checked cursor
errors.odin    codec Error, protocol Errno, and their names
session.odin   Session, Transport, Handler, and an in-process transport
```

It allocates nothing, it is `contextless` throughout, and it is verified at boot
by round-tripping one of every message kind through `encode` and `decode` and
comparing the result field for field.

`kernel/vfs/` holds the namespace layer that section 5 describes:

```
vfs.odin         Server, the #name device table, the one RPC helper
chan.odin        Chan, reference counting, open/read/write/stat/clone
mount.odin       the mount table, bind/unmount, union member lists
namespace.odin   Namespace, rfork semantics, teardown
walk.odin        attach, walk1, cross_mounts, `..`, resolve
readdir.odin     union directory reads and the member-index cookie
static.odin      a read-only server over a node table -- and its fid table
root.odin        `#/`, an instance of that server, and the boot namespace
verify.odin      the boot self-test: 51 checks against two real servers
```

Unlike `sys/vectra9/`, this layer allocates: chans, mount points and fid tables
all come from the heap, so it comes up after `mem.init`. The boot self-test is
bracketed by heap statistics and fails if the count of live objects is not
exactly where it started -- a leaked chan is a fid the server never gets back,
and it is not the kind of bug that announces itself.

---

## 5. The namespace model

Built. `kernel/vfs/` is this section; where the two disagree, the code is
right and this is stale. Two things below the sketch level turned out to
matter enough to record, and both are called out where they arise: `Chan`
carries a `union_head` the sketch does not have (5.6), and `bind` resolves its
target one step short of what is mounted there (5.3).

### 5.1 The shape of the idea

A **namespace** is a private, per-process mapping from names to files. Not a
view of a global tree with permissions on it — there is no global tree. Two
processes on the same machine can each have a `/dev/mouse` and they can be
different files served by different servers, and neither is more real than the
other.

That is the Plan 9 idea, and it is what "modular operating system" means here in
concrete terms: a service is swapped by rebinding a name, not by changing a
subsystem. Testing the network stack means running the real one and binding a
fake `/net` over it in one process.

### 5.2 Chan

A **Chan** is a handle on a file *in a namespace* — as opposed to a fid, which
is a handle on a file in a session.

```odin
Chan :: struct {
    session: ^Session,     // who serves this file
    fid:     Fid,          // the handle within that session
    qid:     Qid,          // what the server calls it

    // Namespace bookkeeping, for `..` across a mount point.
    mounted_over: ^Chan,   // the chan this tree was mounted onto, if any
    tree_root:    Qid,     // the qid this session's tree is rooted at
}
```

The last two fields exist for one reason, explained in §5.5.

### 5.3 Mount points and unions

A mount point is keyed by the file being mounted **over**:

```
key = (session identity, qid.path)
```

`qid.path` and not the whole qid, because `qid.version` changes when a directory
is modified and a mount must not evaporate because someone created a file in the
directory underneath it.

Each mount point holds an **ordered list** of members:

```odin
Mount_Order :: enum { Replace, Before, After }
Mount_Flag  :: enum { Create }

Mount :: struct {
    chan:  ^Chan,          // the root of the mounted tree
    flags: bit_set[Mount_Flag],
}
```

`Replace` clears the list. `Before` pushes onto the front, `After` onto the
back. A mount point with more than one member is a **union directory**: it
presents several trees as one. `Create` marks a member as the one new files are
made in — see §7.4 for what happens when it is not the one that resolved.

**A bind resolves its target one step short.** Resolving `/dev` normally answers
with whatever is bound there, which is the one thing a caller about to change
what is bound there must not be given: the new member would be filed under a key
nothing looks up, so a second `bind -a` would nest a second union inside the
first instead of joining it, and would never be searched. Plan 9 spells the
distinction `Amount` versus `Aopen` in `namec`; Vectra spells it
`resolve_mount_point` versus `resolve`, and `bind_path` exists so that no caller
has to remember which is which.

```
    bind -a /dev/usb /dev        # after:  /dev then /dev/usb
    bind -b /tmp/bin /bin        # before: /tmp/bin then /bin

    /bin  ─┬─▶ [0] /tmp/bin      searched first
           └─▶ [1] /bin          searched second
```

### 5.4 Walking

Resolution is one step at a time, and each step does two things:

```
walk1(ns, c, name):
    for member in members(ns, c):          # c may be a mount point
        if r := session_walk(member.chan, name):
            return cross_mounts(ns, r)     # r may itself be one
    return ENOENT
```

`cross_mounts` is the second half: having arrived at a file, check whether *it*
is mounted over, and if so return the first member of that mount instead. A
walk therefore alternates between asking servers and consulting the mount table,
and a single path element can cross from one server to another.

Two consequences worth stating plainly:

- **A path can traverse several servers.** `/net/tcp/0/data` may involve the
  root server, the network server, and nothing else — or three servers, if
  someone bound a debug filter over `/net/tcp`.
- **Walk is where the namespace costs something.** Every element is a mount
  table lookup plus at least one `Twalk`. Batching — 9P allows sixteen elements
  per `Twalk` — is possible only across elements that stay within one server,
  which the walker discovers as it goes.

### 5.5 `..`, which is the hard part

Walking `..` out of the root of a mounted tree must land at the parent of the
**mount point**, not at the parent the server would name.

```
    mount /srv/net  /net
    cd /net/tcp
    cd ..            ─▶ /net        (the server would say: its own root)
    cd ..            ─▶ /           (the mount point's parent — a *different*
                                     server, which the network server has never
                                     heard of and cannot name)
```

The server physically cannot answer this. It does not know it was mounted, does
not know where, and has no name for anything above its own root. So the
namespace answers it, using the two bookkeeping fields on `Chan`: when a walk of
`..` arrives at a chan whose qid equals its `tree_root`, the walk substitutes
`mounted_over` and continues from there.

`..` at the namespace root is the root. There is no escaping upward, which is
what makes a chroot-equivalent free: a process whose root is a subtree simply
has no name for anything outside it.

### 5.6 Reading a union directory

`Treaddir` on a union concatenates its members' entries, in mount order.

**Duplicates are not filtered.** If `/tmp/bin` and `/bin` both contain `ls`,
a directory read shows `ls` twice, while *opening* `/bin/ls` gets the first.
Filtering would mean holding every name already emitted for the life of the
read, which is unbounded in the size of the directory, in the kernel, on behalf
of a client that may not care. Plan 9 made this call and it was right.

The offset is an opaque cookie, which 9P2000.L already requires — `Treaddir`
offsets must be values previously returned in an `Rreaddir` entry, never
arbitrary. So the union encodes the member index in the high bits:

```
    offset = member_index << 56 | member_offset
```

Two hundred and fifty-six members would break this, and so would a server whose
own cookies exceed 2^56. Neither is a real number; both are checked rather than
assumed, because an offset that silently wraps reads the wrong directory instead
of failing.

Finding the members at all needs one field the sketch in §5.2 does not have. By
the time a caller holds a chan on a union, `cross_mounts` has already
substituted the first member — so the key the mount point is filed under is no
longer reachable from the chan's own server and qid. `Chan.union_head` is the
pointer back, and Plan 9 keeps the same one on `Chan.umh`.

### 5.7 Lifetime and fork

A namespace is reference-counted and shared by default. Forking takes flags,
following Plan 9's `rfork`:

| Flag | Effect |
|---|---|
| *(default)* | share the parent's namespace; a later `bind` is visible to both |
| `Copy` | duplicate the mount table; both start identical and then diverge |
| `Clean` | start empty — no root, no mounts, no way to name anything |

`Clean` is the interesting one. A process with an empty namespace cannot open a
file, because there are no names. It is a sandbox with nothing to escape from,
and the parent constructs its world by binding exactly what it should have.

### 5.8 Bootstrap: how a namespace gets anything in it

Two escapes, because an empty namespace is otherwise a dead end.

**`#name` attaches a kernel-served tree directly**, bypassing the namespace.
`#c` is the console device, `#p` the process device, and so on — Plan 9's
notation, kept because the problem it solves is real: after `Clean` there is
literally no name for anything, and something has to be able to say "give me the
console device" without a path to it. Access is a privilege, and a process
without it cannot manufacture a channel out of nothing.

**`/srv` is a directory of posted channels.** A userland server writes its
channel into `/srv/net`; anyone who can see `/srv/net` can mount it. This is how
services outside the kernel become mountable without a rendezvous mechanism of
their own — the rendezvous is a file, like everything else.

### 5.9 The conventional layout

Convention, not enforcement. A process is free to build something else.

```
/           the root, usually a small in-kernel tree
/dev/       devfs      cons, null, zero, random, draw, mouse, kbd
/net/       netfs      tcp, udp, ipifc, dns
/proc/      procfs     one directory per thread: ctl, mem, regs, status, wait
/ws/        intuition  screen, palette, windows, input
/srv/       posted channels
/env/       environment variables, one file each
/mnt/       conventional mount area
```

`/ws/screen/palette` is already spoken for: `kernel/drivers/fb/palette.odin`
says the boot palette and the compositor's are the same table, and this is where
that table becomes readable.

---

## 6. Deliberately not in this design

- **Caching.** No client-side cache of file contents or of walk results. Qid
  versions make one possible later; adding it before there is a workload to
  measure would be guessing.
- **A distributed namespace.** 9P is a network protocol and Vectra9 will
  eventually be spoken over one, but nothing here assumes or provides
  transparent remote mounting yet.
- **Per-file capabilities.** Access control is Unix-shaped — uid, gid, mode —
  because 9P2000.L's `getattr`/`setattr` are. A capability model would be a
  better fit for per-process namespaces and is a much larger design.
- **Anything that would change the wire.** See §1.

## 7. Resolved: what Plan 9 does

These were open. They are not any more. Where Plan 9 has an answer, Vectra takes
it -- not out of deference, but because these are all questions Plan 9 answered
under load, twenty years ago, and the answers are in the source rather than in
folklore.

### 7.1 A fid is a number, never a pointer

An in-process session has no serialisation, so a client *could* hold a pointer
to the server's file object instead of an index into its table. Faster, and
wrong twice over.

Plan 9 does not face this question in the same shape -- its in-kernel devices
never see a fid at all, because `devmnt` is the only thing that speaks 9P -- but
its discipline settles it anyway: **in Plan 9 a fid that appears in a message is
always a number**, allocated from the mount driver's pool, and `Chan.fid` is a
`ulong`. There is no path by which a client hands the kernel a pointer.

Two reasons to keep it that way here:

- **A fid is a capability, and the table lookup is what makes it one.** A number
  validated against the server's own table can only name files that server chose
  to hand out. A pointer bypasses that check entirely, and a client that can
  forge one can name anything.
- It would make the two transports **observably different**, which is exactly
  what §2.1 promises they are not.

So: `Fid` stays `distinct u32` on both paths. The speed is not worth the
property.

### 7.2 The root is an ordinary server

Plan 9's root is `devroot` -- a real device with `rootattach`, `rootwalk`,
`rootopen` and `rootread`, reached as `#/`, holding a static table of directory
entries. It is not a special case in `namec`; it is a device like `#c` or `#e`.

Vectra does the same. The root is an in-kernel server implementing `Handler`,
with no privileges the others lack and no shortcut through the walk. The saving
from special-casing it -- one session lookup per walk from `/` -- is not worth a
second code path through the most-exercised function in the system.

### 7.3 Tflush: the server keeps a tag table, and Rflush is the barrier

Plan 9's mechanism is specific and worth copying whole.

On the **client** side, `mountio` in `devmnt.c` sends the request and, if the
process is interrupted, builds a `Tflush` and *waits for `Rflush` before
returning*. It cannot abandon the request unilaterally, because the tag is not
free until the server says so.

On the **server** side, lib9p keeps a pool of in-flight requests indexed by tag.
A `Tflush` looks up `oldtag`, marks that request flushed, and gives the server a
chance to abort it. Either way the original request's fate is decided first and
`Rflush` is sent after.

Two rules fall out, and both are in the protocol rather than in a policy:

- **`Tflush` can never be answered with an error.** It gets `Rflush` or the
  connection is broken. A server that can neither find nor abort the request
  still answers `Rflush` -- the client only needs to know the tag is free.
- **A flushed request may still be answered.** The client must tolerate the
  reply it asked to have cancelled, arriving before the `Rflush`.

**Built, in `kernel/mnt`.** The thing this was waiting for was never really the
protocol: it was a transport that can leave a request pending, which needs
threads to leave it pending *on*. `vectra9.In_Process` runs the handler on the
caller's own stack, so a client behind it has nothing outstanding to flush and
no way to send the flush if it did.

`kernel/mnt` is that transport -- a pool of in-flight requests indexed by tag, a
work queue, and worker threads -- plus both halves of the flush. Three details
are worth knowing before reading it:

- **The tag is the pool slot.** A `Tflush` names a request by tag, so the server
  has to find one by tag, so the pool *is* the tag space. A tag that is not an
  index into it names no request, which is a case the protocol requires an
  answer for rather than an error.
- **Each request's flush is preallocated above it.** A client whose request is
  stuck has to be able to send `Tflush`; if that flush competed for an ordinary
  slot, a full pool of stuck requests would leave nobody able to unstick
  anything.
- **`Rflush` is written by whoever finishes the original.** Not by the worker
  that received the `Tflush`, which would have to park to honour the ordering
  and would be a worker not serving anything. The `Tflush` records itself as
  the original's partner and returns; the ordering rule is then structural
  rather than a wait.

What is *not* built is `kernel/vfs` using it. A reply that borrows the server's
storage -- section 4's rule -- was safe because the session lock spanned the
whole exchange, and with several requests in flight it is not. That is a
property of the transport rather than of the protocol, and settling it is the
next step rather than this one.

### 7.4 Union create goes to the first member flagged Create, and stops there

`createdir` in Plan 9's `chan.c` walks the union list, takes the first mount
with `MCREATE` set, and creates there. If none has it, the error is
`Enocreate`. If the create *fails* on that member, the failure is returned --
Plan 9 does **not** fall through to the next member.

Vectra does the same, and the no-fallthrough half is the important half. Falling
through would mean a file created under `/bin` could land in any of several
trees depending on which happened to be writable that day, and the caller would
have no way to know which. A create that fails on the member the namespace
chose is a comprehensible error; a create that silently lands somewhere else is
a bug that surfaces weeks later as a file nobody can find.

If the first `Create` member being read-only is a problem, the fix is the mount
order, which is the process's own to change.
