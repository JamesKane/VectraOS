/*
The system call ABI -- the one file both sides of the door include.

Until this package, the call numbers lived in `kernel/user/syscall.odin` and
every program in ring 3 wrote them again as immediates. That was the honest
arrangement while every program was assembler. An assembler consumes one
copy at build time and Odin the other at run time, and nothing can share
them.

An Odin program in ring 3 ends that excuse. The kernel's dispatcher and the
userland library now read the same constants from here, so the two sides of
a system call cannot drift apart. The assembler blobs still carry their own
immediates, with the same defence as always: the checks fail loudly when a
number moves.

What belongs here is exactly what crosses the door: call numbers, the flag
words calls take, and the packings calls answer with. What does not belong
here is behaviour. This package imports nothing and decides nothing.
*/
package abi

SYS_NOP :: u64(0)
SYS_ARGS :: u64(1)
SYS_WRITE :: u64(2)
SYS_SLEEP :: u64(3)
SYS_EXIT :: u64(4)
SYS_OPEN :: u64(5)
SYS_CLOSE :: u64(6)
SYS_READ :: u64(7)
SYS_BIND :: u64(8)
SYS_SEEK :: u64(9)
SYS_SPAWN :: u64(10)
SYS_WAIT :: u64(11)
SYS_CREATE :: u64(12)
SYS_MOUNT :: u64(13)
SYS_REMOVE :: u64(14)
SYS_PIPE :: u64(15)
SYS_NOTE :: u64(16)
SYS_RFORK :: u64(17)
SYS_NOTIFY :: u64(18)
SYS_NOTED :: u64(19)
SYS_EXEC :: u64(20)
SYS_SEGATTACH :: u64(21)
SYS_SEGALLOC :: u64(22)
SYS_SEGBRK :: u64(23)
SYS_SEGDETACH :: u64(24)
SYS_NOTEPG :: u64(25)

/*
What `noted` may answer, Plan 9's numbers for Plan 9's words. NCONT resumes
the interrupted program from the frame the handler was handed. NDFLT takes
the default action, which is the death the note always was. The other two
of Plan 9's four -- NRSTR and NSAVE, for nested handling -- are refused
until something needs them.
*/
NCONT :: u64(1)
NDFLT :: u64(2)

/*
The rfork flag word, bit for bit Plan 9's, so a value from its manual means
the same thing here. The kernel refuses the bits it does not implement --
environment groups, rendezvous groups, mount restriction, dissociation --
rather than skipping them, and says which in `kernel/user/rfork.odin`.
*/
RFNAMEG :: u64(1) << 0
RFENVG :: u64(1) << 1
RFFDG :: u64(1) << 2
RFNOTEG :: u64(1) << 3
RFPROC :: u64(1) << 4
RFMEM :: u64(1) << 5
RFNOWAIT :: u64(1) << 6
RFCNAMEG :: u64(1) << 10
RFCENVG :: u64(1) << 11
RFCFDG :: u64(1) << 12
RFREND :: u64(1) << 13
RFNOMNT :: u64(1) << 14

// The flag word `segalloc` takes. `SEGSHARED` asks for Plan 9's `SG_SHARED`:
// a run every fork shares whatever its own flags say, and every exec keeps.
// Without it a run is shared under `RFMEM`, copied otherwise, and gone at
// exec, like a data segment.
SEGSHARED :: u64(1) << 0

// The open flags `open` and `create` take, as 9P2000.L carries them.
O_RDONLY :: u64(0)
O_WRONLY :: u64(1)
O_RDWR :: u64(2)
O_TRUNC :: u64(0o1000)

// What `bind` and `mount` mean by their order argument. Any other value is
// Replace, which the kernel decides rather than this file.
ORDER_REPLACE :: u64(0)
ORDER_BEFORE :: u64(1)
ORDER_AFTER :: u64(2)

// What a child may inherit, as bits `spawn` takes. Zero shares the namespace
// and copies the descriptors, which is Plan 9's default and Vectra's.
SPAWN_NS_COPY :: u64(1)
SPAWN_NS_CLEAN :: u64(2)
SPAWN_FD_CLEAN :: u64(4)

// How `pipe` packs its two descriptors into one answer: end 0 in the low
// byte, end 1 in the next. A descriptor table holds sixteen, so a byte is
// roomy.
pipe_ends :: proc "contextless" (packed: i64) -> (end0: int, end1: int) {
	return int(packed & 0xFF), int(packed >> 8 & 0xFF)
}

// -- The calls a shell needs -------------------------------------------------
//
// Added together, for `docs/SHELL.md` step 1. Every one of them is Plan 9's
// by shape, and the numbers continue the table above.

SYS_STAT :: u64(26)
SYS_FSTAT :: u64(27)
SYS_WSTAT :: u64(28)
SYS_DIRREAD :: u64(29)
SYS_DUP :: u64(30)
SYS_CHDIR :: u64(31)
SYS_GETWD :: u64(32)
SYS_PREAD :: u64(33)
SYS_PWRITE :: u64(34)
SYS_EXITS :: u64(35)
SYS_AWAIT :: u64(36)
SYS_UNMOUNT :: u64(37)
SYS_GETPID :: u64(38)
// docs/PROCS.md step 3: what a thread library needs.
SYS_RENDEZVOUS :: u64(39) // tag, value -> the partner's value
SYS_SEMACQUIRE :: u64(40) // address, block -> 1 taken, 0 not, -EINTR noted
SYS_SEMRELEASE :: u64(41) // address, count
SYS_ALARM :: u64(42) // ticks -> ticks the last alarm had left

/*
How a program receives its arguments.

The kernel writes them onto the new program's stack: the bytes of every
argument at the top, an Odin `string` per argument below them, and this
record below those. The first argument register carries the record's
address, and `libuser.args` turns it back into a slice. Plan 9 puts `argc`
and C strings there; Odin's strings carry their lengths, so the same
layout needs no walking.
*/
Args :: struct {
	count:   int,
	strings: [^]string,
}

// The most a program may be given, in bytes of argument text plus the
// records that describe them, and the most one argument may be.
ARGS_MAX :: 4096
ARG_MAX :: 1024

// The most a program may say on the way out, and `await` may answer with.
EXITS_MAX :: 64

// The longest name a `Stat` or `Dirent` carries.
NAME_MAX :: 64

/*
What `stat` answers with, in Plan 9's vocabulary.

`mode` carries the permission bits in its low nine and `DMDIR` at the top,
as Plan 9's `Dir.mode` does. `qid` is the server's name for the file. The
times are seconds. `name` is the last element of the path that was asked
about, and empty for `fstat`, which has a descriptor and no path.
*/
Stat :: struct {
	qid_path:    u64,
	qid_version: u32,
	qid_kind:    u8, // QTDIR and friends, as 9P spells them
	name_len:    u8,
	mode:        u32,
	length:      u64,
	atime:       u64,
	mtime:       u64,
	name:        [NAME_MAX]u8,
}

DMDIR :: u32(1) << 31
QTDIR :: u8(0x80)

// One directory entry, as `dirread` answers them: the qid, the kind and the
// name. Everything else about a file is one `stat` away, which is how Linux
// and 9P2000.L both draw the line.
Dirent :: struct {
	qid_path:    u64,
	qid_version: u32,
	qid_kind:    u8,
	name_len:    u8,
	name:        [NAME_MAX]u8,
}
