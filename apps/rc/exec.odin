/*
Running the tree.

A walk over the nodes with the shell's state beside it. Compound commands
run in this process. A simple command that names a program forks, and the
child arranges its descriptors and execs. A pipeline forks a child per
stage. A backquote forks one child whose output the parent reads. Every
fork is `rfork(RFPROC|RFFDG)`: the child is this interpreter, mid-walk,
with its own copy of the descriptor table, and it carries on from the node
it was given and then says its status. That is why the tree is walked
rather than compiled: a child needs nothing but the pointer it was
forked with.

Redirections on a command that runs in this process are applied and then
undone: the descriptor they replace is parked on a high number first and
put back after. A command that runs in a child applies them and does not
look back.
*/
package rc

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"
import "vsys:vectra9"

FORK_FLAGS :: abi.RFPROC | abi.RFFDG

// fork_child is every fork the shell makes, with the environment written
// out first. The group is shared with the child, so a variable written
// here is what the child's program reads, and the marks come down once, in
// the one table that keeps them.
fork_child :: proc(sh: ^Shell) -> i64 {
	updenv(sh)
	return libuser.rfork(FORK_FLAGS)
}

// run walks one node. The result is in `$status`.
run :: proc(sh: ^Shell, n: ^Node) {
	if n == nil || sh.exiting {
		return
	}
	#partial switch n.kind {
	case .Nop:
		saved := push_redirs(sh, n.redirs[:])
		pop_redirs(saved)

	case .Simple:
		run_simple(sh, n)

	case .Brace:
		saved := push_redirs(sh, n.redirs[:])
		run(sh, n.a)
		pop_redirs(saved)

	case .Seq:
		run(sh, n.a)
		run(sh, n.b)

	case .Async:
		pid := fork_node(sh, n.a)
		if pid > 0 {
			apid := make([]string, 1, sh.temp)
			if apid == nil {
				// The word is lost rather than the shell: an interactive
				// shell that dies here takes the console with it.
				libfmt.fprint(2, "rc: out of memory\n")
				set_status(sh, "out of memory")
				return
			}
			apid[0] = itoa(sh, int(pid))
			set_var(sh, "apid", apid)
		}
		set_status(sh, "")

	case .And_And:
		run(sh, n.a)
		if ok(sh) {
			run(sh, n.b)
		}

	case .Or_Or:
		run(sh, n.a)
		if !ok(sh) {
			run(sh, n.b)
		}

	case .Pipe:
		run_pipe(sh, n)

	case .Bang:
		run(sh, n.a)
		set_status(sh, ok(sh) ? "false" : "")

	case .Subshell:
		pid := fork_node(sh, n.a)
		if pid > 0 {
			set_status(sh, wait_for(sh, pid))
		}

	case .If:
		run(sh, n.a)
		sh.last_if = ok(sh)
		if sh.last_if {
			run(sh, n.b)
		}

	case .If_Not:
		if !sh.last_if {
			run(sh, n.a)
		}

	case .For:
		names := eval_plain(sh, n.a)
		if len(names) != 1 {
			complain(sh, n, "for: one variable name")
			return
		}
		list := n.c != nil ? eval_args(sh, n.c.list[:]) : sh.argv
		list = clone_list(list)
		defer free_list(list)
		for item in list {
			one := make([]string, 1, sh.temp)
			one[0] = item
			set_var(sh, names[0], one)
			run(sh, n.b)
			if sh.exiting {
				break
			}
		}

	case .While:
		for !sh.exiting {
			run(sh, n.a)
			if !ok(sh) {
				break
			}
			run(sh, n.b)
		}

	case .Switch:
		subject := eval_plain(sh, n.a)
		for c in n.list {
			patterns := eval_words(sh, c.list[:])
			if match_any(patterns, subject) {
				run(sh, c.a)
				return
			}
		}

	case .Fn:
		names := strip_all(sh, eval_words(sh, n.list[:]))
		if n.a == nil {
			for name in names {
				undefine(sh, name)
			}
			return
		}
		body := n.a
		n.a = nil // the table owns it now; `free_tree` must not
		for name in names {
			define(sh, name, body)
		}

	case .Twiddle:
		subject := eval_plain(sh, n.a)
		patterns := eval_words(sh, n.list[:])
		set_status(sh, match_any(patterns, subject) ? "" : "no match")

	case .Assign:
		names := eval_plain(sh, n.a)
		if len(names) != 1 {
			complain(sh, n, "assignment: one variable name")
			return
		}
		value := eval_plain(sh, n.b)
		if n.c == nil {
			set_var(sh, names[0], value)
			return
		}
		// `x=y cmd`: the old value comes back after, whatever cmd did.
		old := clone_list(lookup(sh, names[0]))
		set_var(sh, names[0], value)
		run(sh, n.c)
		set_var(sh, names[0], old)
		free_list(old)
	}
}

