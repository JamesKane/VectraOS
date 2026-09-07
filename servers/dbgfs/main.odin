/*
dbgfs -- the debugger's engine, as a file server over `/proc` and the
debug files: `docs/DEVTOOLS.md` section 7, first cut.

    /mnt/dbg/ctl        attach pid | run path args... | detach n. A read
                        answers the number of the target the last word made
    /mnt/dbg/N/ctl      break file:line | name | 0xaddr, delete k, cont,
                        stop, step, next, until 0xaddr
    /mnt/dbg/N/status   one line: Stopped at file:line pc=addr in name (why),
                        Running, or Exited
    /mnt/dbg/N/bt       the frame at the counter, then every stack word that
                        lands in a procedure, marked maybe
    /mnt/dbg/N/vars     the variables visible at the counter, typed
    /mnt/dbg/N/regs     the registers, one per line
    /mnt/dbg/N/breaks   the breakpoints, with hit counts
    /mnt/dbg/N/eval     write an expression, read its value
    /mnt/dbg/N/dis      the disassembly around the counter, from the .vxd
    /mnt/dbg/N/mem      the process's memory, through /proc
    /mnt/dbg/N/procs    the processes of the target's note group

**A word that runs the target answers when it stops.** The serve loop
holds `cont`, `step`, `next`, `until`, `run` and `attach`. A proc of the
target's own writes the kernel's blocking word, `startstop`, `step` or
`waitstop`, and reports back on a channel. The thread that
reads that channel puts the stop in order and answers the held write. So
a script that writes `cont` and then reads `status` reads the stop.

**Breakpoints are bytes, planted before a run and lifted at every stop.**
The kernel knows nothing of them (`docs/PROC.md`). A stop at one leaves
the counter past the instruction on amd64 and riscv64, and the engine
puts it back. A breakpoint is the size of the instruction it replaces,
which `libdebug.break_code` chooses. A run from a breakpoint steps the
one instruction first. That is the
kernel's step where it has one, and a breakpoint on the next instruction
where it has not. Then it plants every breakpoint and goes.

**What is first cut here.** Frame zero only. `vars` are the variables at
the counter. `bt` past the first frame is the stack scanned for return
addresses, as the panic screen does. This compiler keeps no frame pointer
and emits no unwind rows, so no walk can trust a frame yet. `finish`
waits on that walk.

`next` is a step until the line changes. A frame base is the stack
pointer, which is what the compiler names for most procedures. The
`CFA-32` ones read wrong until the walk exists.
*/
package dbgfs

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libdebug"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192
MAX_TARGETS :: 8
MAX_BREAKS :: 16
OUT_MAX :: 4096
PATH_MAX :: 128

// -- The tree -------------------------------------------------------------------

NODE_ROOT :: i32(0)
NODE_CTL :: i32(1)
TARGET_BASE :: i32(16)
TARGET_STRIDE :: i32(16)

Part :: enum i32 {
	Dir    = 0,
	Ctl    = 1,
	Status = 2,
	Bt     = 3,
	Vars   = 4,
	Regs   = 5,
	Breaks = 6,
	Eval   = 7,
	Dis    = 8,
	Mem    = 9,
	Procs  = 10,
}

PART_NAMES := [Part]string {
	.Dir    = "",
	.Ctl    = "ctl",
	.Status = "status",
	.Bt     = "bt",
	.Vars   = "vars",
	.Regs   = "regs",
	.Breaks = "breaks",
	.Eval   = "eval",
	.Dis    = "dis",
	.Mem    = "mem",
	.Procs  = "procs",
}

node_of :: proc "contextless" (t: int, part: Part) -> i32 {
	return TARGET_BASE + i32(t) * TARGET_STRIDE + i32(part)
}

node_target :: proc "contextless" (node: i32) -> int {
	if node < TARGET_BASE {
		return -1
	}
	return int((node - TARGET_BASE) / TARGET_STRIDE)
}

node_part :: proc "contextless" (node: i32) -> Part {
	if node < TARGET_BASE {
		return .Dir
	}
	return Part((node - TARGET_BASE) % TARGET_STRIDE)
}

is_dir :: proc "contextless" (node: i32) -> bool {
	return node == NODE_ROOT || (node >= TARGET_BASE && node_part(node) == .Dir)
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 #no_bounds_check {
	if name == "." {
		return from
	}
	if name == ".." {
		if t := node_target(from); t >= 0 && node_part(from) != .Dir {
			return node_of(t, .Dir)
		}
		return NODE_ROOT
	}
	if from == NODE_ROOT {
		if name == "ctl" {
			return NODE_CTL
		}
		if n, ok := libuser.atoi(name); ok && n >= 1 && n <= MAX_TARGETS && targets[n - 1].used {
			return node_of(int(n - 1), .Dir)
		}
		return -1
	}
	t := node_target(from)
	if t < 0 || node_part(from) != .Dir {
		return -1
	}
	for part in Part {
		if part != .Dir && PART_NAMES[part] == name {
			return node_of(t, part)
		}
	}
	return -1
}

