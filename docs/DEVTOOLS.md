# Tools: one compiler, a POSIX that is a library, and a debugger that is a file server

**Written before the code.** `docs/HARDWARE.md` puts the machine under a
program. This is the plan for what a person writes that program with, and
what they look at when it is wrong. It comes after that document's board
work, and its first steps need no board. `docs/HANDOFF.md` section 6
points here.

Five claims, and the rest of this document is what each one costs:

1. A developer writes a native program in C, C++ or Odin, and it is one
   binary at one address, as every program here is.
2. POSIX is a library over this tree's calls and files, and the kernel
   never learns a POSIX call. The library exists to run LLVM's tools on
   this machine, and whether they run is its measure.
3. There is one compiler. Plan 9 wrote a C compiler per architecture, and
   this tree refuses that with the reasons in section 2.
4. A desktop program or a game is written against a library of about
   twenty calls. Under every call is a file or a segment the program can
   reach alone, so the library is a convenience and never a gate.
5. The debugger is a first-class program, in the shape of the RAD
   Debugger. The kernel's half is Plan 9's `/proc`, whole. The engine is a
   file server a shell script can drive, and the window is one client of
   it.

The audience is the same as `docs/HARDWARE.md`'s. A person who wants the
whole machine in their head. One who wants to fix their program at three
in the morning without a second machine.

**What a developer sees.** A terminal window and an editor. `pong` runs in
a window of its own after `cc -o pong pong.c -lapp`, reads the mouse,
paints a frame, and plays a sound. `db pong` stops it at `main`. A chord
opens the same process in the debugger's window, with the source, the
stack, the locals and the memory in panels. Every one of those panels is a
file under `/mnt/dbg`, and `cat` reads the same words.

## 1. What is taken, and from where

**From Plan 9.** A program is static, linked at one address, and carries
its libraries. `/proc` is the whole debugging interface. `mem` is the
address space at its own offsets, `regs` is the saved frame, and `ctl`
takes `stop`, `startstop`, `waitstop` and `hang`. `db` and `acid` were
programs over those files and nothing else. A debugger that runs over
files can debug a process on another machine through a mount. The C
library's shape is Plan 9's too, with `print`, `Bio`, `rfork`, notes and
`exits`, and section 3 keeps those names for the native library.

And APE, Plan 9's ANSI and POSIX environment, as a precedent with a lesson
in it. It was a personality layer as a library, which is the right shape.
It was also a libc of Plan 9's own, and it aged with its author's
attention. Section 8 takes the shape and not the libc.

**From LLVM.** One back end for three architectures, and three front ends
on it. Odin is one, and clang is the other two. The kernel already links
objects from both, because `clang` assembles the `.S` files and `ld.lld`
takes them beside `vectra.o`. Ring 3 speaks the platform's own calling
convention for the same reason. A C object and an Odin object linked in
one image in `docs/RUNTIME.md`'s milestone.

**From mlibc.** A C library with one directory of OS-specific code, named
`sysdeps`, and everything else portable. A dozen hobby kernels host
clang on it, and that is the measurement section 8 asks for.

**From the RAD Debugger.** Debug information is converted once, at build
time, into a flat file of sorted tables. The debugger reads that and never
reads DWARF. One program shows every view of a process, and every view is
a view of the same memory. Run everything, break anywhere, look at
anything, and the debugger follows a program into every process it
starts.

**From Handmade Hero and raylib.** A platform layer is a pixel buffer the
program owns, a sound buffer the program fills, the input since the last
frame, and a clock. That is a game's whole contract with the machine, and
raylib shows it fits in a short page of calls. Section 4 is that page.

**Not taken.** Plan 9's compilers, for section 2's reasons. Dynamic
linking, and a Linux system call table inside the kernel. `ptrace`, gdb's
remote protocol, and the Debug Adapter Protocol, each a wire where a file
would do. DWARF at run time, and a toolkit inside the game library.

## 2. The models this refuses, and what each got wrong

**Ken Thompson's compilers.** `8c`, `6c`, `5c`, `vc`, `kc` and `qc`, one
per architecture, each with a linker that did the last half of code
generation. They had a dialect of their own, an object format of their
own, and a calling convention of their own with no callee-saved register.
Nothing outside Plan 9 could link with them, so every outside program
came in through APE and a fight. They were small, and they were fast, and
they died with the attention of the people who wrote them. 9front keeps
them alive at real cost and cannot compile the world with them.

The refusal is of a private ABI and a private object format. A program
here is ELF from `ld.lld`, in the platform's convention, and a library
written in one language links from the other two.