/*
run_simple is a command that is words: a function, a builtin, or a program.

Functions and builtins run here, under the command's redirections and
then out from under them. A program runs in a child. The arguments are
evaluated first, in this process, so a backquote inside them runs once
whichever way the command goes.
*/
@(private = "file")
run_simple :: proc(sh: ^Shell, n: ^Node) {
	argv := eval_args(sh, n.list[:])
	if sh.flag_error {
		sh.flag_error = false
		set_status(sh, "error")
		return
	}
	run_argv(sh, n, argv)
}

// What a simple command's first word names. Decided in one place, for the
// parent that runs it and the forked child that may exec it.
Command_Kind :: enum {
	Nothing, // no words: only redirections
	Function,
	Exec, // the builtin whose redirections stay
	Builtin,
	Program,
}

classify :: proc(sh: ^Shell, argv: []string) -> Command_Kind {
	switch {
	case len(argv) == 0:
		return .Nothing
	case find_fn(sh, argv[0]) >= 0:
		return .Function
	case argv[0] == "exec":
		return .Exec
	case is_builtin(argv[0]):
		return .Builtin
	}
	return .Program
}

// run_argv runs a simple command whose words are already evaluated.
run_argv :: proc(sh: ^Shell, n: ^Node, argv: []string) {
	if sh.flags['x'] && len(argv) > 0 {
		libfmt.fprint(2, "%s\n", join(sh, argv, " "))
	}
	switch classify(sh, argv) {
	case .Nothing:
		saved := push_redirs(sh, n.redirs[:])
		pop_redirs(saved)
		set_status(sh, "")
	case .Function:
		saved := push_redirs(sh, n.redirs[:])
		call_function(sh, sh.fns[find_fn(sh, argv[0])].body, argv)
		pop_redirs(saved)
	case .Exec:
		if !apply_redirs(sh, n.redirs[:]) {
			set_status(sh, "redirection")
			return
		}
		builtin_exec(sh, argv[1:])
	case .Builtin:
		saved := push_redirs(sh, n.redirs[:])
		run_builtin(sh, argv)
		pop_redirs(saved)
	case .Program:
		run_program(sh, argv, n.redirs[:])
	}
}

// run_program forks, and the child arranges its descriptors and execs.
run_program :: proc(sh: ^Shell, argv: []string, redirs: []Redir) {
	pid := fork_child(sh)
	if pid < 0 {
		libfmt.fprint(2, "rc: %s: fork failed: %s\n", argv[0], libuser.errstr(pid))
		set_status(sh, "fork")
		return
	}
	if pid == 0 {
		exec_simple(sh, argv, redirs)
	}
	set_status(sh, wait_for(sh, pid))
	if sh.flags['e'] && !ok(sh) && !sh.interactive {
		sh.exiting = true
	}
}

/*
exec_program replaces this process with the program, searched for along
`$path` unless the name has a slash in it. Returns only when nothing
along the path would exec, having said so.
*/
exec_program :: proc(sh: ^Shell, argv: []string) {
	name := argv[0]
	has_slash := false
	for i in 0 ..< len(name) {
		if name[i] == '/' {
			has_slash = true
			break
		}
	}
	if has_slash {
		r := libuser.exec(name, argv)
		libfmt.fprint(2, "rc: %s: %s\n", name, libuser.errstr(r))
		return
	}
	last := -i64(vectra9.ENOENT)
	for dir in search_path(sh) {
		full := dir == "." ? name : path_join(sh, dir, name)
		last = libuser.exec(full, argv)
		if last != -i64(vectra9.ENOENT) {
			break
		}
	}
	if last == -i64(vectra9.ENOENT) {
		libfmt.fprint(2, "rc: %s: not found\n", name)
	} else {
		libfmt.fprint(2, "rc: %s: %s\n", name, libuser.errstr(last))
	}
}

// call_function runs a function body with `$*` rebound to its arguments.
call_function :: proc(sh: ^Shell, body: ^Node, argv: []string) {
	saved := push_args(sh, argv[1:], argv[0])
	run(sh, body)
	pop_args(sh, saved)
}

// push_args rebinds `$*` and `$0` for a function or a `.` file, and answers
// what `pop_args` puts back.
Saved_Args :: struct {
	argv: []string,
	arg0: string,
}

push_args :: proc(sh: ^Shell, argv: []string, arg0: string) -> Saved_Args {
	saved := Saved_Args{argv = sh.argv, arg0 = sh.arg0}
	sh.argv = clone_list(argv)
	sh.arg0 = arg0
	return saved
}

