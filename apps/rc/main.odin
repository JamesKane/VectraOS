/*
rc -- Plan 9's shell, in Odin.

    rc [-c command] [-eix] [file [arg ...]]

Reads commands from the string after `-c`, from the file, or from
descriptor 0, in that order of preference, and runs each line as it is
read. Descriptor 0 with no file and no `-c` is interactive: `$prompt(1)`
before a command and `$prompt(2)` before its continuation, and a syntax
error costs the line and not the session. `-i` makes a file interactive
too, `-e` ends a script at the first command that fails, and `-x` prints
each command before it runs.

The grammar is `parse.odin`, the walk is `exec.odin`, and `rcmain`, built
into the image, runs first and gives `$path`, `$prompt`, `$ifs` and
`$home` their defaults when `/env` did not.

What Plan 9's rc has that this does not, yet: `<{cmd}` and `>{cmd}`,
which need `/fd`; the `` `` `` form of backquote with its own separators;
functions in `/env` as `fn#name`; and notes, which is `^C`.
*/
package rc

import "base:runtime"
import "core:mem"

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"
import "vsys:vectra9"

Var_Entry :: struct {
	name:  string, // on the heap
	list:  []string, // on the heap
	dirty: bool, // set since `/env` last saw it; `updenv` writes it before an exec
}

Fn_Entry :: struct {
	name: string,
	body: ^Node, // adopted from the line that defined it; never freed
}

// The variables and functions are tables searched by name. A shell holds
// dozens of either, and a table that small is faster to scan than to hash.
Shell :: struct {
	vars:        [dynamic]Var_Entry,
	fns:         [dynamic]Fn_Entry,
	argv:        []string, // $*, on the heap
	arg0:        string, // $0
	status_buf:  [STATUS_MAX]u8,
	status_len:  int,
	last_if:     bool,
	flags:       [256]bool,
	flag_error:  bool, // a word failed to evaluate; the command is not run
	exiting:     bool,
	interactive: bool,
	depth:       int, // nested inputs: `.` and `eval` inside a line
	arena:       mem.Dynamic_Arena,
	temp:        runtime.Allocator,
}

RCMAIN := #load("rcmain", string)

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	main(libuser.args(block))
}

main :: proc(args: []string) {
	sh := new(Shell)
	the_shell = sh
	mem.dynamic_arena_init(&sh.arena, context.allocator, context.allocator, 32 * 1024)
	sh.temp = mem.dynamic_arena_allocator(&sh.arena)
	context.temp_allocator = sh.temp
	sh.vars = make([dynamic]Var_Entry)
	sh.fns = make([dynamic]Fn_Entry)
	sh.arg0 = len(args) > 0 ? args[0] : "rc"

	command := ""
	has_command := false
	file := ""
	rest := args[1:] if len(args) > 0 else nil
	for len(rest) > 0 && len(rest[0]) > 1 && rest[0][0] == '-' {
		opt := rest[0]
		rest = rest[1:]
		for i in 1 ..< len(opt) {
			switch opt[i] {
			case 'c':
				if len(rest) == 0 {
					libfmt.fprint(2, "rc: -c wants a command\n")
					libuser.exits("usage")
				}
				command = rest[0]
				has_command = true
				rest = rest[1:]
			case 'e', 'i', 'x', 's', 'l', 'v':
				sh.flags[opt[i]] = true
			case:
				libfmt.fprint(2, "rc: unknown flag -%c\n", opt[i])
				libuser.exits("usage")
			}
		}
	}
	if !has_command && len(rest) > 0 {
		file = rest[0]
		rest = rest[1:]
	}
	sh.argv = clone_list(rest)

	import_env(sh)
	set_pid(sh)
	// A typed `^C` is `interrupt` to this shell's group. The command it is
	// running has no handler and ends; the shell has this one and does
	// not, which is what Plan 9's rc does with its own.
	_ = libuser.notify(uintptr(rawptr(note_handler)))

	// The defaults, from the file in the image.
	boot: Input
	input_from_string(&boot, RCMAIN)
	run_input(sh, &boot)
	input_free(&boot)
	mem.dynamic_arena_free_all(&sh.arena)

	in_: Input
	switch {
	case has_command:
		sh.flags['c'] = true
		input_from_string(&in_, cat2(sh, command, "\n"))
	case len(file) > 0:
		data, ok := libuser.read_file(file, context.allocator)
		if !ok {
			libfmt.fprint(2, "rc: %s: can't open\n", file)
			libuser.exits("can't open")
		}
		sh.arg0 = file
		input_from_string(&in_, string(data))
	case:
		sh.interactive = true
		sh.flags['i'] = true
		input_from_fd(&in_, 0, true)
	}
	if sh.flags['i'] {
		sh.interactive = true
	}
	run_input(sh, &in_)
	libuser.exits(status(sh))
}