**A kernel that speaks two languages.** FreeBSD's Linux layer and the
first Windows Subsystem for Linux put a second system call table in the
kernel. It drags the guest's shapes in with it. File descriptors with
Linux's flags, signals with Linux's delivery, `mmap` with Linux's rules,
and a futex. The kernel then has two personalities and every fix lands
twice. Here the kernel has one interface, and the personality is a
library above it that a program links or does not.

**Dynamic linking.** A loader in every process, a symbol namespace no `ls`
lists, and a library version a program discovers at start. The gain is a
shared page and a patch a program picks up without a relink. A disk and a
compiler make the relink cheap. A program that must load code it did not
link has section 11's hatch, and it is a hundred lines in a library.

**The debugger as a protocol.** `ptrace` is a system call with forty
verbs. gdb's remote protocol is a wire for serial lines, and the Debug
Adapter Protocol is JSON over a pipe to an editor. Each puts the
debugger's model in a stub and hands a client a stream. Here the kernel
serves files, an engine serves files over those, and a window reads them.
A shell script is a client too.

**DWARF in the debugger.** A tree of variable-length records, written for
a compiler to emit and not for a debugger to read at a breakpoint. Every
debugger that reads it at run time is slow at start, and RAD's answer was
to convert once. Section 6 converts once.

## 3. C and C++, on the build the tree has

Every piece of the chain exists for Odin. `build.odin` compiles a package
with `-target:freestanding_<arch>`, links it by `link_user.ld`, and
converts the ELF to a `VECTRA02` image the kernel serves from `/bin`. C
enters that chain at the object.

**The numbers, from one source.** `sys/abi/abi.odin` is where a call's
number lives, and `docs/RUNTIME.md` says why one file holds it. A C
program needs the same numbers, and a second copy is a drift. `build.odin`
generates `sys/abi/abi.h` from the Odin file before anything compiles,
and a boot check compares the two through a C program that prints them.
The header is a build product and never edited.

**`sys/libc`, the native library.** Plan 9's `libc` with ANSI C's names
where the two agree. The system calls under the names `sys/libuser` uses.
`print`, `fprint` and `Bio` for output, and `malloc` over the one heap
`sys/libuser` already has. The string, memory, character and number
routines of the freestanding C standard, and nothing POSIX. A program that
wants `open` with `O_CREAT` and `errno` links section 8's library instead.

`crt0.c` is `_start`. It takes the `abi.Args` block, runs the constructors
in `.init_array`, calls `main`, and calls `exits`.

**C++, without the two halves that need a runtime.** Constructors,
templates, classes and placement `new` work the day `crt0` runs
`.init_array`. Exceptions need `.eh_frame` and an unwinder, and
`link_user.ld` discards the section today. Run-time type information needs
`libc++abi`. Both come with the standard library in section 8, and a
native program builds with `-fno-exceptions -fno-rtti` until then. Nothing
in this tree throws.

**The build.** A `c_programs` table beside `user_programs`, one row per
program with its sources. `compile_c` runs clang with the arch's target,
`-ffreestanding -nostdinc -nostdlib -fno-pic -fno-stack-protector`,
`-fno-omit-frame-pointer`, `-O2 -g`, and `sys/libc/include` on the path.
The link and the converter are the ones Odin uses. A program can name
Odin packages and C sources in one row, and the linker takes both.

**The thread pointer.** C++'s `thread_local`, mlibc's `errno`, and any
libc's `pthread_self` want a register that names the current thread. amd64
keeps it in the FS base, arm64 in `TPIDR_EL0`, and riscv64 in `tp`. The
kernel saves and restores that one register per process on a switch,
which is about two hundred lines across the three ports. A program sets
its own on arm64 and riscv64, and amd64 needs a call, `SYS_TLS`, because
the base is a model-specific register. `link_user.ld` exports the bounds
of the initial TLS image, and `crt0` allocates a block per proc and sets
the pointer. The image format does not change.

`sys/libthread` keeps its current proc in a word in the stack segment,
the one segment `RFMEM` never shares, and `docs/THREAD.md` records the
trick. The thread pointer is the same word in a register. The library may
move to it, and nothing requires that it does.

**Frame pointers, and what Odin does.** clang keeps the frame pointer
under the flag above. Odin at `-o:speed` drops it and has no flag. So a
backtrace cannot rely on the frame chain in every program, and section 6
carries the unwind table instead. Odin emits `.debug_frame` under
`-debug` at every optimisation level, which is what the table is built
from.

**The Odin target.** A ring 3 program is `freestanding` today, and
`sys/libuser` is its operating system. `core:os`, `core:fmt`'s file
output, and `core:thread` are unusable, and the tools were written around
that. An `odin` compiler with a `vectra_amd64` target would put `core:os`
over `sys/libuser` and let a program from anywhere compile here. That is
section 9's work, because it is the same work that puts the compiler on
the machine.

