/*
The sandbox, `docs/GHOST.md` section 4: every tool runs in a child the
ghost forks, and the child's namespace is all it can name.

    fork        RFPROC | RFFDG | RFNAMEG | RFNOTEG | RFENVG: a table, a
                namespace, a note group and an environment of its own
    descriptors the tool's pipe on 1 and 2, nothing on 0, nothing else
    the class   `$work` set, then `/lib/ghost/ns/<class>` replayed by
                `newns`, the same lines `ns` prints
    the strip   every name the ghost's namespace had mounted that the
                class does not bind is unmounted, deepest first, so
                `/proc`, `/net`, `/srv`, `/dev`, `/env`, the model and
                the ghost's own files are empty directories
    the lock    `rfork(RFNOMNT)`: no bind, mount, unmount or `#name`
                again, so the table built is the table the tool has

The strip is what makes the class an allow list. A class names what the
tools may reach, and nothing it does not name survives, whatever the
ghost's own namespace held when it forked.

The fork happens on the session's io proc, `iorun`, so the serve loop
answers while a tool runs. The child is a copy of that proc and never
returns into the thread library: it builds the namespace, does its one
thing, and exits, with every buffer it uses in the `Tool_Run` it was
forked holding. A child may not allocate, because a lock another proc
held at the fork is held for ever in the copy.
*/
package ghost

import "vsys:abi"
import "vsys:libplumb"
import "vsys:libuser"
import "vsys:vectra9"

MAX_OUT :: 16 * 1024
MAX_KEEP :: 32
MAX_STRIP :: 96

Op :: enum u8 {
	Read,
	Ls,
	Write,
	Run,
	Plumb,
	Ns,
}

/*
One tool call: what the child is asked, what it answered, and the scratch
the child builds its namespace in. On the heap, made by the turn, read and
written by the io proc and by the child's copy.
*/
Tool_Run :: struct {
	op:        Op,
	class:     [NAME_MAX]u8,
	clen:      int,
	work:      [PATH_MAX]u8,
	wlen:      int,
	unlocked:  bool,

	path:      string,
	text:      string,
	script:    string,
	offset:    i64,
	count:     i64,
	expect:    i64, // The version a read saw, or -1
	confirmed: bool, // A write to a file that exists may go ahead

	// The io proc's side. `pid` is set once the child runs, and the clock
	// reads it and `deadline` to kill a run past its time.
	pid:       i64,
	deadline:  int,
	killed:    bool,
	out:       [MAX_OUT]u8,
	nout:      int,
	status:    [128]u8,
	stlen:     int,

	// The child's.
	nsbuf:     [16 * 1024]u8,
	classbuf:  [4096]u8,
	keep:      [MAX_KEEP][PATH_MAX]u8,
	keeplen:   [MAX_KEEP]int,
	iobuf:     [8192]u8,
}

tool_new :: proc(s: ^Session, op: Op) -> ^Tool_Run {
	t := new(Tool_Run)
	t.op = op
	t.clen = copy(t.class[:], class_of(s))
	t.wlen = copy(t.work[:], work_of(s))
	t.unlocked = g_unlocked
	t.expect = -1
	return t
}

tool_free :: proc(t: ^Tool_Run) {
	free(t)
}

// The first line the child answered, and the rest.
tool_head :: proc "contextless" (t: ^Tool_Run) -> (head: string, body: string) {
	out := string(t.out[:t.nout])
	for i in 0 ..< len(out) {
		if out[i] == '\n' {
			return out[:i], out[i + 1:]
		}
	}
	return out, ""
}

// The child's ending, the word after its pid: empty for a clean exit.
tool_status :: proc "contextless" (t: ^Tool_Run) -> string {
	st := string(t.status[:t.stlen])
	for i in 0 ..< len(st) {
		if st[i] == ' ' {
			return st[i + 1:]
		}
	}
	return ""
}

/*
tool_run is the call on the io proc: a pipe, the fork, the child's output
read to its end, and the child collected. The io proc is the child's
parent, so the wait is here beside the fork.
*/
tool_run :: proc "contextless" (arg: rawptr) -> i64 {
	t := (^Tool_Run)(arg)
	packed := libuser.pipe()
	if packed < 0 {
		t.nout = copy(t.out[:], "error no pipe for the tool\n")
		return -1
	}
	r, w := abi.pipe_ends(packed)
	pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNAMEG | abi.RFNOTEG | abi.RFENVG)
	if pid < 0 {
		_ = libuser.close(r)
		_ = libuser.close(w)
		t.nout = copy(t.out[:], "error no process for the tool\n")
		return -1
	}
	if pid == 0 {
		sandbox(t, w, r)
	}
	_ = libuser.close(w)
	t.deadline = now + RUN_DEADLINE
	t.pid = pid
	for {
		n := libuser.read(r, t.iobuf[:])
		if n <= 0 {
			break
		}
		t.nout += copy(t.out[t.nout:], t.iobuf[:n])
	}
	_ = libuser.close(r)
	for {
		n := libuser.await(u64(pid), t.status[:])
		if n == -i64(vectra9.EAGAIN) {
			continue
		}
		t.stlen = n > 0 ? int(n) : 0
		break
	}
	t.pid = 0
	return 0
}