pop_args :: proc(sh: ^Shell, saved: Saved_Args) {
	free_list(sh.argv)
	sh.argv = saved.argv
	sh.arg0 = saved.arg0
}

// fork_node runs a node in a child that then says its status. Answers the
// pid to the parent; the child never returns.
fork_node :: proc(sh: ^Shell, n: ^Node) -> i64 {
	pid := fork_child(sh)
	if pid < 0 {
		libfmt.fprint(2, "rc: fork failed: %s\n", libuser.errstr(pid))
		set_status(sh, "fork")
		return pid
	}
	if pid == 0 {
		run_in_child(sh, n)
	}
	return pid
}

/*
run_in_child is a forked child's whole life: run the node, say the status.

A node that is one program -- `sleep 100 &`, a pipeline's stage, a
backquote's body -- is exec'd in this process rather than forked a second
time, as Plan 9's rc does. The pid the parent holds is then the program's
own, so `kill $apid` reaches it, and a pipeline of n stages is n processes
rather than 2n.
*/
run_in_child :: proc(sh: ^Shell, n: ^Node) -> ! {
	sh.interactive = false
	set_pid(sh)
	if n != nil && n.kind == .Simple {
		// The words once, whichever way the command goes.
		argv := eval_args(sh, n.list[:])
		if sh.flag_error {
			libuser.exits("error")
		}
		if classify(sh, argv) == .Program {
			if sh.flags['x'] {
				libfmt.fprint(2, "%s\n", join(sh, argv, " "))
			}
			exec_simple(sh, argv, n.redirs[:])
		}
		run_argv(sh, n, argv)
		libuser.exits(status(sh))
	}
	run(sh, n)
	libuser.exits(status(sh))
}

// exec_simple is a forked child's end as a program: its redirections for
// good, its environment written out, and the exec. Returns only by exiting.
exec_simple :: proc(sh: ^Shell, argv: []string, redirs: []Redir) -> ! {
	if !apply_redirs(sh, redirs) {
		libuser.exits("redirection")
	}
	exec_program(sh, argv)
	libuser.exits("exec")
}

/*
run_pipe forks a child per side. The left writes its `pipe_left` into the
pipe, the right reads it on `pipe_right`, and the parent closes both ends
before waiting, so the reader sees an end when the writer is gone. The
status is both, joined by `|`, as rc reports it.
*/
@(private = "file")
run_pipe :: proc(sh: ^Shell, n: ^Node) {
	fds := libuser.pipe()
	if fds < 0 {
		set_status(sh, "pipe")
		return
	}
	r, w := abi.pipe_ends(fds)

	left := fork_child(sh)
	if left == 0 {
		libuser.dup(w, n.pipe_left)
		libuser.close(r)
		libuser.close(w)
		run_in_child(sh, n.a)
	}
	right := fork_child(sh)
	if right == 0 {
		libuser.dup(r, n.pipe_right)
		libuser.close(r)
		libuser.close(w)
		run_in_child(sh, n.b)
	}
	libuser.close(r)
	libuser.close(w)
	ls := left > 0 ? wait_for(sh, left) : "fork"
	rs := right > 0 ? wait_for(sh, right) : "fork"
	if len(ls) == 0 && len(rs) == 0 {
		set_status(sh, "")
	} else {
		set_status(sh, cat2(sh, cat2(sh, ls, "|"), rs))
	}
}

/*
backquote runs a body in a child with its output into a pipe, reads the
pipe to its end, and splits what came on `$ifs`. The parent closes its
write end before reading, or the end would never come.
*/
backquote :: proc(sh: ^Shell, body: ^Node) -> []string {
	fds := libuser.pipe()
	if fds < 0 {
		return nil
	}
	r, w := abi.pipe_ends(fds)
	pid := fork_child(sh)
	if pid == 0 {
		libuser.dup(w, 1)
		libuser.close(r)
		libuser.close(w)
		run_in_child(sh, body)
	}
	libuser.close(w)
	out := make([dynamic]u8, 0, 256, sh.temp)
	if pid > 0 {
		tmp: [1024]u8
		for {
			n := libuser.read(r, tmp[:])
			if n <= 0 {
				break
			}
			append(&out, ..tmp[:n])
		}
	}
	libuser.close(r)
	if pid > 0 {
		bq := make([]string, 1, sh.temp)
		bq[0] = wait_for(sh, pid)
		set_var(sh, "bqstatus", bq)
	}
	return split_ifs(sh, string(out[:]))
}

// -- Redirections -------------------------------------------------------------------