// -- Targets --------------------------------------------------------------------

Break :: struct {
	used:  bool,
	armed: bool,
	addr:  u64,
	orig:  [libdebug.BREAK_MAX]u8,
	size:  int, // The breakpoint's bytes, which is the instruction's
	hits:  int,
}

// What the engine is in the middle of for a target, across the stop that
// its proc reports. See `on_stop`.
Phase :: enum {
	Idle,
	Attaching, // a `waitstop` after `run` or `attach`
	Stepping, // one step, and answer
	Nexting, // steps until the line changes
	Over, // a step off a breakpoint, then a run
	Running, // a run, until a stop
	Stopping, // a `stop`, then a `waitstop`
}

// One blocking word for the target's proc, and its answer.
Ask :: struct {
	target: ^Target,
	word:   string,
	err:    i64,
}

Target :: struct {
	used:     bool,
	exited:   bool,
	stopped:  bool,
	busy:     bool, // a word is out with the target's proc
	pid:      u64,
	name:     [PATH_MAX]u8,
	name_len: int,
	group:    u64, // its note group, for `procs`
	dbg:      libdebug.Debug,
	has_dbg:  bool,
	regs:     [libdebug.FRAME_SIZE]u8,
	why:      [128]u8,
	why_len:  int,
	breaks:   [MAX_BREAKS]Break,
	temp:     u64, // a breakpoint for one run: `until`, or a step by breakpoint
	ask:      ^libthread.Chan,
	asked:    Ask,
	phase:    Phase,
	next_line: u32,
	next_steps: int,
	pending:  vectra9.Fid, // the held ctl write, answered at the stop
	has_pending: bool,
	mem_fd:   int,
	eval_out: [OUT_MAX]u8,
	eval_len: int,
	last_word: [64]u8,
	last_len: int,
}

targets: [MAX_TARGETS]Target
last_made: int = -1 // what a read of /ctl answers

stops: ^libthread.Chan // `^Ask`, from every target's proc
fids: libuser.Fid_Table
srv: lib9p.Srv

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	fd, perr := libuser.post("/srv/dbg")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	stops = libthread.chancreate(size_of(rawptr), 0)
	if stops == nil || libthread.threadcreate(stop_thread, nil) < 0 {
		libthread.threadexitsall("no thread")
	}
	srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		msize   = FRAME,
	}
	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.error_reply(vectra9.EIO))
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

// -- The target's proc -------------------------------------------------------------

// target_proc writes the blocking words for one target, and reports each
// answer on the shared channel. A proc of its own because the word parks
// the writer until the target stops.
target_proc :: proc "contextless" (arg: rawptr) {
	t := (^Target)(arg)
	for {
		a := (^Ask)(libthread.recvp(t.ask))
		a.err = ctl_write(t.pid, a.word)
		libthread.sendp(stops, a)
	}
}

// ctl_write writes one word to a process's ctl and answers the kernel's
// errno, zero for success.
ctl_write :: proc "contextless" (pid: u64, word: string) -> i64 {
	path: [64]u8
	fd := libuser.open(proc_file(path[:], pid, "ctl"), abi.O_WRONLY)
	if fd < 0 {
		return fd
	}
	n := libuser.write(int(fd), transmute([]u8)word)
	_ = libuser.close(int(fd))
	if n < 0 {
		return n
	}
	return 0
}

proc_file :: proc "contextless" (buf: []u8, pid: u64, name: string) -> string {
	sink := libodin.sink_from(buf)
	libodin.put_str(&sink, "/proc/")
	libodin.put_uint(&sink, pid)
	libodin.put_str(&sink, "/")
	libodin.put_str(&sink, name)
	return libodin.str(&sink)
}

// ask sends a blocking word to the target's proc. The stop thread hears the
// answer.
ask :: proc "contextless" (t: ^Target, word: string) {
	t.asked = Ask{target = t, word = word}
	t.busy = true
	t.stopped = false
	libthread.sendp(t.ask, &t.asked)
}

// -- Stops --------------------------------------------------------------------------

// stop_thread hears every target's proc and puts each stop in order:
// the registers read, the reason found, the breakpoints lifted, and the
// held write answered, or the next step of a plan sent.
stop_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	for {
		a := (^Ask)(libthread.recvp(stops))
		t := a.target
		t.busy = false
		on_stop(t, a.err)
	}
}

