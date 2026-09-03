/*
The commands that have to run in the shell's own process, because they
change it: its directory, its variables, its arguments, its descriptors
or its life. Everything else is a program.
*/
package rc

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"
import "vsys:vectra9"

is_builtin :: proc(name: string) -> bool {
	switch name {
	case ".", "builtin", "cd", "eval", "exit", "flag", "rfork", "shift", "wait", "whatis":
		return true
	}
	return false
}

run_builtin :: proc(sh: ^Shell, argv: []string) {
	switch argv[0] {
	case ".":
		builtin_dot(sh, argv[1:])
	case "builtin":
		if len(argv) < 2 {
			set_status(sh, "")
			return
		}
		if is_builtin(argv[1]) {
			run_builtin(sh, argv[1:])
		} else {
			run_program(sh, argv[1:], nil)
		}
	case "cd":
		builtin_cd(sh, argv[1:])
	case "eval":
		builtin_eval(sh, argv[1:])
	case "exit":
		if len(argv) > 1 {
			set_status(sh, argv[1])
		}
		sh.exiting = true
	case "flag":
		builtin_flag(sh, argv[1:])
	case "rfork":
		builtin_rfork(sh, argv[1:])
	case "shift":
		n := 1
		if len(argv) > 1 {
			if v, ok := atoi(argv[1]); ok {
				n = v
			}
		}
		if n > len(sh.argv) {
			n = len(sh.argv)
		}
		rest := clone_list(sh.argv[n:])
		free_list(sh.argv)
		sh.argv = rest
		set_status(sh, "")
	case "wait":
		builtin_wait(sh, argv[1:])
	case "whatis":
		builtin_whatis(sh, argv[1:])
	}
}

// builtin_exec replaces the shell with a program, its redirections
// already applied. With no program it is the redirections alone, kept.
builtin_exec :: proc(sh: ^Shell, argv: []string) {
	if len(argv) == 0 {
		set_status(sh, "")
		return
	}
	exec_program(sh, argv)
	set_status(sh, "exec")
}

@(private = "file")
builtin_cd :: proc(sh: ^Shell, args: []string) {
	dir := ""
	if len(args) > 0 {
		dir = args[0]
	} else {
		home := lookup(sh, "home")
		dir = len(home) > 0 ? home[0] : "/"
	}
	if r := libuser.chdir(dir); r < 0 {
		libfmt.fprint(2, "rc: can't cd %s: %s\n", dir, libuser.errstr(r))
		set_status(sh, "can't cd")
		return
	}
	set_status(sh, "")
}

// builtin_dot runs a file here, with `$*` set to the arguments after it.
// `-i` makes the file interactive: prompts, and errors that do not end it.
@(private = "file")
builtin_dot :: proc(sh: ^Shell, args_in: []string) {
	args := args_in
	interactive := false
	if len(args) > 0 && args[0] == "-i" {
		interactive = true
		args = args[1:]
	}
	if len(args) == 0 {
		set_status(sh, "usage")
		return
	}
	in_: Input
	if args[0] == "/dev/cons" || args[0] == "/fd/0" {
		input_from_fd(&in_, 0, interactive)
	} else {
		data, ok := read_file(args[0])
		if !ok {
			libfmt.fprint(2, "rc: %s: can't open\n", args[0])
			set_status(sh, "can't open")
			return
		}
		input_from_string(&in_, string(data))
		delete(data)
	}
	saved_argv := sh.argv
	saved_arg0 := sh.arg0
	saved_interactive := sh.interactive
	sh.argv = clone_list(args[1:])
	sh.arg0 = args[0]
	sh.interactive = interactive
	run_input(sh, &in_)
	free_list(sh.argv)
	sh.argv = saved_argv
	sh.arg0 = saved_arg0
	sh.interactive = saved_interactive
	input_free(&in_)
}

@(private = "file")
builtin_eval :: proc(sh: ^Shell, args: []string) {
	text := join(sh, args, " ")
	in_: Input
	input_from_string(&in_, cat2(sh, text, "\n"))
	saved := sh.interactive
	sh.interactive = false
	run_input(sh, &in_)
	sh.interactive = saved
	input_free(&in_)
}