// -- The child ----------------------------------------------------------------

@(private = "file")
say :: proc "contextless" (parts: ..string) {
	for p in parts {
		_ = libuser.write_full(1, transmute([]u8)p)
	}
}

@(private = "file")
fail :: proc "contextless" (why: ..string) -> ! {
	say("error ")
	for w in why {
		say(w)
	}
	say("\n")
	libuser.exits("sandbox")
}

/*
sandbox is the child, from the fork to its exit. It never returns.
*/
@(private = "file")
sandbox :: proc "contextless" (t: ^Tool_Run, out: int, other: int) -> ! {
	_ = libuser.close(other)
	_ = libuser.dup(out, 1)
	_ = libuser.dup(out, 2)
	_ = libuser.close(0)
	libuser.close_from(3)

	// `$work` is the class file's name for the task's directory. The
	// environment is a copy, so the ghost's own is untouched.
	work := string(t.work[:t.wlen])
	if efd := libuser.open_or_create("/env/work", abi.O_WRONLY); efd >= 0 {
		_ = libuser.write_full(int(efd), transmute([]u8)work)
		_ = libuser.close(int(efd))
	}

	// The table as the ghost had it, before the class: what the strip
	// takes down. The descriptor stays open, because `/proc` is one of
	// the names the strip removes and `ns` reads the table after it.
	nb: [24]u8
	pb: [64]u8
	nspath := libuser.cat_into(pb[:], "/proc/", libuser.itoa(nb[:], i64(libuser.getpid())), "/ns")
	nsfd := int(libuser.open(nspath, abi.O_RDONLY))
	if nsfd < 0 {
		fail("the namespace cannot be read: ", libuser.errstr(i64(nsfd)))
	}
	table := read_all_at(nsfd, t.nsbuf[:])
	// A table cut short would leave mounts standing that the strip never
	// saw, so a sandbox built from one is refused, not believed.
	if len(table) == len(t.nsbuf) || (len(table) > 0 && table[len(table) - 1] != '\n') {
		fail("the namespace is too long to strip")
	}

	cb: [PATH_MAX]u8
	classpath := libuser.cat_into(cb[:], "/lib/ghost/ns/", string(t.class[:t.clen]))
	cfd := libuser.open(classpath, abi.O_RDONLY)
	if cfd < 0 {
		fail("no class ", string(t.class[:t.clen]), ": ", libuser.errstr(cfd))
	}
	class := read_all_at(int(cfd), t.classbuf[:])
	_ = libuser.close(int(cfd))
	if !libuser.newns(classpath) {
		fail("the class ", string(t.class[:t.clen]), " would not apply")
	}

	// What the class binds, its names expanded as `newns` expanded them.
	nkeep := 0
	lines := each_line(class)
	for line in next_line(&lines) {
		if nkeep >= MAX_KEEP {
			break
		}
		if target := libuser.ns_target(line, t.keep[nkeep][:]); target != "" {
			t.keeplen[nkeep] = len(target)
			nkeep += 1
		}
	}

	// Every other name the table had mounted, once each, deepest first,
	// so a mount inside another comes down while it can still be named.
	strip: [MAX_STRIP]string
	nstrip := 0
	lines = each_line(table)
	for line in next_line(&lines) {
		target := last_word(line)
		if len(target) == 0 || target[0] != '/' || kept(t, nkeep, target) {
			continue
		}
		dup := false
		for i in 0 ..< nstrip {
			if strip[i] == target {
				dup = true
				break
			}
		}
		if !dup {
			// A mount past the list would stay, and the lock below would
			// keep it. So the sandbox is refused, as a table cut short is.
			if nstrip == MAX_STRIP {
				fail("the namespace has too many mounts to strip")
			}
			strip[nstrip] = target
			nstrip += 1
		}
	}
	for i in 0 ..< nstrip {
		for j in i + 1 ..< nstrip {
			if len(strip[j]) > len(strip[i]) {
				strip[i], strip[j] = strip[j], strip[i]
			}
		}
	}
	for i in 0 ..< nstrip {
		_ = libuser.unmount("", strip[i])
	}

	// The lock. The control, `ghost -u`, leaves it off, and a `run bind`
	// then succeeds, which is what the self-test's control shows.
	if !t.unlocked && libuser.rfork(abi.RFNOMNT) < 0 {
		fail("the namespace would not lock")
	}
	if libuser.chdir("/n/work") < 0 {
		_ = libuser.chdir("/")
	}

	switch t.op {
	case .Ns:
		say(string(read_all_at(nsfd, t.nsbuf[:])))
	case .Read:
		child_read(t)
	case .Ls:
		child_ls(t)
	case .Write:
		child_write(t)
	case .Run:
		_ = libuser.close(nsfd)
		argv := [3]string{"rc", "-c", t.script}
		r := libuser.exec("/bin/rc", argv[:])
		fail("cannot exec rc: ", libuser.errstr(r))
	case .Plumb:
		child_plumb(t)
	}
	libuser.exits("")
}