on_stop :: proc "contextless" (t: ^Target, err: i64) {
	if err != 0 {
		if err == -i64(vectra9.EIO) {
			t.exited = true
			set_why(t, "exited")
		} else {
			t.exited = true
			set_why(t, "the kernel refused the word")
		}
		lift_all(t)
		t.phase = .Idle
		answer_pending(t, 0)
		return
	}
	read_regs(t)
	t.stopped = true
	pc := libdebug.frame_pc(t.regs[:])

	note: [64]u8
	n := read_file_once(t.pid, "note", note[:])
	text := string(note[:max(n, 0)])
	hit := -1
	switch {
	case has_prefix(text, "sys: breakpoint"):
		at := pc - libdebug.BREAK_ADVANCE
		for i in 0 ..< MAX_BREAKS {
			if t.breaks[i].used && t.breaks[i].armed && t.breaks[i].addr == at {
				hit = i
			}
		}
		if hit >= 0 || (t.temp != 0 && t.temp == at) {
			pc = at
			libdebug.frame_set_pc(t.regs[:], pc)
			write_regs(t)
			if hit >= 0 {
				t.breaks[hit].hits += 1
				set_why(t, "breakpoint")
			} else {
				set_why(t, "stepped")
			}
		} else {
			set_why(t, "breakpoint, not one of ours")
		}
	case len(text) > 0:
		set_why(t, text)
	case:
		set_why(t, t.phase == .Stepping || t.phase == .Nexting || t.phase == .Over ? "stepped" : "stopped")
	}
	lift_all(t)

	// The plan: a step off a breakpoint runs on, and a `next` steps again
	// until the line moves. Everything else answers now.
	switch t.phase {
	case .Over:
		arm_all(t)
		t.phase = .Running
		ask(t, "startstop")
		return
	case .Nexting:
		_, line, ok := libdebug.line_at(&t.dbg, pc)
		if t.has_dbg && ok && line == t.next_line && t.next_steps < 200 {
			t.next_steps += 1
			step_once(t)
			return
		}
	case .Attaching:
		// The program is what it is only now. A `run` reads the target's
		// name before its exec on another core as often as after, and
		// the debug file is the program's. `hang` stopped it at that
		// exec, and nothing else it starts should stop that way, so
		// `nohang`, and the children of a watched program run.
		load_debug(t)
		_ = ctl_write(t.pid, "nohang")
	case .Idle, .Stepping, .Running, .Stopping:
	}
	t.phase = .Idle
	answer_pending(t, 0)
}

// step_once runs one instruction: the kernel's step, or a breakpoint on
// the next instruction the disassembly names and a run to it.
step_once :: proc "contextless" (t: ^Target) {
	when libdebug.HAS_STEP {
		ask(t, "step")
	} else {
		pc := libdebug.frame_pc(t.regs[:])
		if next, ok := libdebug.dis_next(&t.dbg, pc); t.has_dbg && ok {
			t.temp = next
			temp_size = plant(t, next, nil)
			ask(t, "startstop")
		} else {
			// No disassembly to step by. The stop this answers with says so.
			set_why(t, "no step on this architecture without a dis table")
			t.phase = .Idle
			t.stopped = true
			answer_pending(t, i64(vectra9.EOPNOTSUPP))
		}
	}
}

// answer_pending answers the ctl write a stop was for, if one waits.
answer_pending :: proc "contextless" (t: ^Target, err: i64) {
	if !t.has_pending {
		return
	}
	req, ok := lib9p.held(&srv, t, wants_pending)
	t.has_pending = false
	if !ok {
		return
	}
	if err != 0 {
		_ = lib9p.respond(req, vectra9.error_reply(vectra9.Errno(err)))
		return
	}
	m := req.msg.(vectra9.Twrite)
	_ = lib9p.respond(req, vectra9.Rwrite{count = u32(len(m.data))})
}

wants_pending :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	t := (^Target)(arg)
	#partial switch m in request^ {
	case vectra9.Twrite:
		return m.fid == t.pending
	}
	return false
}

set_why :: proc "contextless" (t: ^Target, why: string) {
	t.why_len = copy(t.why[:], why)
}

// -- Reading and writing the target ------------------------------------------------