Proves: a C program and a C++ program in the user suite, on three
architectures. Each opens `/dev/cons` through `sys/libc` and writes a
line. The C++ one writes it from a constructor. An Odin program calls a
C procedure and a C program calls an Odin one, in one image, and the
`abi.h` check holds.

## 4. `sys/libapp`: the platform layer, and the escape hatches

Three rungs, and a program stands on whichever it likes.

**Rung 0 is files.** `/srv/draw`'s window, with its `data` and `ctl`.
`/dev/mouse` as a line per movement. `/kbd` as a message per key, and
`/dev/scancode` under that. `/dev/audio`, `/dev/time` and `/dev/gpu`,
which are section 10's and `docs/HARDWARE.md`'s. Any language with a
`read` and a `write` has all of it.

**Rung 1 is a library per device.** `sys/libdraw` for the verbs, which
exists. `sys/libgpu` for a queue, which `docs/HARDWARE.md` section 7
plans. `sys/libmui` for gadgets, which `docs/WORKBENCH.md` section 5
plans. Each is a file's protocol as procedures, and knows nothing about
the others.

**Rung 2 is `sys/libapp`**, and it is Handmade Hero's platform layer as
a library. The program owns the pixels, and the library owns nothing the
program cannot reach.

    open(name, w, h)     a window, its store, its input files, and a clock
    frame(app)           the pixels, the seconds since the last frame, the input
    present(app, vsync)  flush the store, and wait for the vblank if asked
    sound(app, samples)  the next slice of audio, at the rate open chose
    close(app)           give it all back

    Frame.pixels         []u32, with width, height and stride
    Frame.dt             seconds since the last frame
    Frame.keys           down, pressed and released, by libkey's runes
    Frame.mouse          x, y, buttons, wheel
    Frame.pads           up to four, each sticks, triggers and buttons
    Frame.text           the runes typed since the last frame
    Frame.quit           the close gadget, or a note

A game is `open`, a loop of `frame`, `present` and `sound`, and `close`.
A tool that draws a graph is the same program with a slower loop. The
library is a `libthread` program inside. An io proc reads each input
file into a channel, and `frame` drains the channels into the record. A
program that never calls `frame` blocks nothing.

**The store is a segment, not a stream.** A window's pixels are a run of
memory `servers/intuition` holds, and a client draws today through `data`
writes the server copies into it. A full frame at 1920 by 1080 is eight
megabytes, and a copy per frame through a pipe is the whole budget. So a
window grows a `store` file, and a client attaches it with `segattach`
through the descriptor. The kernel maps the server's pages into the
client, which is the hand-on `docs/HARDWARE.md` section 13 already allows
a ring 3 server.

`present` is then one `flush` line and no copy. `libdraw` keeps the verbs
for the program that wants a rectangle filled and does not want to own
eight megabytes. And the verbs are the fallback. A window reached through
a mount refuses `segattach`, because a segment does not cross a wire.
`present` then writes the frame through `data` as verbs without a word to
the program. `docs/FLEET.md` section 7 is the rule, and `cpu` is why.

**A clock is a file and a register.** `/dev/time` reads the count of
nanoseconds since boot and, when the machine has one, the wall clock.
`open` reads it once for the rate and the epoch, and `frame` reads the
cycle counter directly after that. `rdtsc`, `cntvct_el0` and `rdtime` are
user-readable on the three architectures. A file is the calibration, and
a register is the fast path, which is the hatch's shape again.

**Sound is a file.** `/dev/audio` takes samples on `data` and a rate on
`ctl`, as Plan 9's does. QEMU's `virtio-sound` sits on the PCI code
`docs/DISK.md` already has, and the board's I2S is `docs/HARDWARE.md`
section 9's. `apps/tracker`, the empty directory `docs/HANDOFF.md` lists,
is the program the device is for. The relay clicks in that file's first
section are why the machine has a sound at all.

**The GPU is the same frame with a queue in it.** When `/dev/gpu` exists,
`open` opens it and `Frame` carries a `gpu` record from `sys/libgpu`
beside the pixels. A program submits to the queue instead of painting,
and `present` submits the frame's last command. On QEMU there is no
directory, `gpu` is nil, and the pixels are the path. A program written
against the pixels runs on both.

**The hatches, one per rung.** A program that wants raw scancodes reads
`/dev/scancode`. One that wants a draw verb the library did not wrap calls
`libdraw` on the window the library opened, because `App` carries the
descriptors. One that wants the ring itself takes `gpu.queue` and rings
the doorbell. Nothing in the library is a privilege. A program that drops
it loses convenience and keeps the files.

