/*
Starting a server at boot.

A filesystem server is a program: it opens a device, posts a name in
`/srv`, and forks, so that the process that started it sees the parent exit
once the name exists and can mount on its next line. A shell does that in
two lines. The boot does it here, before there is a shell, for the server
that carries the shell's tools -- `fatfs` over the disk.

`start_server` is the two lines in kernel terms: spawn the program from the
boot namespace with the arguments given, wait for the parent to exit, and
say what its exit word was. An empty word is the memfs convention for "the
name is posted"; anything else is why it is not. The caller mounts.
*/
package user

import "kernel:vfs"

// SERVER_PATIENCE is how long a server's parent may take to post and exit:
// it reads a device and a partition table, which is a handful of disk
// requests on an emulated core.
SERVER_PATIENCE :: 2000

/*
start_server runs `path` with `names` as its arguments and waits for it to
exit. `said` is the exit word, copied into `into`; `ok` is a deliberate
exit with an empty word, which is a server that posted. A program that
faulted, or said something, or did not come back in time, is `ok` false
with the word or the reason in `said`.
*/
start_server :: proc(path: string, names: []string, into: []u8) -> (said: string, ok: bool) {
	argv := new(Argv)
	if argv == nil {
		return "no memory for the arguments", false
	}
	defer free(argv)
	if !argv_from(argv, names) {
		return "too many arguments", false
	}
	p, serr := spawn_path(nil, path, SPAWN_NS_COPY, argv)
	if serr != vfs.OK || p == nil {
		n := copy(into, "did not start")
		return string(into[:n]), false
	}
	if !wait(p, SERVER_PATIENCE) {
		n := copy(into, "did not come back")
		return string(into[:n]), false
	}
	n := copy(into, p.exit.text[:p.exit.text_len])
	said = string(into[:n])
	ok = p.exit.deliberate && n == 0
	if !p.exit.deliberate {
		n = copy(into, "faulted")
		said = string(into[:n])
	}
	_ = destroy(p)
	return said, ok
}

/*
start_program runs `path` with `names` and does not wait: the program is
the machine's from here on. For `init`, which the boot starts last and
which becomes the shell on the console. Answers whether it started.
*/
start_program :: proc(path: string, names: []string) -> bool {
	argv := new(Argv)
	if argv == nil {
		return false
	}
	defer free(argv)
	if !argv_from(argv, names) {
		return false
	}
	p, serr := spawn_path(nil, path, SPAWN_NS_COPY, argv)
	return serr == vfs.OK && p != nil
}