read_file_once :: proc "contextless" (pid: u64, name: string, into: []u8) -> int {
	path: [64]u8
	fd := libuser.open(proc_file(path[:], pid, name), abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	n := libuser.read(int(fd), into)
	_ = libuser.close(int(fd))
	return int(n)
}

read_regs :: proc "contextless" (t: ^Target) -> bool {
	path: [64]u8
	fd := libuser.open(proc_file(path[:], t.pid, "regs"), abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	n := libuser.pread(int(fd), t.regs[:], 0)
	_ = libuser.close(int(fd))
	return n == i64(len(t.regs))
}

write_regs :: proc "contextless" (t: ^Target) -> bool {
	path: [64]u8
	fd := libuser.open(proc_file(path[:], t.pid, "regs"), abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	n := libuser.pwrite(int(fd), t.regs[:], 0)
	_ = libuser.close(int(fd))
	return n == i64(len(t.regs))
}

read_mem :: proc "contextless" (t: ^Target, addr: u64, into: []u8) -> int {
	if t.mem_fd < 0 {
		return -1
	}
	return int(libuser.pread(t.mem_fd, into, addr))
}

write_mem :: proc "contextless" (t: ^Target, addr: u64, data: []u8) -> int {
	if t.mem_fd < 0 {
		return -1
	}
	return int(libuser.pwrite(t.mem_fd, data, addr))
}

// plant writes the breakpoint bytes at `addr`, keeping the bytes there in
// `orig` when a caller gives one. A temporary breakpoint keeps its bytes
// in the target record.
temp_orig: [libdebug.BREAK_MAX]u8
temp_size: int

// plant writes a breakpoint at `addr`, keeping the bytes it replaces in
// `orig`, and answers how many: the instruction's own size, so the next
// instruction is left whole. Zero when the write did not land.
plant :: proc "contextless" (t: ^Target, addr: u64, orig: []u8) -> int {
	keep := orig
	if keep == nil {
		keep = temp_orig[:]
	}
	first: [1]u8
	if read_mem(t, addr, first[:]) != 1 {
		return 0
	}
	code := libdebug.break_code(first[0])
	if read_mem(t, addr, keep[:len(code)]) != len(code) {
		return 0
	}
	if write_mem(t, addr, code) != len(code) {
		return 0
	}
	// Read back, so a write the kernel took and did not land is a refusal
	// here and not a run that never stops.
	back: [libdebug.BREAK_MAX]u8
	if read_mem(t, addr, back[:len(code)]) != len(code) {
		return 0
	}
	for i in 0 ..< len(code) {
		if back[i] != code[i] {
			return 0
		}
	}
	return len(code)
}

lift :: proc "contextless" (t: ^Target, addr: u64, orig: []u8, size: int) {
	_ = write_mem(t, addr, orig[:size])
}

arm_all :: proc "contextless" (t: ^Target) {
	for i in 0 ..< MAX_BREAKS {
		b := &t.breaks[i]
		if b.used && !b.armed {
			b.size = plant(t, b.addr, b.orig[:])
			b.armed = b.size > 0
			if !b.armed {
				set_why(t, "a breakpoint would not plant")
			}
		}
	}
}

lift_all :: proc "contextless" (t: ^Target) {
	if t.exited {
		for i in 0 ..< MAX_BREAKS {
			t.breaks[i].armed = false
		}
		t.temp = 0
		return
	}
	for i in 0 ..< MAX_BREAKS {
		b := &t.breaks[i]
		if b.used && b.armed {
			lift(t, b.addr, b.orig[:], b.size)
			b.armed = false
		}
	}
	if t.temp != 0 {
		lift(t, t.temp, temp_orig[:], temp_size)
		t.temp = 0
	}
}

// resume runs the target: off a breakpoint by one step first, then with
// every breakpoint planted.
resume :: proc "contextless" (t: ^Target) {
	pc := libdebug.frame_pc(t.regs[:])
	for i in 0 ..< MAX_BREAKS {
		if t.breaks[i].used && t.breaks[i].addr == pc {
			t.phase = .Over
			step_once(t)
			return
		}
	}
	arm_all(t)
	t.phase = .Running
	ask(t, "startstop")
}

// -- Attaching ----------------------------------------------------------------------

// load_debug opens the target's debug file by its program's name, if the
// build staged one.
load_debug :: proc "contextless" (t: ^Target) {
	status: [512]u8
	n := read_file_once(t.pid, "status", status[:])
	if n <= 0 {
		return
	}
	text := string(status[:n])
	name := text
	for i in 0 ..< len(text) {
		if text[i] == ' ' {
			name = text[:i]
			break
		}
	}
	t.name_len = copy(t.name[:], name)
	// The note group is the fifth field.
	fields: [8]string
	nf := split_fields(text, fields[:])
	if nf >= 5 {
		if g, ok := libuser.atoi(fields[4]); ok {
			t.group = u64(g)
		}
	}
	path: [PATH_MAX]u8
	vxd := libuser.cat_into(path[:], "/lib/debug/", libuser.basename(name), ".vxd")
	data := load_file(vxd)
	if data == nil {
		return
	}
	d, ok := libdebug.open(data)
	if !ok {
		libuser.heap_free(raw_data(data))
		return
	}
	t.dbg = d
	t.has_dbg = true
}

// load_file reads a whole file onto the heap, sized by its stat.
load_file :: proc "contextless" (path: string) -> []u8 {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return nil
	}
	defer libuser.close(int(fd))
	st: abi.Stat
	if libuser.fstat(int(fd), &st) != 0 || st.length == 0 || st.length > 32 << 20 {
		return nil
	}
	size := int(st.length)
	block := libuser.heap_alloc(size)
	if block == nil {
		return nil
	}
	data := ([^]u8)(block)[:size]
	at := 0
	for at < size {
		n := libuser.read(int(fd), data[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	if at != size {
		libuser.heap_free(block)
		return nil
	}
	return data
}

new_target :: proc "contextless" (pid: u64) -> ^Target {
	for i in 0 ..< MAX_TARGETS {
		t := &targets[i]
		if t.used {
			continue
		}
		t^ = {}
		t.used = true
		t.pid = pid
		t.mem_fd = -1
		t.ask = libthread.chancreate(size_of(rawptr), 0)
		if t.ask == nil || libthread.proccreate(target_proc, t) < 0 {
			t.used = false
			return nil
		}
		path: [64]u8
		t.mem_fd = int(libuser.open(proc_file(path[:], pid, "mem"), abi.O_RDWR))
		last_made = i
		return t
	}
	return nil
}

release_target :: proc "contextless" (t: ^Target) {
	if !t.exited && t.stopped {
		lift_all(t)
		_ = ctl_write(t.pid, "start")
	}
	if t.mem_fd >= 0 {
		_ = libuser.close(t.mem_fd)
	}
	if t.has_dbg {
		libuser.heap_free(raw_data(t.dbg.data))
	}
	// The proc stays parked on its channel. A target slot reused sends it
	// the next word.
	t.used = false
}

/*
run_program forks, arms the child to stop at its exec, and execs. The
child is a copy of this server up to the exec. It makes three calls in
it: its own ctl, the path, and the program. The pid comes back to the
parent, which attaches and waits for the stop at the entry.
*/
run_program :: proc "contextless" (argv: []string) -> (pid: u64, ok: bool) {
	if len(argv) == 0 {
		return 0, false
	}
	child := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOTEG)
	if child < 0 {
		return 0, false
	}
	if child == 0 {
		me := libuser.getpid()
		_ = ctl_write(me, "hang")
		_ = libuser.exec(argv[0], argv)
		libuser.exits("exec")
	}
	return u64(child), true
}

// -- The words ------------------------------------------------------------------------

// root_ctl takes a word for the server: attach, run, detach. The words
// that wait for a stop hold the request and answer it there.
root_ctl :: proc "contextless" (fid: vectra9.Fid, text: string) -> (errno: vectra9.Errno, hold: bool) {
	words: [16]string
	n := split_fields(text, words[:])
	if n == 0 {
		return vectra9.EINVAL, false
	}
	switch words[0] {
	case "attach":
		if n < 2 {
			return vectra9.EINVAL, false
		}
		pid, pok := libuser.atoi(words[1])
		if !pok {
			return vectra9.EINVAL, false
		}
		t := new_target(u64(pid))
		if t == nil {
			return vectra9.ENOMEM, false
		}
		_ = ctl_write(t.pid, "stop")
		t.phase = .Attaching
		t.pending = fid
		t.has_pending = true
		ask(t, "waitstop")
		return vectra9.Errno(0), true
	case "run":
		if n < 2 {
			return vectra9.EINVAL, false
		}
		pid, rok := run_program(words[1:n])
		if !rok {
			return vectra9.EIO, false
		}
		t := new_target(pid)
		if t == nil {
			return vectra9.ENOMEM, false
		}
		t.phase = .Attaching
		t.pending = fid
		t.has_pending = true
		ask(t, "waitstop")
		return vectra9.Errno(0), true
	case "detach":
		if n < 2 {
			return vectra9.EINVAL, false
		}
		i, iok := libuser.atoi(words[1])
		if !iok || i < 1 || i > MAX_TARGETS || !targets[i - 1].used {
			return vectra9.ENOENT, false
		}
		release_target(&targets[i - 1])
		return vectra9.Errno(0), false
	}
	return vectra9.EINVAL, false
}

// target_ctl takes a word for one target.
target_ctl :: proc "contextless" (t: ^Target, fid: vectra9.Fid, text: string) -> (errno: vectra9.Errno, hold: bool) {
	words: [8]string
	n := split_fields(text, words[:])
	if n == 0 {
		return vectra9.EINVAL, false
	}
	if t.exited {
		return vectra9.ESRCH, false
	}
	if t.busy {
		return vectra9.EBUSY, false
	}
	switch words[0] {
	case "break":
		if n < 2 {
			return vectra9.EINVAL, false
		}
		addr, aok := resolve_place(t, words[1])
		if !aok {
			return vectra9.ENOENT, false
		}
		for i in 0 ..< MAX_BREAKS {
			if !t.breaks[i].used {
				t.breaks[i] = Break{used = true, addr = addr}
				return vectra9.Errno(0), false
			}
		}
		return vectra9.ENOMEM, false
	case "delete":
		if n < 2 {
			return vectra9.EINVAL, false
		}
		k, kok := libuser.atoi(words[1])
		if !kok || k < 0 || k >= MAX_BREAKS || !t.breaks[k].used {
			return vectra9.ENOENT, false
		}
		if t.breaks[k].armed {
			lift(t, t.breaks[k].addr, t.breaks[k].orig[:], t.breaks[k].size)
		}
		t.breaks[k].used = false
		return vectra9.Errno(0), false
	case "cont":
		if !t.stopped {
			return vectra9.EBUSY, false
		}
		t.pending = fid
		t.has_pending = true
		resume(t)
		return vectra9.Errno(0), true
	case "stop":
		if t.stopped {
			return vectra9.Errno(0), false
		}
		_ = ctl_write(t.pid, "stop")
		t.phase = .Stopping
		t.pending = fid
		t.has_pending = true
		ask(t, "waitstop")
		return vectra9.Errno(0), true
	case "step":
		if !t.stopped {
			return vectra9.EBUSY, false
		}
		t.phase = .Stepping
		t.pending = fid
		t.has_pending = true
		step_once(t)
		return vectra9.Errno(0), true
	case "next":
		if !t.stopped {
			return vectra9.EBUSY, false
		}
		_, line, lok := libdebug.line_at(&t.dbg, libdebug.frame_pc(t.regs[:]))
		if !t.has_dbg || !lok {
			return vectra9.EOPNOTSUPP, false
		}
		t.next_line = line
		t.next_steps = 0
		t.phase = .Nexting
		t.pending = fid
		t.has_pending = true
		step_once(t)
		return vectra9.Errno(0), true
	case "until":
		if n < 2 || !t.stopped {
			return vectra9.EINVAL, false
		}
		addr, aok := resolve_place(t, words[1])
		if !aok {
			return vectra9.ENOENT, false
		}
		t.temp = addr
		temp_size = plant(t, addr, nil)
		if temp_size == 0 {
			t.temp = 0
			return vectra9.EFAULT, false
		}
		t.pending = fid
		t.has_pending = true
		resume(t)
		return vectra9.Errno(0), true
	case "finish":
		return vectra9.EOPNOTSUPP, false
	}
	return vectra9.EINVAL, false
}

// resolve_place turns `file:line`, a procedure's name, or `0xaddr` into
// an address in the target.
resolve_place :: proc "contextless" (t: ^Target, place: string) -> (addr: u64, ok: bool) {
	if len(place) > 2 && place[0] == '0' && place[1] == 'x' {
		return parse_hex(place[2:])
	}
	colon := -1
	for i := len(place) - 1; i >= 0; i -= 1 {
		if place[i] == ':' {
			colon = i
			break
		}
	}
	if !t.has_dbg {
		return 0, false
	}
	if colon > 0 {
		line, lok := libuser.atoi(place[colon + 1:])
		if !lok {
			return 0, false
		}
		return libdebug.line_first(&t.dbg, place[:colon], u32(line))
	}
	return libdebug.proc_named(&t.dbg, place)
}

// -- The files' text -----------------------------------------------------------------

put_place :: proc "contextless" (sink: ^libodin.Sink, t: ^Target, pc: u64) {
	if !t.has_dbg {
		return
	}
	if name, low, ok := libdebug.proc_at(&t.dbg, pc); ok {
		libodin.put_str(sink, " in ")
		libodin.put_str(sink, name)
		libodin.put_str(sink, "+")
		libodin.put_hex(sink, pc - low, 0)
	}
	if file, line, ok := libdebug.line_at(&t.dbg, pc); ok {
		libodin.put_str(sink, " at ")
		libodin.put_str(sink, libuser.basename(file))
		libodin.put_str(sink, ":")
		libodin.put_uint(sink, u64(line))
	}
}

status_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	switch {
	case t.exited:
		libodin.put_str(&sink, "Exited (")
		libodin.put_str(&sink, string(t.why[:t.why_len]))
		libodin.put_str(&sink, ")")
	case !t.stopped:
		libodin.put_str(&sink, "Running")
	case:
		pc := libdebug.frame_pc(t.regs[:])
		libodin.put_str(&sink, "Stopped pc=")
		libodin.put_hex(&sink, pc, 0)
		put_place(&sink, t, pc)
		libodin.put_str(&sink, " (")
		libodin.put_str(&sink, string(t.why[:t.why_len]))
		libodin.put_str(&sink, ")")
	}
	libodin.put_str(&sink, "\n")
	return len(libodin.str(&sink))
}

bt_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	if !t.stopped {
		libodin.put_str(&sink, "not stopped\n")
		return len(libodin.str(&sink))
	}
	pc := libdebug.frame_pc(t.regs[:])
	libodin.put_str(&sink, "0 ")
	libodin.put_hex(&sink, pc, 0)
	put_place(&sink, t, pc)
	libodin.put_str(&sink, "\n")
	// The rest is a scan, as `kernel/panic.odin` scans: every word of the
	// stack that lands inside a procedure, marked maybe. A code pointer
	// pushed as data reads the same. A word at a procedure's first byte is
	// such a pointer -- a context's procedures, say -- and never a return
	// address, so it is left out.
	sp := libdebug.frame_sp(t.regs[:])
	stack: [2048]u8
	n := read_mem(t, sp, stack[:])
	found := 0
	for at := 0; at + 8 <= n && found < 12; at += 8 {
		v := libdebug.u64_of(stack[at:at + 8])
		if !t.has_dbg {
			break
		}
		if _, low, ok := libdebug.proc_at(&t.dbg, v); ok && v > low {
			found += 1
			libodin.put_str(&sink, "maybe ")
			libodin.put_hex(&sink, v, 0)
			put_place(&sink, t, v)
			libodin.put_str(&sink, "\n")
		}
	}
	return len(libodin.str(&sink))
}

regs_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	if !t.stopped {
		libodin.put_str(&sink, "not stopped\n")
		return len(libodin.str(&sink))
	}
	for i in 0 ..< libdebug.reg_count() {
		name, v := libdebug.reg_at(t.regs[:], i)
		libodin.put_str(&sink, name)
		libodin.put_str(&sink, " ")
		libodin.put_hex(&sink, v, 0)
		libodin.put_str(&sink, "\n")
	}
	return len(libodin.str(&sink))
}

breaks_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	for i in 0 ..< MAX_BREAKS {
		b := &t.breaks[i]
		if !b.used {
			continue
		}
		libodin.put_int(&sink, i64(i))
		libodin.put_str(&sink, " ")
		libodin.put_hex(&sink, b.addr, 0)
		put_place(&sink, t, b.addr)
		libodin.put_str(&sink, " hits ")
		libodin.put_int(&sink, i64(b.hits))
		libodin.put_str(&sink, "\n")
	}
	return len(libodin.str(&sink))
}