**Desktop programs.** A program of gadgets is a `libmui` program, and the
toolkit and the platform layer are siblings over the same window files.
A game with a settings panel opens a second window on the toolkit or
draws its own. The platform layer does not know what a gadget is, and
the toolkit does not know what a frame is.

**Both languages, one source.** The libraries are written in Odin, and
each exports its calls with C linkage. `sys/include/vectra/` holds one
header per library, written by hand, because the surfaces are small. A C
program per library links and calls every entry in the boot self-test,
which is what keeps a header honest. A header a program cannot link
against fails the boot.

Proves: a C program opens a window, paints a frame, reads the mouse the
self-test injects, plays a second of sound, and exits. The same program
in Odin. And a game in `apps/`, small enough to read, that a person can
play.

## 5. The debugger's kernel: `/proc`, whole

`docs/PROC.md` has five files and `stop` and `start`. Plan 9's `proc(3)`
has the rest, and every one of them is a table the kernel already keeps.

    /proc/n/mem       the address space, read and written at the address
                      as the offset, through the process's own tables
    /proc/n/regs      the saved frame, read and written while stopped
    /proc/n/fpregs    the floating-point state, the same way
    /proc/n/text      the program's file, for a debugger to open
    /proc/n/segment   one line per run: address, length, class, name
    /proc/n/fd        one line per descriptor: number, mode, path
    /proc/n/wait      the exit records of children, read as `await`

And `ctl` grows the words a debugger writes:

    startstop         run, and stop before the next note is delivered
    waitstop          answer when the process has stopped, and why
    hang              stop at the next `exec`, before its first instruction
    nohang            withdraw that
    startsyscall      run, and stop at the next system call, in and out
    step              run one instruction and stop
    watch addr len r|w|rw
                      stop on an access, in the debug registers

**A trap becomes a note, and a note can stop a process.** `docs/USER.md`
argues that a fault ends a program, and it still does, by a different
path. A fault posts `sys: trap: fault addr=... pc=...`, a breakpoint
instruction posts `sys: breakpoint`, and a process with `startstop` asked
parks before either is delivered. `waitstop` then answers with the text. A
process nobody asked for delivers the note, and an unhandled note ends the
program as it always has. The fault rule does not change for a program
nobody is watching.

**A breakpoint is a byte written through `mem`.** `int3` on amd64, `brk`
on arm64, `c.ebreak` on riscv64. The engine writes it, the process traps,
the note stops it, and the engine puts the original byte back and moves
the program counter. The kernel knows nothing about breakpoints. The
loader copied every text page for this process alone, so a write through
`mem` reaches no other instance.

**A step is the hardware's where it has one.** The trap flag on amd64 and
the software-step bit in `MDSCR_EL1` on arm64. Each is set in the saved
frame before `start` and cleared in the trap that follows. riscv64 has no
step in the base architecture. The engine steps it with a breakpoint on
the next instruction, which section 6's disassembly names. `watch` is the
debug registers on amd64 and the watchpoint registers on arm64, four of
each, and `Sdtrig` on riscv64 where the platform has it.

**`mem` walks the tables and never faults.** A read of an address the
process has not mapped answers an error. The copy is the one `copy_in`
already makes, from a space that is not the caller's, one page at a time.
`docs/USER.md`'s confused deputy argument holds here too. The engine asks
for bytes at an offset and the kernel decides what it may see.

**Nothing changes about who may.** There are no users, so any process may
stop and read any other, as `docs/PROC.md` says of `kill`. The day
processes have an owner, `/proc` checks it in one place.

**The kernel's own debugging stays where it is.** `lldb` over QEMU's stub
with `build/vectra.elf`, as `docs/TESTING.md` describes. Section 6 gives
the panic screen a symbol table, which is the one thing `docs/BOOT.md`
names as missing from it.

Proves: a self-test loads a program, writes a breakpoint into it through
`mem`, asks `startstop`, and reads `waitstop`. It reads the program
counter from `regs`, steps once, reads it again and finds the next
instruction, and lets the program finish. A control removes the
before-delivery check, and the program dies of its own breakpoint.

## 6. Debug information: one flat file per program, made at build time

The `.vx` image carries no symbols and never will. The information a
debugger wants is a second file beside it.

**The source is DWARF.** Odin emits it under `-debug` at any
optimisation, and clang under `-g`. Ring 3 builds gain the flag, and the
image does not grow, because the converter is what consumes the sections
and the `.vx` drops them. A `--user-debug` option to `build.odin` builds
ring 3 at `-o:none` for the day a stepped variable must not be in a
register.

