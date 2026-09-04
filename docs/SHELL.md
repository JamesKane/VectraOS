# A command line, and a disk to keep it on

**Written before the code.** This is the plan for the next stretch: Plan 9's
shell and command set, rewritten in Odin, running in a terminal window and
on the serial line, over files that survive a reboot. It records what the
tree has, what the shell needs that the tree has not got, the order to build
it in, and what each step proves on the boot line. `docs/HANDOFF.md` section
6 points here. When a step is built, its reasoning moves to the document
beside the code, as every other subsystem's did.

## 1. What a shell needs, and what is there

`rc` is a program that reads a line, parses it, forks, arranges descriptors
and a namespace for the child, execs a program by name with arguments, and
waits for a status. Vectra has every piece of that sentence except the
arguments and the status.

| Need | What the tree has | What is missing |
|---|---|---|
| a program that runs | `spawn`, `exec`, `rfork`, `wait`, the VECTRA02 loader, `/bin` served from the image | **argv** (`exec` takes a path and nothing else), **an environment**, a status that is a string |
| files by name | the namespace, `bind`/`mount` with unions, `open`/`create`/`remove`/`seek`, 9P2000.L to every server | **`stat`/`fstat`/`wstat`** from ring 3 (the kernel has `Tgetattr` in `vfs/chan.odin` and nothing exports it), **`dirread`**, a **current directory** (every path is absolute), `dup`, `fd2path` |
| pipelines | `pipe`, `rfork` with `RFFDG`, notes | `dup` again, and `wait` that names the child that ended |
| a terminal | `/dev/cons` with a line discipline, one per window in the draw server, `apps/terminal` reading lines | the terminal spawning a shell with the window's console as its descriptors, the way `rio` does |
| a runtime for the tools | `sys/libuser` (calls, serve loop, fid table), `sys/libedit`, `vsys:vectra9` | **a heap**: every program builds with `-default-to-nil-allocator`; Odin's `core:strings`, `core:text/regex` and `[dynamic]` all want one. A buffered print. Argument parsing |
| processes as files | `note`/`notepg` by pid | **`#p`**: `/proc/n/status`, `/proc/n/ns`, `/proc/n/note`, which `ps`, `kill` and `ns` read and write |
| a disk | Limine boots from a FAT volume QEMU makes out of `build/esp` | **a block device** (no driver of any kind), **a filesystem server** over it, and the boot namespace mounting it |

The last row is the reason this plan has two halves. A shell over the
ramfs is a demo. A shell over a disk the host can also read is a
development environment: a tool is edited on the host, appears in
`build/esp/vectra/bin`, and runs in the guest without a kernel rebuild.

## 2. The order

Each step ends with a boot line, as every step before it did, and each is
usable on its own before the next starts. The kernel steps come first
because every program after them is written against their ABI.

### Step 1: the process ABI programs are written against

`kernel/user`, `sys/abi`, `sys/libuser`. About 1,500 lines in the kernel
and as many in the library.

- **`exec(path, argv)`** and **`spawn(path, flags, argv)`**. The kernel
  copies the strings onto the new program's stack in Plan 9's layout --
  `argc`, the `argv` pointers, the strings above them -- and `_start` gets
  the stack pointer. `sys/libuser` grows `args()` and every program's
  `start` signature changes once. The six servers take no arguments today
  and lose nothing.
- **`#e`, the environment device**, as Plan 9 has it: a kernel device whose
  files are variables, one environment group per process, shared or copied
  by `rfork` with `RFENVG`/`RFCENVG`, which `rfork.odin` refuses today and
  which `sys/abi` already names. `rc` keeps `$path`, `$prompt`, `$status`
  and every `x=y` there, and `env` lists it with `ls`.
- **`stat`, `fstat`, `wstat`**, over `Tgetattr`/`Tsetattr`, answering
  Plan 9's `Dir`. **`dirread`**, over the `Treaddir` the vfs already
  answers, returning `Dir`s. **`dup`**, **`chdir`** with a per-process
  current directory the walker resolves relative paths against, and
  **`fd2path`** for `pwd`. `pread`/`pwrite` fold the seek in.
- **`await`**: `wait` answers a string, `pid status`, as Plan 9's does, so
  `$status` can be `""` for success and a word otherwise. `exits(string)`
  replaces the numeric `exit` for programs, and the kernel keeps the number
  for its own self-tests.