dis_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	if !t.stopped || !t.has_dbg {
		libodin.put_str(&sink, t.stopped ? "no disassembly for this program\n" : "not stopped\n")
		return len(libodin.str(&sink))
	}
	pc := libdebug.frame_pc(t.regs[:])
	i, ok := libdebug.dis_index(&t.dbg, pc)
	if !ok {
		libodin.put_str(&sink, "no disassembly at the counter\n")
		return len(libodin.str(&sink))
	}
	for j := max(i - 4, 0); j < i + 12; j += 1 {
		addr, text, rok := libdebug.dis_row(&t.dbg, j)
		if !rok {
			break
		}
		libodin.put_str(&sink, addr == pc ? "=> " : "   ")
		libodin.put_hex(&sink, addr, 0)
		libodin.put_str(&sink, "  ")
		libodin.put_str(&sink, text)
		libodin.put_str(&sink, "\n")
	}
	return len(libodin.str(&sink))
}

// procs_text lists the processes of the target's note group: a program's
// procs, in `docs/THREAD.md`'s sense.
procs_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	fd := libuser.open("/proc", abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	defer libuser.close(int(fd))
	entries: [16]abi.Dirent
	for {
		n := libuser.dirread(int(fd), entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			pid, pok := libuser.atoi(string(e.name[:e.name_len]))
			if !pok {
				continue
			}
			status: [512]u8
			got := read_file_once(u64(pid), "status", status[:])
			if got <= 0 {
				continue
			}
			fields: [8]string
			nf := split_fields(string(status[:got]), fields[:])
			if nf < 5 {
				continue
			}
			g, gok := libuser.atoi(fields[4])
			if !gok || u64(g) != t.group {
				continue
			}
			libodin.put_str(&sink, fields[1])
			libodin.put_str(&sink, " ")
			libodin.put_str(&sink, fields[3])
			libodin.put_str(&sink, " ")
			libodin.put_str(&sink, libuser.basename(fields[0]))
			libodin.put_str(&sink, "\n")
		}
	}
	return len(libodin.str(&sink))
}