@(private = "file")
kept :: proc "contextless" (t: ^Tool_Run, nkeep: int, target: string) -> bool {
	for i in 0 ..< nkeep {
		if string(t.keep[i][:t.keeplen[i]]) == target {
			return true
		}
	}
	return false
}

// read_all_at reads a file from its start into `buf`, as much as fits.
@(private = "file")
read_all_at :: proc "contextless" (fd: int, buf: []u8) -> string {
	n := 0
	for n < len(buf) {
		got := libuser.pread(fd, buf[n:], u64(n))
		if got <= 0 {
			break
		}
		n += int(got)
	}
	return string(buf[:n])
}

@(private = "file")
child_read :: proc "contextless" (t: ^Tool_Run) {
	fd := libuser.open(t.path, abi.O_RDONLY)
	if fd < 0 {
		fail(libuser.errstr(fd))
	}
	st: abi.Stat
	if libuser.fstat(int(fd), &st) < 0 {
		fail("no stat")
	}
	vb: [24]u8
	say("ok ", libuser.itoa(vb[:], i64(st.qid_version)), "\n")
	at := u64(max(t.offset, 0))
	left := t.count > 0 ? int(t.count) : MAX_OUT - 64
	left = min(left, MAX_OUT - 64)
	for left > 0 {
		got := libuser.pread(int(fd), t.iobuf[:min(left, len(t.iobuf))], at)
		if got <= 0 {
			break
		}
		_ = libuser.write_full(1, t.iobuf[:got])
		at += u64(got)
		left -= int(got)
	}
}

@(private = "file")
child_ls :: proc "contextless" (t: ^Tool_Run) {
	fd := libuser.open(t.path, abi.O_RDONLY)
	if fd < 0 {
		fail(libuser.errstr(fd))
	}
	say("ok\n")
	entries: [16]abi.Dirent
	for {
		n := libuser.dirread(int(fd), entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			say(string(e.name[:e.name_len]), e.qid_kind & abi.QTDIR != 0 ? "/\n" : "\n")
		}
	}
}

/*
child_write is the staleness check and the write. A file that exists and
moved since the ghost's read answers `stale`. One that exists with no yes
yet answers `exists`, and the turn asks the person before it runs again.
Both answer the version seen, which the second run then holds the file to.
*/
@(private = "file")
child_write :: proc "contextless" (t: ^Tool_Run) {
	vb: [24]u8
	st: abi.Stat
	exists := libuser.stat(t.path, &st) >= 0
	if exists && t.expect >= 0 && i64(st.qid_version) != t.expect {
		say("stale ", libuser.itoa(vb[:], i64(st.qid_version)), "\n")
		return
	}
	if exists && !t.confirmed {
		say("exists ", libuser.itoa(vb[:], i64(st.qid_version)), "\n")
		return
	}
	fd := libuser.open_or_create(t.path, abi.O_WRONLY, 0o664)
	if fd < 0 {
		fail(libuser.errstr(fd))
	}
	if !libuser.write_full(int(fd), transmute([]u8)t.text) {
		fail("the write fell short")
	}
	if libuser.fstat(int(fd), &st) < 0 {
		st.qid_version = 0
	}
	_ = libuser.close(int(fd))
	say("ok ", libuser.itoa(vb[:], i64(st.qid_version)), "\n")
}

@(private = "file")
child_plumb :: proc "contextless" (t: ^Tool_Run) {
	m := libplumb.Msg {
		src  = "ghost",
		wdir = "/n/work",
		type = "text",
		data = t.text,
	}
	n := libplumb.pack(&m, t.iobuf[:])
	if n < 0 {
		fail("the message is too long")
	}
	fd := libuser.open("/mnt/plumb/send", abi.O_WRONLY)
	if fd < 0 {
		fail("no plumber: ", libuser.errstr(fd))
	}
	if w := libuser.write(int(fd), t.iobuf[:n]); w != i64(n) {
		fail("no rule took it: ", libuser.errstr(w))
	}
	say("ok\n")
}

// -- Lines --------------------------------------------------------------------

Line_Iter :: struct {
	s:  string,
	at: int,
}

each_line :: proc "contextless" (s: string) -> Line_Iter {
	return Line_Iter{s = s}
}

next_line :: proc "contextless" (it: ^Line_Iter) -> (line: string, idx: int, ok: bool) {
	if it.at >= len(it.s) {
		return "", 0, false
	}
	e := it.at
	for e < len(it.s) && it.s[e] != '\n' {
		e += 1
	}
	line = it.s[it.at:e]
	it.at = e + 1
	return line, 0, true
}

// last_word answers the last run of non-space on a line: the target of a
// line `ns` printed.
last_word :: proc "contextless" (line: string) -> string {
	e := len(line)
	for e > 0 && (line[e - 1] == ' ' || line[e - 1] == '\t' || line[e - 1] == '\r') {
		e -= 1
	}
	b := e
	for b > 0 && line[b - 1] != ' ' && line[b - 1] != '\t' {
		b -= 1
	}
	return line[b:e]
}