- **A heap in ring 3.** `libuser.heap` over `segalloc`/`segbrk`: a
  first-fit allocator behind an `mem.Allocator`, installed as
  `context.allocator` by a `libuser.main` that every tool's `_start` calls.
  A buffered writer (`Biobuf`), `print`/`fprint` over `core:fmt`'s buffer
  formatting, `ARGBEGIN`-style flag parsing, `errstr` from `vectra9`'s
  errno names.

Proves: a program spawned with three arguments echoes them, changes
directory, lists it, and exits with a string its parent's `await` repeats.

**Where it stands.** Done, in two commits: the ABI, and then `#e`, which
`docs/ENV.md` describes. `tests/abi` is the program, `/bin/abitest`, and the
user suite runs it with three arguments on all three architectures. Two
details the plan did not have: the numeric
`exit` and `wait` stay for the kernel's own checks, with `exits` and `await`
beside them; and `libfmt` is a package apart from `libuser`, because
importing `core:fmt` makes the runtime emit two kilobytes of arithmetic
helpers into every program that links the importer, which the page-sized
test programs cannot afford.

### Step 2: `rc`

`apps/rc`, about 5,000 lines of Odin against 9front's 6,000 of C. A
hand-written recursive-descent parser in place of the yacc grammar; the
same tree, the same word list semantics, the same execution model.

In order, each a boot check: words and quoting, `$var` and `$#var` and
`$"var`, simple commands with `rfork`/`exec`/`await`, redirections including
`>[2=1]` and `<>`, pipelines, `;` `&` `&&` `||`, globbing over `dirread`,
`if`/`if not`/`for`/`while`/`switch`, `fn`, `.`, `~`, here documents,
backquote substitution, and the builtins: `cd`, `.`, `builtin`, `eval`,
`exec`, `exit`, `flag`, `rfork`, `shift`, `wait`, `whatis`. `rcmain` is a
file, in the image first and on the disk after step 5.

Proves: a script with a pipeline, a loop and a function runs from the boot
self-test and its output matches.

**Where it stands.** Done, as `docs/RC.md` describes, with `echo` and `cat`
from step 3 pulled forward because the pipeline check needs two ends. Not
yet: `<{cmd}`, the `` `` `` backquote, `fn#name` in `/env`, notes, and an
interactive session, which waits for step 8 to give rc a console. `await`
grew a pid of zero, any child, for `wait` with nothing named. The user
stack is sixteen pages, because a shell recursing through `core:fmt` on
four faulted, and the ring 3 heap starts at 64 KiB rather than 256,
because every fork copies it.

### Step 3: the tools

`cmd/`, one package per command, built like the six servers are. The first
set is what a shell is useless without, in rough order of need:

`echo` `cat` `ls` `pwd` `mkdir` `rm` `cp` `mv` `cmp` `wc` `tee` `tail`
`grep` `sed` `sort` `uniq` `tr` `basename` `cleanname` `test` `seq`
`sleep` `read` `bind` `mount` `unmount` `env`

`grep` and `sed` take `core:text/regex`, which is Plan 9's syntax near
enough; a `regexp(6)` port comes later if it is not. `awk`, `sam`, `ed`,
`diff`, `tar` and the rest wait for a reason. `date` waits for a clock the
kernel does not have.

Proves: each tool is one line of the boot self-test, run by `rc` against
the ramfs and the console.

**Where it stands.** Done, as `docs/CMD.md` describes: the twenty-seven
tools above, `date` excepted, each a line of `tests/tools.rc`, which `rc`
runs from the boot self-test in a `memfs` it starts and mounts itself.
`servers/memfs` is the real in-memory filesystem -- the teaching `ramfs`
keeps its name until the disk retires it. `grep` and `sed` use
`sys/libregex`, a Thompson matcher in Plan 9's dialect, rather than
`core:text/regex`, for size. The kernel grew `mkdir`, `unmount`, `/lib`
served from the image, and one program pack in place of a `#load` per
program.

### Step 4: `#p`

`kernel/procfs`, about 600 lines. `/proc/n/status` (name, pid, state, the
cells of the process record the self-test already reads), `/proc/n/ns`
(the mount table as `bind`/`mount` lines, which `ns` prints and a script
can replay), `/proc/n/note` (a write is `note`, so `kill` is `echo kill >
/proc/n/note`), `/proc/n/ctl` for `kill` and `stop`. `ps`, `kill` and `ns`
are then three tools of the ordinary kind.

