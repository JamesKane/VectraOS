/*
ask -- the ghost from a prompt, `docs/GHOST.md` section 4.

    ask [-w dir] [-c class] [-m model] [-g ghostdir] [-k] prompt...

Opens a session on `/mnt/ghost`, writes the prompt, and streams the answer
to the terminal as it comes. When the ghost needs a yes, the question goes
to the terminal and the next line typed is the answer; a descriptor 0 that
ends is no. `-w` names the work directory, `-c` the namespace class, `-m`
the model, and `-g` another ghost's directory. The session is hung up at
the end unless `-k` keeps it, and then its number is the last line, so
`cat /mnt/ghost/N/log` reads every step it took.

The exit word is empty when the ghost finished its turn, and its status
otherwise: `Stopped budget`, `Stopped refusal`.

It is the files and nothing else, so a script does the same with `cat`
and `echo`.
*/
package ask

import "vsys:abi"
import "vsys:libthread"
import "vsys:libuser"

g_dir := "/mnt/ghost"
g_sess: string
sess_buf: [24]u8
g_keep: bool

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	ctl: [4][2]string
	nctl := 0
	prompt: [4096]u8
	n := 0
	i := 1
	for i < len(args) {
		a := args[i]
		if len(a) == 2 && a[0] == '-' && n == 0 {
			if a[1] == 'k' {
				g_keep = true
				i += 1
				continue
			}
			if i + 1 >= len(args) {
				usage()
			}
			switch a[1] {
			case 'w':
				ctl[nctl] = {"work", args[i + 1]}
				nctl += 1
			case 'c':
				ctl[nctl] = {"class", args[i + 1]}
				nctl += 1
			case 'm':
				ctl[nctl] = {"model", args[i + 1]}
				nctl += 1
			case 'g':
				g_dir = args[i + 1]
			case:
				usage()
			}
			i += 2
			continue
		}
		if n > 0 && n < len(prompt) {
			prompt[n] = ' '
			n += 1
		}
		n += copy(prompt[n:], a)
		i += 1
	}
	if n == 0 {
		usage()
	}

	pb: [256]u8
	fd := libuser.open(libuser.cat_into(pb[:], g_dir, "/new"), abi.O_RDONLY)
	if fd < 0 {
		libuser.eprint("ask: no ghost at ", g_dir, "\n")
		libuser.exits("no ghost")
	}
	got := libuser.read(int(fd), sess_buf[:])
	_ = libuser.close(int(fd))
	if got <= 0 {
		libuser.eprint("ask: the ghost has no session to give\n")
		libuser.exits("no session")
	}
	g_sess = trim(string(sess_buf[:got]))
	line: [512]u8
	for c in ctl[:nctl] {
		if !put(pb[:], "ctl", libuser.cat_into(line[:], c[0], " ", c[1])) {
			libuser.eprint("ask: the ghost refused ", c[0], " ", c[1], "\n")
			hangup()
			libuser.exits("ctl")
		}
	}
	if !put(pb[:], "prompt", string(prompt[:n])) {
		libuser.eprint("ask: the ghost refused the prompt\n")
		hangup()
		libuser.exits("prompt")
	}
	libthread.main(threadmain, nil)
}

usage :: proc "contextless" () -> ! {
	libuser.eprint("usage: ask [-w dir] [-c class] [-m model] [-g ghostdir] [-k] prompt...\n")
	libuser.exits("usage")
}

// threadmain streams `reply` to descriptor 1 until the turn ends, with the
// requester's thread beside it.
threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	if libthread.threadcreate(confirm_thread, nil) < 0 {
		libthread.threadexitsall("threadcreate")
	}
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	pb: [256]u8
	fd := libuser.open(path(pb[:], "reply"), abi.O_RDONLY)
	if fd < 0 {
		libthread.threadexitsall("reply")
	}
	buf: [4096]u8
	last := u8('\n')
	for {
		got := libthread.ioread(io, int(fd), buf[:])
		if got <= 0 {
			break
		}
		_ = libuser.write_full(1, buf[:got])
		last = buf[got - 1]
	}
	if last != '\n' {
		_ = libuser.write_full(1, transmute([]u8)string("\n"))
	}
	_ = libuser.close(int(fd))

	// The status says whether the turn finished or stopped, and why.
	status: [128]u8
	word := ""
	if sfd := libuser.open(path(pb[:], "status"), abi.O_RDONLY); sfd >= 0 {
		got := libuser.read(int(sfd), status[:])
		_ = libuser.close(int(sfd))
		if got > 0 {
			word = trim(string(status[:got]))
		}
	}
	if g_keep {
		_ = libuser.write_full(1, transmute([]u8)g_sess)
		_ = libuser.write_full(1, transmute([]u8)string("\n"))
	} else {
		hangup()
	}
	libthread.threadexitsall(word == "Idle" ? "" : word)
}

/*
confirm_thread answers the requester from the terminal: the question on
descriptor 2, a line from descriptor 0 as the answer. It parks on
`confirm` through an io proc of its own, and so does its read of the line.
When `confirm` ends, the turn has, and so does this thread.
*/
confirm_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexits("")
	}
	pb: [256]u8
	fd := libuser.open(path(pb[:], "confirm"), abi.O_RDWR)
	if fd < 0 {
		libthread.threadexits("")
	}
	q: [1024]u8
	a: [256]u8
	for {
		got := libthread.ioread(io, int(fd), q[:])
		if got <= 0 {
			break
		}
		libuser.eprint("ghost: ", trim(string(q[:got])), "? ")
		n := 0
		for n < len(a) {
			r := libthread.ioread(io, 0, a[n:n + 1])
			if r <= 0 || a[n] == '\n' {
				break
			}
			n += 1
		}
		answer := trim(string(a[:n]))
		if answer == "" {
			answer = "no"
		}
		_ = libthread.iowrite(io, int(fd), transmute([]u8)answer)
	}
	_ = libuser.close(int(fd))
	libthread.threadexits("")
}

path :: proc "contextless" (buf: []u8, file: string) -> string {
	return libuser.cat_into(buf, g_dir, "/", g_sess, "/", file)
}

// put writes one line to a session file, and says whether it was taken.
put :: proc "contextless" (buf: []u8, file: string, text: string) -> bool {
	fd := libuser.open(path(buf, file), abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	w := libuser.write(int(fd), transmute([]u8)text)
	_ = libuser.close(int(fd))
	return w == i64(len(text))
}

hangup :: proc "contextless" () {
	pb: [256]u8
	_ = put(pb[:], "ctl", "hangup")
}

trim :: proc "contextless" (s: string) -> string {
	b := 0
	e := len(s)
	for b < e && (s[b] == ' ' || s[b] == '\n' || s[b] == '\t') {
		b += 1
	}
	for e > b && (s[e - 1] == ' ' || s[e - 1] == '\n' || s[e - 1] == '\t') {
		e -= 1
	}
	return s[b:e]
}