**The converter is `elf_to_debug`**, beside `elf_to_image` in
`build.odin`. It reads `.debug_info`, `.debug_abbrev`, `.debug_line`,
`.debug_str`, `.debug_frame` and `.symtab`, and writes
`build/user/<name>.vxd`. The reader is a subset of DWARF 5 and refuses
what it does not know by name. A compiler that moves is then a build
failure and not a wrong answer.

**The file is tables with sorted keys**, RAD's shape:

    units       one per compilation unit: name, directory, language
    files       the source paths, by index
    procs       low, high, name, unit, and the frame rule
    lines       address to file and line, sorted by address, for both
                directions by binary search
    scopes      nested ranges, each with its variables
    vars        name, type, and a location: fbreg offset, a register,
                or an address. Anything else is `optimised away`
    types       base, pointer, array, struct with members, union, enum,
                procedure, typedef, and Odin's slice, string and map
    unwind      the CFI rows from `.debug_frame`: at this address, the
                return address and each callee-saved register are here
    dis         one line of text per instruction, from `llvm-objdump`
                at build time, so the machine never needs a decoder
    strings     one pool, every name above an offset into it

A reader on the machine opens the file, reads the table headers, and
binary-searches. It never parses. A procedure name from an address is one
search, and a backtrace is a walk of the unwind rows.

**Disassembly is a build product.** A decoder for three instruction sets
is a project, and amd64's alone is most of it. `llvm-objdump` is on the
host, and later on the machine, and its text is a table like the others.
A program with no `.vxd` reads as bytes, which is what it is.

**Where it lives.** `/lib/debug/<name>.vxd` on the disk, staged by the
build with the tools. `/bin` is served from the image and stays small.
The engine opens `text`, takes the program's name, and looks there.

**The kernel gets the same.** `build.odin` makes `vectra.vxd`, and embeds
the `procs` table alone in the kernel. The panic screen resolves its
frame's addresses through it and prints a backtrace with names. That
retires the line in `docs/BOOT.md` that says it has none.

Proves: a host test converts a fixture ELF and reads every table back.
A boot check resolves a known kernel procedure by name from the embedded
table and gets its address.

## 7. `servers/dbgfs`: the engine as a file server, and the window as one client

The engine is a `libthread` program that posts `/srv/dbg` and is mounted
at `/mnt/dbg`. It holds the `.vxd` readers, the unwinder, the expression
evaluator, and one io proc per target parked on `waitstop`.

    /mnt/dbg/ctl            attach pid | attach /n/host/proc/pid,
                            run path args..., detach n
    /mnt/dbg/N/ctl          break file:line | name | addr, delete k,
                            cont, stop, step, next, finish, until addr
    /mnt/dbg/N/status       Stopped at file:line pc=addr, and the reason
    /mnt/dbg/N/bt           one frame per line: depth, pc, name, file:line
    /mnt/dbg/N/frames/K/vars
                            the locals in frame K, one per line, typed
    /mnt/dbg/N/frames/K/regs
                            the registers as frame K saw them
    /mnt/dbg/N/breaks       the breakpoints, one per line, with hit counts
    /mnt/dbg/N/eval         write an expression, read its value
    /mnt/dbg/N/dis          the disassembly around pc, from the .vxd
    /mnt/dbg/N/mem          the process's memory, through /proc
    /mnt/dbg/N/procs        the other procs of the same program

`next` is a breakpoint at the return address and a step until the line
changes. `finish` is the breakpoint alone. `until` is a breakpoint at an
address and a `cont`. The evaluator reads `a.b[3].c`, arithmetic, casts
by a type's name, and a register by `$rip` or `$x0`. A value is text, in
the language of the unit that defined it.

**A target is a path.** `attach` takes a pid in this machine's `/proc`, or
the path of a process directory under an imported one. A process on
another machine is then a target from a window here. `docs/FLEET.md`
section 8 has the import.

**Run everything.** `run` starts the program with `hang` and attaches.
A target that spawns is caught at the child's `exec` by the same word,
and the child appears as `/mnt/dbg/M`. A note group is a program's set of
processes, and the engine follows the group. A `libthread` program's
procs are its `procs` file, and each is a target with its own stack.

**A script is a client.** The self-test is one:

```
db run /bin/debuggee
echo 'break debuggee.odin:31' > /mnt/dbg/1/ctl
echo cont > /mnt/dbg/1/ctl
cat /mnt/dbg/1/bt
echo total > /mnt/dbg/1/eval
cat /mnt/dbg/1/eval
echo next > /mnt/dbg/1/ctl
```

`tests/debuggee` is a program with a loop and a struct, and the script
knows the answers. The check compares the words.