// -- 9P ---------------------------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag
	if !libuser.default_reply(request, reply) {
		return
	}
	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)
	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)
	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)
	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}
	case vectra9.Tread:
		read(m, reply, buf)
	case vectra9.Twrite:
		write(m, reply)
	case vectra9.Treaddir:
		readdir(m, reply, buf)
	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := is_dir(node)
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100666,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}
	case vectra9.Tclunk:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}
	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}
	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// text_window copies the window a read asked for out of a text that was
// just made whole.
text_window :: proc "contextless" (text: []u8, m: vectra9.Tread, reply: ^vectra9.Msg, buf: []u8) {
	if m.offset >= u64(len(text)) {
		reply^ = vectra9.Rread{data = nil}
		return
	}
	start := int(m.offset)
	end := min(len(text), start + min(len(buf), int(m.count)))
	copy(buf[:end - start], text[start:end])
	reply^ = vectra9.Rread{data = buf[:end - start]}
}

scratch: [OUT_MAX]u8

read :: proc "contextless" (m: vectra9.Tread, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}
	if node == NODE_CTL {
		sink := libodin.sink_from(scratch[:])
		libodin.put_int(&sink, i64(last_made + 1))
		libodin.put_str(&sink, "\n")
		text_window(scratch[:len(libodin.str(&sink))], m, reply, buf)
		return
	}
	ti := node_target(node)
	if ti < 0 || !targets[ti].used {
		reply^ = vectra9.error_reply(vectra9.ESRCH)
		return
	}
	t := &targets[ti]
	n := 0
	switch node_part(node) {
	case .Status:
		n = status_text(t, scratch[:])
	case .Bt:
		n = bt_text(t, scratch[:])
	case .Vars:
		n = vars_text(t, scratch[:])
	case .Regs:
		n = regs_text(t, scratch[:])
	case .Breaks:
		n = breaks_text(t, scratch[:])
	case .Eval:
		text_window(t.eval_out[:t.eval_len], m, reply, buf)
		return
	case .Dis:
		n = dis_text(t, scratch[:])
	case .Procs:
		n = procs_text(t, scratch[:])
	case .Mem:
		room := min(len(buf), int(m.count))
		got := read_mem(t, m.offset, buf[:room])
		if got < 0 {
			reply^ = vectra9.error_reply(vectra9.EFAULT)
			return
		}
		reply^ = vectra9.Rread{data = buf[:got]}
		return
	case .Ctl:
		sink := libodin.sink_from(scratch[:])
		libodin.put_str(&sink, string(t.last_word[:t.last_len]))
		libodin.put_str(&sink, "\n")
		n = len(libodin.str(&sink))
	case .Dir:
	}
	text_window(scratch[:n], m, reply, buf)
}

