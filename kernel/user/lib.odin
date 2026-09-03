/*
`#l` at `/lib`: what the kernel ships that is not a program.

Plan 9 keeps its shared files under `/lib` and its shell's under `/rc/lib`.
Until the disk, the kernel image is the only place a file can come from,
so the few the tree needs are embedded here and served read-only like
`/bin`'s programs: the shell's own test script first, and whatever a later
step wants a program to read at boot.

    /lib/tests/tools.rc    the script `verify_tools` runs the shell on
*/
package user

import "kernel:vfs"
import "vsys:vectra9"

TOOLS_RC := #load("../../tests/tools.rc")

@(private = "file")
lib_nodes: [3]vfs.Static_Node

@(private = "file")
lib_tree: vfs.Static_Tree

@(private = "file")
lib_server: vfs.Server

// lib_init brings `#l` up and binds it at `/lib`. Runs beside `bin_init`.
lib_init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	lib_nodes = {
		{name = "/", parent = -1, dir = true},
		{name = "tests", parent = 0, dir = true},
		{name = "tools.rc", parent = 1, data = string(TOOLS_RC)},
	}
	if !vfs.static_init(&lib_tree, "lib", lib_nodes[:3]) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&lib_server, "l", vfs.static_handler, &lib_tree); err != .None {
		return vectra9.EPROTO
	}
	if !vfs.register_device(&lib_server) {
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#l", "/lib")
}