**`cmd/db` is the line client**, for the serial line and for a person who
wants one. It is a page of commands over the files above, and every
command is one read or write. It is the client the self-test drives.

**`apps/debugger` is the window**, a `libmui` program with panels. Source
with the current line and the breakpoints in the margin, the call stack,
the locals and a watch list. Registers, memory at an address, the
disassembly, the procs, and the program's output. A chord runs, breaks,
steps over, steps in and finishes. Each panel reads a file and redraws, so
the window holds layout and nothing else. Two windows on one target agree,
because the engine holds the target.

**A target's memory is data.** The engine reads a string out of a process
by length and never by a terminator it trusts. A type from a `.vxd` bounds
every read.

Proves: the script above, run by `rc` from the boot self-test on three
architectures. And one control, the `.vxd` withheld, so `bt` answers
addresses and `vars` answers nothing.

## 8. `sys/libposix`: mlibc over the files

The purpose is narrow. `clang`, `ld.lld` and later `odin` run on this
machine, and each is a large C++ program that expects a POSIX. The
library is done when they run, and grows past that only when a program
someone wants asks it to.

**Why mlibc.** Its OS boundary is one directory, `sysdeps/vectra`, and
the rest is a libc other people maintain and test. It builds `libc++` and
`libstdc++`, which is the C++ half of section 3. musl is the alternative
with the better reputation, and its system calls are Linux's, called
directly from every corner of the source. newlib has no threads. A libc
of this tree's own is APE, and APE is the lesson.

**The mapping**, one line per shape, and the whole of the OS-specific
code:

    open, read, write, close, lseek     the calls, one to one
    stat, fstat, readdir                stat, fstat, dirread, Dir to struct stat
    fork                                rfork(RFPROC|RFFDG|RFENVG)
    execve(path, argv, envp)            envp written to /env, then exec
    waitpid                             await, the string parsed
    exit(n)                             exits, the number as text, so
                                        waitpid parses it back
    kill(pid, sig)                      the signal's name to /proc/n/note
    signal, sigaction                   notify, and a table from a note's
                                        text to a number: sys: trap is
                                        SIGSEGV, interrupt is SIGINT,
                                        kill is SIGTERM
    pthread_create                      rfork(RFPROC|RFMEM) onto a stack
                                        with a TLS block, section 3's
    mutex, cond, the futex under them   semacquire and semrelease on a
                                        word, which docs/USER.md has
    mmap anonymous, munmap              segalloc, segdetach
    mmap of a file, private             segalloc and a read
    mmap of a file, shared              refused, ENODEV
    pipe, dup, dup2, fcntl(F_DUPFD)     pipe, dup
    getcwd, chdir                       getwd, chdir
    clock_gettime, nanosleep            /dev/time, sleep in ticks
    getpid, getppid                     getpid, /proc/n/status
    isatty, tcsetattr                   /dev/consctl, rawon and rawoff
    ioctl(TIOCGWINSZ)                   the window's ctl, and ENOTTY for
                                        every other request
    socket, connect, accept             /net, when servers/netfs exists,
                                        as Plan 9's dial in the library
    getuid and its kin                  zero, there are no users
    errno                               the wire's numbers, which are
                                        Linux's, in the thread's TLS
    poll, select                        an io proc per descriptor, in the
                                        library

`docs/VECTRA9.md` chose Linux's errno values for the wire because this
library was coming. An error crosses from a 9P reply to `errno` without a
table.

**Two shapes cost more than a line, and each is named with its price.** A
shared file mapping is a page two processes see through a file, and no
server here maps a file into a client. LLVM reads its inputs through a
private mapping or a `read`, and works without the shared kind. It stays
refused until a program that cannot live without it appears.

`poll` over io procs costs a proc per descriptor, which is Plan 9's answer
and `docs/INIT.md`'s bill. `lld` and `clang` poll nothing. A kernel `poll`
waits for a program with a hundred descriptors. `docs/HANDOFF.md`'s note
that a process cannot wait on two descriptors is the same item.

**What the kernel grows.** The thread pointer, from section 3. `fd2path`
for `/proc/n/fd`, which `docs/SHELL.md` already lists. Nothing else. A
POSIX shape that needs a new call is a shape this section argues against.

**The tree a program sees is the namespace.** A port that wants `/usr/bin`
or `/tmp` gets a `bind` in the script that runs it, and no `chroot`. The
compiler's own installation is a directory the build stages, mounted where
the compiler expects it.

**The build.** mlibc builds with meson from the host, against a `vectra`
triple clang treats as generic ELF, and the objects land in
`sys/libposix/lib`. The `sysdeps` directory is this tree's and lives here.
`build.odin` gains a `posix_programs` table that links a program against
it with its own `crt0`, and section 3's link and converter do the rest.