/*
run_input reads, parses and runs lines until the input ends or `exit`.
The temporary arena is reset after each line at the top level only: a
nested input (`.`, `eval`) is inside a line that is still running.
*/
run_input :: proc(sh: ^Shell, in_: ^Input) {
	lx: Lexer
	lexer_init(&lx, in_)
	defer lexer_free(&lx)
	p := Parser{lx = &lx}
	depth := sh.depth
	sh.depth += 1
	defer sh.depth -= 1

	for !sh.exiting {
		n := parse_line(&p)
		if n == nil {
			break
		}
		if p.err || lx.err {
			set_status(sh, "syntax error")
			free_tree(n)
			if !sh.interactive {
				break
			}
			in_.prompt = 1
			continue
		}
		run(sh, n)
		free_tree(n)
		// A whole line ran: the next read is a new command, which gets the
		// first prompt again rather than the continuation's.
		in_.prompt = 1
		if depth == 0 {
			mem.dynamic_arena_free_all(&sh.arena)
		}
	}
}

// set_pid is `$pid`, this process's own, set at startup and again in every
// child the shell forks, which is a different process with the same tables.
set_pid :: proc(sh: ^Shell) {
	one := make([]string, 1, sh.temp)
	if one == nil {
		libfmt.fprint(2, "rc: out of memory\n")
		libuser.exits("out of memory")
	}
	one[0] = itoa(sh, int(libuser.getpid()))
	set_var(sh, "pid", one)
}

// note_handler is what the kernel calls with a note. An interrupt is
// taken and continued from; anything else takes the default, which ends
// the shell as it would any program.
note_handler :: proc "c" (ureg: rawptr, note: cstring) {
	_ = ureg
	if string(note) == "interrupt" {
		libuser.noted(abi.NCONT)
	}
	libuser.noted(abi.NDFLT)
}

// show_prompt writes `$prompt(which)` for an interactive read.
show_prompt :: proc(which: int) {
	sh := the_shell
	if sh == nil {
		return
	}
	prompt := lookup(sh, "prompt")
	if which > len(prompt) {
		return
	}
	// A note is delivered at the next system call, and after a `^C` that is
	// this write: it answers EINTR with nothing written, and the prompt is
	// asked for again.
	for {
		text := transmute([]u8)prompt[which - 1]
		n := libuser.write(2, text)
		if n != -i64(vectra9.EINTR) {
			if n > 0 && int(n) < len(text) {
				_ = libuser.write_full(2, text[n:])
			}
			return
		}
	}
}

the_shell: ^Shell

define :: proc(sh: ^Shell, name: string, body: ^Node) {
	undefine(sh, name)
	append(&sh.fns, Fn_Entry{name = clone(name), body = body})
}

undefine :: proc(sh: ^Shell, name: string) {
	i := find_fn(sh, name)
	if i < 0 {
		return
	}
	delete(sh.fns[i].name)
	unordered_remove(&sh.fns, i)
}

find_fn :: proc(sh: ^Shell, name: string) -> int {
	for e, i in sh.fns {
		if e.name == name {
			return i
		}
	}
	return -1
}

find_var :: proc(sh: ^Shell, name: string) -> int {
	for e, i in sh.vars {
		if e.name == name {
			return i
		}
	}
	return -1
}
