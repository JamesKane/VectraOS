/*
The root -- an ordinary server, deliberately.

Plan 9's `devroot` is a real device with `rootattach`, `rootwalk`, `rootopen`
and `rootread`, not a special case inside `namec`. Vectra takes the same line,
and gets the same two things out of it. The walker has one code path rather
than one plus a root. And the root becomes rebindable like anything else. A
process that wants a different `/` binds one, and nothing below this comment
has to know. See docs/VECTRA9.md section 7.2.

The tree it serves is the conventional layout from section 5.9 -- empty
directories waiting for the servers that will be bound into them. Convention,
not enforcement: a process is free to build something else, and `Clean` plus a
handful of binds is how it does.

    /bin/     boot images -- the programs the kernel ships, as files
    /dev/     devfs      cons, null, zero, random, draw, mouse, kbd
    /net/     netfs      tcp, udp, ipifc, dns
    /proc/    procfs     one directory per thread
    /ws/      intuition  screen, palette, windows, input
    /srv/     posted channels
    /env/     environment variables, one file each
    /lib/     what the kernel ships that is not a program: scripts
    /mnt/     conventional mount area
*/
package vfs

import "vsys:vectra9"

@(private)
ROOT_NODES := [?]Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "adm", parent = 0, dir = true},
	{name = "bin", parent = 0, dir = true},
	{name = "dev", parent = 0, dir = true},
	{name = "env", parent = 0, dir = true},
	{name = "lib", parent = 0, dir = true},
	{name = "mnt", parent = 0, dir = true},
	{name = "n", parent = 0, dir = true},
	{name = "net", parent = 0, dir = true},
	{name = "proc", parent = 0, dir = true},
	{name = "srv", parent = 0, dir = true},
	{name = "usr", parent = 0, dir = true},
	{name = "ws", parent = 0, dir = true},
	// Where a mounted filesystem goes, by Plan 9 convention: `/n/esp` is the
	// disk the machine booted from, once `fatfs` serves it.
	{name = "esp", parent = 7, dir = true},
	// And the keyboard server's, which `init` mounts so the draw server can
	// read its keys from a file that is not the serial console.
	{name = "kbd", parent = 7, dir = true},
	// Where another machine's tree lands: `import` and `9fs` mount at
	// `/n/host`, and a mount point has to be there first. This root is a
	// static tree, so the names a fleet uses are here by name -- the ones
	// `docs/FLEET.md` and `/lib/ndb/local` give its machines, and `remote`
	// for any other. A `/n` that grows on demand is a later change.
	{name = "fs", parent = 7, dir = true},
	{name = "big", parent = 7, dir = true},
	{name = "desk", parent = 7, dir = true},
	{name = "one", parent = 7, dir = true},
	{name = "two", parent = 7, dir = true},
	{name = "remote", parent = 7, dir = true},
	// Where a session's `factotum` is mounted: the keys a user typed in, and
	// the handshakes run through them. `/mnt` is the sixth entry now that  is first.
	{name = "factotum", parent = 6, dir = true},
	// Where the debugger's engine is mounted, so `db` and the debugger's
	// window find `/mnt/dbg` in any namespace. `docs/DEVTOOLS.md` section 7.
	{name = "dbg", parent = 6, dir = true},
	{name = "wb", parent = 6, dir = true},
	// Where `cpu` mounts the terminal it is a shell for: the far machine binds
	// `/mnt/term/dev` before its own so the shell's console is the terminal's.
	// `docs/FLEET.md` section 7.
	{name = "term", parent = 6, dir = true},
	// Where `#d` binds: a process's own descriptors as files, `/fd/0` and its
	// siblings. `cpu` exports it so a remote command's three are the terminal's.
	// `docs/FLEET.md` section 7. Appended last so no parent index above shifts.
	{name = "fd", parent = 0, dir = true},
	// Where `webfs` is mounted: the web as files, `docs/WEB.md` section 3.
	{name = "web", parent = 6, dir = true},
	// Where the plumber is mounted: messages between programs by rules,
	// `docs/GHOST.md` section 5.
	{name = "plumb", parent = 6, dir = true},
	// Where the first network is mounted, and where a union of conversations
	// is the timeline: `bind -a /mnt/feed/one /mnt/all`. `docs/WEB.md`
	// section 4.
	{name = "feed", parent = 6, dir = true},
	{name = "all", parent = 6, dir = true},
	// Where mail is mounted, `docs/WEB.md` section 6, and a second mail
	// server the self-test runs as the other side of a handshake.
	{name = "mail", parent = 6, dir = true},
	{name = "mail2", parent = 6, dir = true},
	// Where the two social networks are mounted, `docs/WEB.md` section 7:
	// the fediverse and the AT network, each its conversations.
	{name = "fedi", parent = 6, dir = true},
	{name = "at", parent = 6, dir = true},
	// Where chat is mounted, `docs/WEB.md` section 8: a person's rooms.
	{name = "matrix", parent = 6, dir = true},
	// Where the mentions a person's pages drew are mounted, `docs/WEB.md`
	// section 9: the other end of the two-way link.
	{name = "mention", parent = 6, dir = true},
}

// How many conventional directories the root serves, not counting `/` itself.
// Reported at boot, so a layout change shows up in the log rather than only in
// this file.
ROOT_DIRECTORIES :: len(ROOT_NODES) - 1

@(private)
root_tree: Static_Tree
@(private)
root_server: Server

/*
The namespace the kernel itself uses, and the one every first process inherits.

A global because there is nothing to hang it off yet. When there are processes
this becomes `proc.ns` and the global becomes the ancestor every `ns_fork`
descends from -- which is the same object, differently named.
*/
boot_namespace: ^Namespace

/*
init brings up the root device and builds the boot namespace.

Must run after `mem.init`: the fid table, the directory buffer and every chan
come from the heap. Everything before this point in the boot names files by not
naming them at all.
*/
init :: proc() -> Errno {
	if !static_init(&root_tree, ROOT_NODES[:]) {
		return vectra9.ENOMEM
	}
	if err := server_init(&root_server, "/", static_handler, &root_tree); err != .None {
		return vectra9.EPROTO
	}
	if !register_device(&root_server) {
		return vectra9.EEXIST
	}

	boot_namespace = ns_new()
	if boot_namespace == nil {
		return vectra9.ENOMEM
	}

	// Through `#/` rather than a direct call to `attach`. The one path that has
	// to work after a `Clean` fork is therefore the one the kernel itself uses to
	// build a namespace. If the escape hatch is broken, boot says so.
	root, err := device_attach("#/")
	if err != OK {
		return err
	}
	defer chan_close(root)

	return ns_set_root(boot_namespace, root)
}