// builtin_flag tests a flag (`flag x`) or sets one (`flag x +`, `flag x -`).
@(private = "file")
builtin_flag :: proc(sh: ^Shell, args: []string) {
	if len(args) == 0 || len(args[0]) != 1 {
		set_status(sh, "usage")
		return
	}
	f := args[0][0]
	if len(args) == 1 {
		set_status(sh, sh.flags[f] ? "" : "flag not set")
		return
	}
	sh.flags[f] = args[1] == "+"
	set_status(sh, "")
}

// builtin_rfork is the flags by letter, Plan 9's: n N e E s f F m.
@(private = "file")
builtin_rfork :: proc(sh: ^Shell, args: []string) {
	flags: u64
	letters := len(args) > 0 ? args[0] : "ens"
	for i in 0 ..< len(letters) {
		switch letters[i] {
		case 'n':
			flags |= abi.RFNAMEG
		case 'N':
			flags |= abi.RFCNAMEG
		case 'e':
			flags |= abi.RFENVG
		case 'E':
			flags |= abi.RFCENVG
		case 's':
			flags |= abi.RFNOTEG
		case 'f':
			flags |= abi.RFFDG
		case 'F':
			flags |= abi.RFCFDG
		case 'm':
			flags |= abi.RFNOMNT
		case:
			libfmt.fprint(2, "rc: rfork: bad flag %c\n", letters[i])
			set_status(sh, "usage")
			return
		}
	}
	if r := libuser.rfork(flags); r < 0 {
		set_status(sh, libuser.errstr(r))
		return
	}
	set_status(sh, "")
}

// builtin_wait collects a named child, or every child there is.
@(private = "file")
builtin_wait :: proc(sh: ^Shell, args: []string) {
	if len(args) > 0 {
		pid, pok := atoi(args[0])
		if !pok {
			set_status(sh, "usage")
			return
		}
		set_status(sh, wait_for(sh, i64(pid)))
		return
	}
	buf: [128]u8
	last := ""
	for {
		n := libuser.await(0, buf[:])
		if n == -i64(vectra9.EAGAIN) {
			continue
		}
		if n < 0 {
			break
		}
		last = word_after_pid(sh, buf[:n])
	}
	set_status(sh, last)
}

// builtin_whatis prints what each name is: a variable with its value, a
// function, a builtin, or the program `$path` would find.
@(private = "file")
builtin_whatis :: proc(sh: ^Shell, args: []string) {
	missing := false
	for name in args {
		found := false
		if vi := find_var(sh, name); vi >= 0 {
			libfmt.print("%s=%s\n", name, quoted_list(sh, sh.vars[vi].list))
			found = true
		}
		if find_fn(sh, name) >= 0 {
			libfmt.print("fn %s {...}\n", name)
			found = true
		}
		if is_builtin(name) || name == "exec" {
			libfmt.print("builtin %s\n", name)
			found = true
		}
		if !found {
			path := lookup(sh, "path")
			if len(path) == 0 {
				path = []string{".", "/bin"}
			}
			for dir in path {
				full := path_join(sh, dir, name)
				if exists(full) {
					libfmt.print("%s\n", full)
					found = true
					break
				}
			}
		}
		if !found {
			libfmt.fprint(2, "%s: not found\n", name)
			missing = true
		}
	}
	set_status(sh, missing ? "not found" : "")
}

// quoted_list prints a list the way rc would read it back.
@(private = "file")
quoted_list :: proc(sh: ^Shell, list: []string) -> string {
	parts := make([]string, len(list), sh.temp)
	for s, i in list {
		parts[i] = quote(sh, s)
	}
	if len(parts) == 1 {
		return parts[0]
	}
	return cat2(sh, cat2(sh, "(", join(sh, parts, " ")), ")")
}

@(private = "file")
quote :: proc(sh: ^Shell, s: string) -> string {
	needs := len(s) == 0
	for i in 0 ..< len(s) {
		if !wordchr(s[i]) || s[i] == '*' || s[i] == '?' || s[i] == '[' || s[i] == '=' {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	out := make([dynamic]u8, 0, len(s) + 2, sh.temp)
	append(&out, '\'')
	for i in 0 ..< len(s) {
		if s[i] == '\'' {
			append(&out, '\'')
		}
		append(&out, s[i])
	}
	append(&out, '\'')
	return string(out[:])
}