**Where it stands.** Done, as `docs/PROC.md` describes, `stop` and `start`
and `args` included. The vfs mount table grew the names each bind was made
with so `ns` has something to print, `getpid` arrived so `rc` has `$pid`,
and the scheduler can park a thread from a tick, which is what a stop that
catches a program in ring 3 needs.

### Step 5: the disk

Two kernel devices and a QEMU line, about 1,500 lines.

- **`virtio-blk` over PCI**, on every board. QEMU's `virt` boards and q35
  all have a PCI bus with an ECAM window, and `-device virtio-blk-pci`
  attaches the ESP to it on all three, where today the ESP is IDE on q35
  and virtio-mmio on the boards. One transport, one driver, one line in
  `build.odin`. OVMF and its two siblings boot from virtio. The ECAM base is
  the board's, assumed the way the GIC's and the PLIC's are, until the
  device tree or the ACPI tables are read for it. Completion is polled
  first, because a request waits for its answer and nothing else is
  running, and takes an interrupt when something else needs the core.
- **`#S`**, the storage device: `/dev/sd0/data`, `/dev/sd0/ctl`, and a
  partition table read out of the MBR or the GPT into `/dev/sd0/esp` and
  its neighbours, which is `9front`'s `sd` and `disk/prep` in one.

Proves: the first 512 bytes of `/dev/sd0/data` are the FAT volume's boot
sector, and a write to a scratch region reads back after a reboot.

**Where it stands.** Done, as `docs/DISK.md` describes. `kernel/drivers/pci`
reads configuration space through the two ports on the PC and the ECAM
window on the boards; `kernel/drivers/virtio` speaks modern virtio-blk over
it, one request at a time, polled; `kernel/sd` is `#S`, a union member of
`/dev`. `build.odin` attaches the ESP and a scratch disk over
`virtio-blk-pci` on all three boards, and makes the scratch image with an
MBR so the partition path has something to read. The self-test reads `sd0`'s
boot sector, writes and reads a sector of `sd1`, and reads `sd1`'s DOS
partition through its window. The reboot half of the write proof is the
scratch image being a plain file the build leaves alone; the ESP's `vvfat`
backend is the one whose raw scratch writes do not persist, which is why the
write goes to `sd1`.

### Step 6: a filesystem the host can read

`servers/fatfs`, about 2,000 lines: 9front's `dossfs` in Odin, a 9P server
over `/dev/sd0/esp`, FAT12 through FAT32, long names, read and write. The
boot namespace mounts it at `/n/esp` and binds `/n/esp/vectra/bin` before
`/bin`. `build.odin` stages every `.vx`, `rcmain`, and `/lib` into
`build/esp/vectra/`. From here on `#b` carries only what boots the disk --
`fatfs` and `rc` -- and everything else lives in a directory on the host.

Proves: `ls /n/esp/vectra/bin` names the tools the build staged, a file
written by a tool is on the host after the machine stops, and the kernel
image is smaller than it was.

**Where it stands.** Done, as `docs/FATFS.md` describes. `servers/fatfs`
reads and writes FAT12, FAT16 and FAT32 with long names over any partition
file `#S` presents; the boot starts it, mounts `/srv/esp` at `/n/esp`, and
binds `vectra/bin` before `/bin` and `vectra/lib` before `/lib`. The build
stages every program and the library under `build/esp/vectra/` and the
kernel's pak keeps only `fatfs` and `rc`: the image went from 3.0 MB to 2.1
MB. The self-test lists forty programs off the disk and reads the test
script back byte for byte; the script writes `hello disk` into `tmp/` and
it is on the host when QEMU exits. Two things assumed `/bin` was one tree:
`create_path` now honours the union's create member, and the user suite
counts processes against the servers alive before it. `vvfat`'s partition
is type 6, so the device is `/dev/sd0/dos`; `/dev/sd0/esp` is tried first.

### Step 7: a filesystem of Vectra's own

`servers/vfs` -- the name is taken; call it `kfs` after Plan 9's -- on a
second virtio disk `build.odin` makes. FAT has no owners, no permissions,
no qid versions, and a 4 GiB file limit, and every one of those is a thing
the namespace promises. A simple on-disk shape: a superblock, a free-block
bitmap, an inode table holding `Dir`s, directory blocks of `(name, inode)`,
one level of indirection, write-through, `fsync` on `close`. About 3,000
lines, and a journal when a crash costs something. `/usr/glenda` lives
here, and `$home` points at it.