Saved_Fd :: struct {
	fd:    int, // the descriptor a redirection replaced
	saved: int, // where its old chan waits, or -1 if it was closed
}

// push_redirs applies redirections in this process, parking what they
// replace. `pop_redirs` puts everything back.
push_redirs :: proc(sh: ^Shell, redirs: []Redir) -> []Saved_Fd {
	if len(redirs) == 0 {
		return nil
	}
	saved := make([dynamic]Saved_Fd, 0, len(redirs), sh.temp)
	for &r in redirs {
		s := Saved_Fd{fd = r.fd, saved = park(r.fd)}
		append(&saved, s)
		if !apply_redir(sh, &r) {
			set_status(sh, "redirection")
		}
	}
	return saved[:]
}

pop_redirs :: proc(saved: []Saved_Fd) {
	for i := len(saved) - 1; i >= 0; i -= 1 {
		s := saved[i]
		if s.saved >= 0 {
			libuser.dup(s.saved, s.fd)
			libuser.close(s.saved)
		} else {
			libuser.close(s.fd)
		}
	}
}

// park copies a descriptor to the lowest free number and answers it, or -1
// when the descriptor was not open. One call, as Plan 9's rc does it.
@(private = "file")
park :: proc(fd: int) -> int {
	return int(libuser.dup(fd))
}

// apply_redirs applies redirections for good, in a child or for `exec`.
apply_redirs :: proc(sh: ^Shell, redirs: []Redir) -> bool {
	for &r in redirs {
		if !apply_redir(sh, &r) {
			return false
		}
	}
	return true
}

@(private = "file")
apply_redir :: proc(sh: ^Shell, r: ^Redir) -> bool {
	fd: i64 = -1
	switch r.kind {
	case .Dup:
		if libuser.dup(r.from, r.fd) < 0 {
			libfmt.fprint(2, "rc: can't duplicate descriptor %d\n", r.from)
			return false
		}
		return true
	case .Close:
		libuser.close(r.fd)
		return true
	case .Here:
		fd = here_pipe(sh, r)
		if fd < 0 {
			return false
		}
	case .Read, .Write, .Append, .Read_Write:
		names := eval_plain(sh, r.word)
		if len(names) != 1 {
			libfmt.fprint(2, "rc: redirection names %d files\n", len(names))
			return false
		}
		name := names[0]
		switch r.kind {
		case .Read:
			fd = libuser.open(name, abi.O_RDONLY)
		case .Write:
			fd = libuser.open_or_create(name, abi.O_WRONLY)
		case .Append:
			fd = libuser.open_append(name)
		case .Read_Write:
			fd = libuser.open_or_create(name, abi.O_RDWR)
		case .Here, .Dup, .Close:
		}
		if fd < 0 {
			libfmt.fprint(2, "rc: %s: %s\n", name, libuser.errstr(fd))
			return false
		}
	}
	if int(fd) != r.fd {
		libuser.dup(int(fd), r.fd)
		libuser.close(int(fd))
	}
	return true
}

/*
here_pipe makes a here document readable: a pipe, and a child that writes
the body into it and ends. The body has `$name` replaced unless the tag
was quoted; `$$` is one `$`.
*/
@(private = "file")
here_pipe :: proc(sh: ^Shell, r: ^Redir) -> i64 {
	fds := libuser.pipe()
	if fds < 0 {
		return -1
	}
	rd, wr := abi.pipe_ends(fds)
	body := r.here.text
	if !r.here_quoted {
		body = substitute(sh, r.here.text)
	}
	pid := fork_child(sh)
	if pid == 0 {
		libuser.close(rd)
		libuser.write_full(wr, transmute([]u8)body)
		libuser.exits("")
	}
	libuser.close(wr)
	return i64(rd)
}

// substitute replaces `$name` in a here document with the variable's list
// joined by spaces, and `$$` with `$`.
@(private = "file")
substitute :: proc(sh: ^Shell, text: string) -> string {
	out := make([dynamic]u8, 0, len(text) + 64, sh.temp)
	i := 0
	for i < len(text) {
		c := text[i]
		if c != '$' {
			append(&out, c)
			i += 1
			continue
		}
		i += 1
		if i < len(text) && text[i] == '$' {
			append(&out, '$')
			i += 1
			continue
		}
		start := i
		for i < len(text) && idchr(text[i]) {
			i += 1
		}
		if i == start {
			append(&out, '$')
			continue
		}
		append(&out, ..transmute([]u8)join(sh, lookup(sh, text[start:i]), " "))
	}
	return string(out[:])
}

complain :: proc(sh: ^Shell, n: ^Node, what: string) {
	libfmt.fprint(2, "rc: line %d: %s\n", n.line, what)
	set_status(sh, "error")
}