Proves: a program per shape in `sys/libposix/tests`, each a line of the
user suite. `hello` through `printf`. `fork`, `exec` and `waitpid`
returning the number. Four threads and a mutex. A signal caught. Then
`lld` links a program on the machine, which is the first measurement,
and `clang` compiles one, which is the second.

## 9. Self-hosting, and the loop

`docs/HARDWARE.md` section 11 has the loop's first two shapes. A stick,
and then the host's tree as a mount. This adds the third. The tools run
on the machine, and the host is a monitor.

**The tools on the disk.** `clang` and `ld.lld` as `/bin/cc` and
`/bin/ld`, linked against section 8's library. `sys/libc` and
`sys/include` are staged under `/sys` where a build finds them. A C
program is edited in a window, compiled in the window, run in a window,
and opened in the debugger's. The `.vxd` converter runs on the machine
too, because it is Odin and links what every tool links.

**The Odin compiler.** It is C++ on LLVM, so it comes for the price of
section 8 plus its own OS layer. A `vectra` target in the compiler puts
`core:os` over `sys/libuser`, `core:thread` over `sys/libthread`, and
`core:time` over `/dev/time`. That target is the work section 3 named,
and it goes upstream or stays a patch this tree carries. Either way the
programs in this tree stop being `freestanding` the day it lands, and
`core:fmt` writes to a file.

**The last step is `build.odin` on the machine.** It compiles the kernel,
stages an ESP on the disk, and the machine reboots into what it built.
That is the day the host is optional, and the day this tree measures
itself the way Plan 9 did.

**What the size buys, said plainly.** LLVM is thirty million lines, and
`docs/HARDWARE.md` section 1 says why that number is the enemy. This tree
accepts exactly one thing it cannot read, and that is the compiler. It is
bearable because the compiler is a tool and not a layer of the machine.
Everything between its output and the silicon is in this tree, and a
program does not depend on the compiler at run time. There is no runtime,
no JIT and no shared library, and a program is bytes at an address.

## 10. The order

Each step ends with a boot line, and each is usable before the next
starts. Three of them need nothing before them and can proceed at once.

### Step 0: C on the build

`sys/abi/abi.h`, `sys/libc`, `build.odin`, `kernel/user`, the three
ports. About 3,300 lines.

- The header, generated and checked.
- `sys/libc` and `crt0`, with `.init_array`.
- The `c_programs` table, `compile_c`, and mixed rows.
- The thread pointer, saved on a switch, with `SYS_TLS` on amd64 and the
  TLS bounds in `link_user.ld`.
- `-debug` on every ring 3 build, for step 4.

Boot line: a C hello, a C++ hello with a constructor, and the mixed
image, on three architectures.

### Step 1: the clock, the store, and sound

`kernel/devfs`, `servers/intuition`, `kernel/drivers/sound` or a ring 3
`servers/soundfs` over `docs/HARDWARE.md`'s `mmio` when it exists. About
1,400 lines.

- `/dev/time`, nanoseconds and the counter's rate.
- A window's `store` file, attached by descriptor.
- `/dev/audio` over `virtio-sound`.

Boot line: a program attaches its window's store and paints without a
verb, and a second of samples reaches the device.

### Step 2: `sys/libapp`, and the C faces

`sys/libapp`, `sys/include/vectra`, a game in `apps/`. About 2,900
lines. Needs steps 0 and 1, and `docs/WORKBENCH.md` step 2 for the
pointer.

Boot line: the C program of section 4, the same in Odin, and the game
started and closed by the self-test.

### Step 3: `/proc`, whole

`kernel/procfs`, `kernel/user`, the three ports. About 1,900 lines.
Needs nothing before it.

Boot line: section 5's breakpoint written, hit, stepped and released.

### Step 4: debug information

`build.odin`, `sys/libdebug` for the reader, `kernel/panic.odin`. About
4,700 lines, most of it the DWARF subset. Needs step 0 for the C side.

Boot line: the kernel resolves a procedure by name from its own table,
and the panic screen prints names.

### Step 5: `dbgfs` and `db`

`servers/dbgfs`, `cmd/db`, `tests/debuggee`. About 4,700 lines. Needs
steps 3 and 4.

Boot line: the script in section 7, on three architectures.

### Step 6: the window

`apps/debugger`. About 2,500 lines. Needs step 5 and `docs/WORKBENCH.md`
step 3.

Boot line: the window opens on the debuggee, and a chord steps it. The
panels are files, so the check reads the files.

### Step 7: `sys/libposix`