write :: proc "contextless" (m: vectra9.Twrite, reply: ^vectra9.Msg) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	text := trim(string(m.data))
	if node == NODE_CTL {
		errno, hold := root_ctl(m.fid, text)
		if hold {
			lib9p.hold(&srv)
			return
		}
		if errno != vectra9.Errno(0) {
			reply^ = vectra9.error_reply(errno)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		return
	}
	ti := node_target(node)
	if ti < 0 || !targets[ti].used {
		reply^ = vectra9.error_reply(vectra9.ESRCH)
		return
	}
	t := &targets[ti]
	switch node_part(node) {
	case .Ctl:
		t.last_len = copy(t.last_word[:], text)
		errno, hold := target_ctl(t, m.fid, text)
		if hold {
			lib9p.hold(&srv)
			return
		}
		if errno != vectra9.Errno(0) {
			reply^ = vectra9.error_reply(errno)
			return
		}
	case .Eval:
		t.eval_len = eval_text(t, text, t.eval_out[:])
	case .Mem:
		if !t.stopped {
			reply^ = vectra9.error_reply(vectra9.EBUSY)
			return
		}
		if write_mem(t, m.offset, m.data) != len(m.data) {
			reply^ = vectra9.error_reply(vectra9.EFAULT)
			return
		}
	case .Dir, .Status, .Bt, .Vars, .Regs, .Breaks, .Dis, .Procs:
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}
	reply^ = vectra9.Rwrite{count = u32(len(m.data))}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if !is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	if node == NODE_ROOT {
		// `ctl` at cookie 1, then target i at cookie i + 2.
		if m.offset < 1 && vectra9.remaining(&c) >= vectra9.dirent_size("ctl") {
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_CTL), offset = 1, type = vectra9.DT_REG, name = "ctl"})
		}
		for i in 0 ..< MAX_TARGETS {
			cookie := u64(i + 2)
			if cookie <= m.offset || !targets[i].used {
				continue
			}
			digits: [4]u8
			sink := libodin.sink_from(digits[:])
			libodin.put_int(&sink, i64(i + 1))
			name := libodin.str(&sink)
			if vectra9.remaining(&c) < vectra9.dirent_size(name) {
				break
			}
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(node_of(i, .Dir)), offset = cookie, type = vectra9.DT_DIR, name = name})
		}
	} else {
		t := node_target(node)
		for part in Part {
			if part == .Dir {
				continue
			}
			cookie := u64(part)
			if cookie <= m.offset {
				continue
			}
			name := PART_NAMES[part]
			if vectra9.remaining(&c) < vectra9.dirent_size(name) {
				break
			}
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(node_of(t, part)), offset = cookie, type = vectra9.DT_REG, name = name})
		}
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

