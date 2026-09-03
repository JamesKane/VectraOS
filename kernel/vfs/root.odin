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
	{name = "esp", parent = 6, dir = true},
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
	if !static_init(&root_tree, "root", ROOT_NODES[:]) {
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