`sys/libposix/sysdeps`, the build glue, the tests. About 3,700 lines of
this tree's own. Needs step 0 and the disk.

Boot line: the tests of section 8, and `lld` links a program on the
machine.

### Step 8: self-hosting

The `vectra` target in the Odin compiler, `build.odin` on the machine.
About 1,800 lines. Needs step 7, and `docs/HARDWARE.md` step 3 for a
tree that fits.

Boot line: the machine builds a kernel and boots it.

## 11. Decisions taken here, and what would reverse them

- **One compiler, three languages, three architectures.** The reversal
  is a target LLVM cannot reach, and none on this tree's list is one.
- **Static images at one address, and no dynamic linking.** The reversal
  is a program that must load code it did not link. The hatch is a
  `VECTRA02` loader in a library, which `segattach`es the file and jumps,
  in about a hundred lines and with no kernel change.
- **The ABI is the platform's, and not this tree's.** That was true
  before this document, and nothing reverses it.
- **The personality is a library, and the kernel never learns a POSIX
  call.** The reversal is a shape no library can fake at a price a
  program can pay. Section 8 names the two candidates and their prices.
- **The unwind table comes from the debug file, and the frame chain is
  the fallback.** Because Odin drops the frame pointer at speed and has
  no flag. The reversal is the flag, and then the chain is enough.
- **Debug information is a flat file made at build time, and DWARF never
  reaches the machine.** The reversal is a type the tables cannot hold,
  and the answer is one more kind in the `types` table.
- **The debugger is files, then a server over them, then a window over
  that.** The reversal is an operation that needs a round trip faster
  than a 9P message, a million single steps. The answer is a word the
  kernel's `ctl` takes, `step N` or `until`, and not a protocol.
- **Disassembly is a build product.** The reversal is code with no
  `.vxd`, which reads as bytes.
- **The library holds no privilege the program lacks.** Every call in
  `sys/libapp` is over a file or a segment the program can open itself.
  A library that needed a capability of its own would be a service, and
  a service is a directory in `/srv`.
- **The store is a segment.** Because a frame is eight megabytes and a
  pipe is not the place for it. The reversal is a client on another
  machine, and it keeps the verbs.
- **A clock is a file and a register.** The file calibrates and the
  register is read. The reversal is a machine whose counter is not
  user-readable, and it reads the file.
- **mlibc, not musl and not a libc of this tree's.** The reversal is
  mlibc unmaintained, in which case the `sysdeps` directory is the
  portable part and moves.
- **Sound before the GPU.** A sound device is a page of driver on a bus
  the tree already has. The GPU is `docs/HARDWARE.md`'s fifth step.

## 12. Sizes and order of dependence

    step 0  C on the build   abi.h 150, libc 2,500, crt0 100, build 300, tls 250    nothing before it
    step 1  clock, store     time 200, store 300, sound 900                          nothing before it
    step 2  libapp           libapp 1,200, headers 400, tests 500, a game 800        steps 0, 1
    step 3  /proc whole      procfs 900, user 600, ports 3 x 150                     nothing before it
    step 4  debug info       dwarf 3,000, writer 800, libdebug 600, panic 300        step 0
    step 5  dbgfs, db        dbgfs 3,500, db 800, debuggee 400                       steps 3, 4
    step 6  the window       debugger 2,500                                          step 5
    step 7  libposix         sysdeps 2,500, glue 400, tests 800                      step 0
    step 8  self-hosting     odin target 1,500, build 300                            step 7

Steps 0, 1 and 3 are independent. Step 4 needs only step 0's build
flag, so the debugger's line can run beside the platform layer's.

## See also

- `docs/RUNTIME.md` -- `sys/abi`, `sys/libuser`, the `VECTRA02` format
  and the user half of `build.odin`, which step 0 extends and does not
  change.
- `docs/PROC.md` -- `/proc` as it is, and the five doors step 3 widens.
- `docs/USER.md` -- the fault rule section 5 keeps, `segalloc` and
  `segattach`, and the semaphores section 8 builds a mutex on.
- `docs/THREAD.md` -- the library every program in this document is
  written on, and the private word the thread pointer may replace.
- `docs/WORKBENCH.md` -- the toolkit the debugger's window is built on,
  and the pointer the platform layer reads.
- `docs/HARDWARE.md` -- the loop this document adds a third shape to,
  the GPU the platform layer hands on, and the hand-on the store uses.
- `docs/DRAW.md` -- the window, its `data` and `ctl`, and the store the
  new file attaches.
- `docs/BOOT.md` -- the panic screen step 4 gives names to.
- `docs/STYLE.md` -- why this reads the way it does.