**Where it stands.** Done, as `docs/KFS.md` describes. `servers/kfs` is
the shape above -- superblock, bitmap, 1024 inodes, 4 KiB blocks, one
indirect level -- written through in the order that survives a stop
between writes, with no journal yet. The scratch disk grew to 64 MiB with
a Plan 9 partition, which kfs reams the first time and keeps after; the
boot starts it after fatfs, since it is a program on the FAT disk, and
mounts it at `/usr`; `rcmain` sets `$home` to `/usr/glenda`. The self-test
keeps a boot count in `/usr/glenda/boots` that the boot line prints and
that grew from 1 to 4 across the three boards on one image, and checks a
0600 file stats as 0600 and a qid version moves on write. Not yet: a
journal, files past 4 MiB, rename, owners, dates.

### Step 8: boot to a shell

`init`, an `rc` script on the disk, run by the kernel as the first
program: mount the disk, start the draw server, and start a terminal
window that runs `rc` with the window's console as descriptors 0, 1 and 2.
The serial line gets an `rc` of its own on `/dev/cons`. `boot complete`
becomes a prompt.

**Where it stands.** Done, as `docs/INIT.md` describes, and the plan with
it. `apps/rc/init` is the script, staged as `/lib/init`; the kernel starts
it after the last check. It starts `kbdfs` and gives the draw server the
keyboard's file to read, so the kernel's console keeps its discipline for
the serial shell `init` becomes; `apps/terminal` is a window with `rc` in
it, two pipes and a typist process. The self-test types at the window's
shell; the serial one was checked by hand, and `ps` from it shows thirteen
processes for two shells, which is the number the next document is about.

## The plan is done

Eight steps, eight commits, three boards. What the machine can do that it
could not when this was written: run a program with arguments, keep an
environment, shell a script, run twenty-seven tools off a disk the host
can read, keep a home on a disk of its own, and boot to a prompt. What it
still cannot do, in the order it should learn: wait on two things in one
process, which `docs/INIT.md`'s process count is the bill for; take a
`^C`; open a second window; and know what time it is.

## 3. Decisions taken here, and what would reverse them

- **Plan 9's ABI, not POSIX's.** `argv` on the stack, an environment that
  is a filesystem, `await` that answers a string, `rfork` flags rather than
  `fork` and `setsid`. POSIX stays a translation runtime, as
  `docs/HANDOFF.md` section 1 says it must.
- **Odin, one package per command, one binary each.** Not a busybox. The
  loader already maps whole programs cheaply, and a tool that is one file
  is a tool a person can read.
- **FAT first, then a filesystem of our own.** FAT is the bridge to the
  host and costs nothing in format design. It is not the destination,
  because it cannot keep what the namespace promises about a file.
- **Polled disk I/O first.** A request is synchronous and the machine
  waits for it; an interrupt is an optimisation to make when a second
  thread has something better to do, and the driver is written so the
  swap is one procedure.
- **No users yet.** One user, `glenda`, everywhere `Dir.uid` is asked for.
  Authentication is a later milestone with a document of its own, and
  `docs/FLEET.md` section 4 is that document.

## 4. Sizes and order of dependence

    step 1  ABI            kernel 1.5k, libuser 1.5k     nothing before it
    step 2  rc             5k                            step 1
    step 3  tools          3-4k                          step 1; each is independent
    step 4  #p             0.6k                          step 1; `ps`, `kill`, `ns` after it
    step 5  disk           1.5k                          nothing before it; can run beside 2-4
    step 6  fatfs          2k                            steps 1 and 5
    step 7  kfs            3k                            step 6, to bootstrap from
    step 8  init           0.2k                          all of it

Steps 2-4 and step 5 are independent work and can proceed in either order
or at once.

## See also

- `docs/USER.md` -- what a program may do today, which step 1 extends
- `docs/RUNTIME.md` -- `sys/libuser` and the VECTRA02 format the tools use
- `docs/NAMESPACE.md` -- the mount model the shell arranges per command
- `docs/DEVFS.md` -- the console the shell reads from, and the `ctl` convention `#e` and `#p` follow
- `docs/TESTING.md` -- what each step's boot line may and may not claim