// -- Text helpers ----------------------------------------------------------------------

split_fields :: proc "contextless" (s: string, out: []string) -> int {
	n := 0
	start_at := -1
	for i in 0 ..= len(s) {
		blank := i == len(s) || s[i] == ' ' || s[i] == '\n' || s[i] == '\t'
		if blank {
			if start_at >= 0 && n < len(out) {
				out[n] = s[start_at:i]
				n += 1
			}
			start_at = -1
		} else if start_at < 0 {
			start_at = i
		}
	}
	return n
}

trim :: proc "contextless" (s: string) -> string {
	t := s
	for len(t) > 0 && (t[len(t) - 1] == '\n' || t[len(t) - 1] == ' ' || t[len(t) - 1] == '\r') {
		t = t[:len(t) - 1]
	}
	for len(t) > 0 && t[0] == ' ' {
		t = t[1:]
	}
	return t
}

has_prefix :: proc "contextless" (s, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
}

parse_hex :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		d: u64
		switch {
		case c >= '0' && c <= '9': d = u64(c - '0')
		case c >= 'a' && c <= 'f': d = u64(c - 'a' + 10)
		case c >= 'A' && c <= 'F': d = u64(c - 'A' + 10)
		case:
			return 0, false
		}
		v = v << 4 | d
	}
	return v, true
}
