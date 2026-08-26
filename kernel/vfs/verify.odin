/*
The namespace self-test, run on the machine that will use it.

Every claim `docs/VECTRA9.md` section 5 makes is checked here against two real
servers and real 9P traffic -- no stubs, and nothing that would pass if the
mount table were a lookup table with a fancier name. The ones worth naming:

  - a union searched in mount order, with the first member winning a name both
    members have
  - a directory read that concatenates members and does *not* filter duplicates
  - `..` out of the root of a mounted tree, landing on a server that has never
    heard of the tree it just left
  - a `Copy` fork that diverges, and a `Clean` fork with no way to name anything

The last of those is the one to watch. A `Clean` namespace that could still
reach a file would be a sandbox with a hole in it, and it would look exactly
like a working one from anywhere else.
*/
package vfs

import "vsys:vectra9"

Verify_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string, // What went wrong first, for a one-line log
	union_entries: int, // Names a union directory listed, duplicates included
	mounts:        int, // Mount points the test namespace ended up with
}

@(private = "file")
check :: proc(r: ^Verify_Result, ok: bool, what: string) -> bool {
	r.checks += 1
	if !ok {
		r.failures += 1
		if r.first_failure == "" {
			r.first_failure = what
		}
	}
	return ok
}

// -- Fixtures ----------------------------------------------------------------

@(private = "file")
ALPHA_NODES := [?]Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "cons", parent = 0, data = "alpha console\n"},
	{name = "sub", parent = 0, dir = true},
	{name = "deep", parent = 2, data = "deep\n"},
}

// `cons` on purpose: both trees have it, so the union has a duplicate to not
// filter and a first-member-wins rule to get right.
@(private = "file")
BETA_NODES := [?]Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "cons", parent = 0, data = "beta console\n"},
	{name = "mouse", parent = 0, data = "beta mouse\n"},
}

@(private = "file")
alpha_tree: Static_Tree
@(private = "file")
alpha_server: Server
@(private = "file")
beta_tree: Static_Tree
@(private = "file")
beta_server: Server

// -- Helpers -----------------------------------------------------------------

@(private = "file")
read_file :: proc(ns: ^Namespace, path: string, buf: []u8) -> (string, Errno) {
	c, err := open_path(ns, path)
	if err != OK {
		return "", err
	}
	defer chan_close(c)

	n: int
	n, err = chan_read(c, 0, buf)
	if err != OK {
		return "", err
	}
	return string(buf[:n]), OK
}

/*
list_dir walks a whole directory listing, following the opaque cookies.

Bounded by `MAX_LISTING_PASSES` rather than trusting the loop to end: a server
that returned the same cookie twice, or a union that failed to advance past an
exhausted member, would otherwise spin here forever instead of failing.
*/
@(private = "file")
MAX_LISTING_PASSES :: 32

@(private = "file")
list_dir :: proc(
	ns: ^Namespace,
	path: string,
	buf: []u8,
	want: string,
) -> (
	total: int,
	matches: int,
	first_match: int, // Position of `want` in the listing; -1 if absent
	err: Errno,
) {
	first_match = -1
	c: ^Chan
	c, err = open_path(ns, path, O_RDONLY | O_DIRECTORY)
	if err != OK {
		return
	}
	defer chan_close(c)

	offset := u64(0)
	for pass in 0 ..< MAX_LISTING_PASSES {
		_ = pass
		n: int
		n, err = readdir(c, offset, buf)
		if err != OK {
			return
		}
		if n == 0 {
			return
		}

		cursor := vectra9.cursor_from(buf[:n])
		for {
			entry, more := vectra9.next_dirent(&cursor)
			if !more {
				break
			}
			if entry.name == want {
				matches += 1
				if first_match < 0 {
					first_match = total
				}
			}
			total += 1
			offset = entry.offset
		}
	}
	return total, matches, first_match, vectra9.ELOOP
}

// -- The test ----------------------------------------------------------------

/*
verify exercises the namespace layer and reports what failed.

`buf` is the caller's scratch: file contents and directory listings are read
into it, so it wants to be a few hundred bytes at least. It is borrowed for the
duration and nothing here holds onto it.

Everything allocated is released before returning, including on the failure
paths, so a failed self-test does not also leak the heap it was testing on.
*/
verify :: proc(buf: []u8) -> Verify_Result {
	r: Verify_Result

	if !check(&r, boot_namespace != nil, "boot namespace exists") {
		return r
	}
	if !check(&r, static_init(&alpha_tree, "alpha", ALPHA_NODES[:]), "alpha server tables") {
		return r
	}
	defer static_destroy(&alpha_tree)
	if !check(&r, static_init(&beta_tree, "beta", BETA_NODES[:]), "beta server tables") {
		return r
	}
	defer static_destroy(&beta_tree)

	check(
		&r,
		server_init(&alpha_server, "alpha", static_handler, &alpha_tree) == .None,
		"alpha Tversion",
	)
	check(
		&r,
		server_init(&beta_server, "beta", static_handler, &beta_tree) == .None,
		"beta Tversion",
	)

	// A copy, so the binds below cannot leave the boot namespace rearranged.
	ns := ns_fork(boot_namespace, {.Copy})
	if !check(&r, ns != nil, "Copy fork") {
		return r
	}
	defer ns_close(ns)

	verify_paths(&r, ns, buf)
	verify_union(&r, ns, buf)
	verify_dotdot(&r, ns)
	verify_forks(&r, ns, buf)
	verify_protocol_rules(&r)

	r.mounts = ns.mount_count
	return r
}

@(private = "file")
verify_paths :: proc(r: ^Verify_Result, ns: ^Namespace, buf: []u8) {
	root, err := resolve(ns, "/")
	if check(r, err == OK && chan_is_dir(root), "resolve / is a directory") {
		chan_close(root)
	}

	dev: ^Chan
	dev, err = resolve(ns, "/dev")
	if check(r, err == OK && chan_is_dir(dev), "resolve /dev from the root server") {
		chan_close(dev)
	}

	_, err = resolve(ns, "/nope")
	check(r, err == vectra9.ENOENT, "a name that is not there is ENOENT")

	// No process, so nothing for a relative path to be relative to. Refused
	// rather than quietly treated as absolute.
	_, err = resolve(ns, "dev")
	check(r, err == vectra9.EINVAL, "a relative path is refused")

	// Section 5.8's escape: `#/` reaches the root device without a namespace.
	var_root: ^Chan
	var_root, err = resolve(ns, "#/")
	if check(r, err == OK && chan_is_dir(var_root), "#/ attaches the root device") {
		chan_close(var_root)
	}

	// Now bind a real server over /dev and read out of it. Two servers are
	// involved in `/dev/cons` from here on, which is the point.
	src: ^Chan
	src, err = attach(&alpha_server)
	if !check(r, err == OK, "attach alpha") {
		return
	}
	defer chan_close(src)

	over: ^Chan
	over, err = resolve_mount_point(ns, "/dev")
	if !check(r, err == OK, "resolve /dev as a mount point") {
		return
	}
	defer chan_close(over)

	check(r, bind(ns, src, over, .Replace) == OK, "bind alpha over /dev")

	text: string
	text, err = read_file(ns, "/dev/cons", buf)
	check(r, err == OK && text == "alpha console\n", "read /dev/cons crosses to alpha")

	text, err = read_file(ns, "/dev/sub/deep", buf)
	check(r, err == OK && text == "deep\n", "read two levels inside a mounted tree")

	_, err = resolve(ns, "/dev/sub/nope")
	check(r, err == vectra9.ENOENT, "a missing name inside a mounted tree is ENOENT")

	// The static server is read-only and says so with EROFS, not EOPNOTSUPP:
	// there is such an operation and the client may not have it.
	_, err = open_path(ns, "/dev/cons", O_WRONLY)
	check(r, err == vectra9.EROFS, "opening a read-only file for writing is EROFS")
}

@(private = "file")
verify_union :: proc(r: ^Verify_Result, ns: ^Namespace, buf: []u8) {
	if bind_path(ns, "#beta-unused", "/dev", .After) == OK {
		check(r, false, "a bogus device spec must not bind")
	}

	src, err := attach(&beta_server)
	if !check(r, err == OK, "attach beta") {
		return
	}
	defer chan_close(src)

	over: ^Chan
	over, err = resolve_mount_point(ns, "/dev")
	if !check(r, err == OK, "resolve /dev as a mount point again") {
		return
	}
	defer chan_close(over)

	check(r, bind(ns, src, over, .After) == OK, "bind beta after alpha on /dev")

	// The second bind must have joined the existing mount point rather than
	// keying a new one on alpha's root. Two members, one union.
	mp := mount_head(ns, over)
	check(r, member_count(mp) == 2, "/dev is a union of two members")

	/*
	The chan a union resolves to is its *first* member -- so `stat /dev`
	describes alpha, the same tree `open /dev/cons` reaches. Checked on the
	chan's own identity because nothing else can see it: names are resolved by
	searching the member list, and a listing is assembled from the member list,
	so both come out right even if the crossing picked the wrong member.
	*/
	dev: ^Chan
	dev, err = resolve(ns, "/dev")
	if check(r, err == OK, "resolve /dev after the second bind") {
		check(r, dev.server == &alpha_server, "a union directory is its first member")
		check(r, dev.union_head == mp, "and remembers the mount point it came through")
		chan_close(dev)
	}

	text: string
	text, err = read_file(ns, "/dev/mouse", buf)
	check(r, err == OK && text == "beta mouse\n", "a name only beta has resolves")

	text, err = read_file(ns, "/dev/cons", buf)
	check(r, err == OK && text == "alpha console\n", "a name both have resolves to the first")

	// Four names across two trees, `cons` among them twice. Duplicates are not
	// filtered -- section 5.6, and Plan 9's call.
	total, matches, _, lerr := list_dir(ns, "/dev", buf, "cons")
	r.union_entries = total
	check(r, lerr == OK, "the union listing terminates")
	check(r, total == 4, "the union lists every member's entries")
	check(r, matches == 2, "a duplicated name is listed twice, not filtered")

	// Alpha holds `cons` and `sub`, beta holds `cons` and `mouse`. In mount
	// order that puts `mouse` last, and nowhere else -- which is what catches a
	// union that concatenates its members backwards, a bug every count-based
	// check above is blind to because the counts come out the same either way.
	_, _, at, merr := list_dir(ns, "/dev", buf, "mouse")
	check(r, merr == OK && at == 3, "members are listed in mount order")

	// Section 7.4: creation goes to the member flagged Create, and there is no
	// such member here, so there is no target rather than a guess.
	check(r, union_create_target(mp) == nil, "no Create flag means no create target")
}

@(private = "file")
verify_dotdot :: proc(r: ^Verify_Result, ns: ^Namespace) {
	sub, err := resolve(ns, "/dev/sub")
	if !check(r, err == OK, "resolve /dev/sub") {
		return
	}
	defer chan_close(sub)

	// One step up is still inside alpha: the server can name this one.
	up: ^Chan
	up, err = walk1(ns, sub, "..")
	if !check(r, err == OK && up.server == &alpha_server, ".. inside a tree stays in it") {
		return
	}
	defer chan_close(up)

	// One more step leaves alpha entirely. Alpha has no name for where this
	// lands, has never heard of the root server, and is not asked.
	out: ^Chan
	out, err = walk1(ns, up, "..")
	if !check(
		r,
		err == OK && out.server == &root_server,
		".. out of a mounted root crosses to the mount point's server",
	) {
		return
	}
	defer chan_close(out)

	check(r, out.qid.path == ns.root.qid.path, ".. from /dev lands on /")

	// And there is no escaping upward, which is what makes a chroot free.
	top: ^Chan
	top, err = walk1(ns, out, "..")
	if check(r, err == OK && top.qid.path == ns.root.qid.path, ".. at the root is the root") {
		chan_close(top)
	}
}

@(private = "file")
verify_forks :: proc(r: ^Verify_Result, ns: ^Namespace, buf: []u8) {
	child := ns_fork(ns, {.Copy})
	if !check(r, child != nil, "Copy fork inherits") {
		return
	}
	defer ns_close(child)

	text, err := read_file(child, "/dev/cons", buf)
	check(r, err == OK && text == "alpha console\n", "a copied namespace starts identical")

	check(r, unmount_path(child, "", "/dev") == OK, "unmount /dev in the child")

	_, err = resolve(child, "/dev/cons")
	check(r, err == vectra9.ENOENT, "the child diverges")

	text, err = read_file(ns, "/dev/cons", buf)
	check(r, err == OK && text == "alpha console\n", "the parent is unaffected")

	// Clean: no root, no mounts, no names. A sandbox with nothing to escape.
	clean := ns_fork(ns, {.Clean})
	if !check(r, clean != nil, "Clean fork") {
		return
	}
	defer ns_close(clean)

	check(r, clean.root == nil && clean.mount_count == 0, "a Clean namespace is empty")
	_, err = resolve(clean, "/dev/cons")
	check(r, err == vectra9.ENOENT, "a Clean namespace can name nothing")

	// The one way back: `#name`, which is why it exists.
	recovered: ^Chan
	recovered, err = device_attach("#/")
	if check(r, err == OK, "#/ recovers a Clean namespace") {
		check(r, ns_set_root(clean, recovered) == OK, "the recovered chan can be a root")
		chan_close(recovered)

		rebuilt: ^Chan
		rebuilt, err = resolve(clean, "/dev")
		if check(r, err == OK, "and the rebuilt namespace resolves") {
			chan_close(rebuilt)
		}
	}

	// Sharing is the default, and it is a share rather than a copy.
	shared := ns_fork(ns, {})
	check(r, shared == ns, "the default fork shares")
	ns_close(shared)
}

/*
verify_protocol_rules checks the two things section 7.3 says are the protocol's
rather than any server's policy.

Only the first is testable without a scheduler: Tflush can never be answered
with an error, so a server with nothing pending still answers Rflush. The
second -- that a flushed request may still be answered -- needs two requests in
flight, and a synchronous transport never has them.
*/
@(private = "file")
verify_protocol_rules :: proc(r: ^Verify_Result) {
	request := vectra9.Msg(vectra9.Tflush{oldtag = vectra9.Tag(1)})
	reply: vectra9.Msg
	err := vectra9.call(&root_server.session, &request, &reply)
	if !check(r, err == .None, "Tflush reaches the server") {
		return
	}
	_, ok := reply.(vectra9.Rflush)
	check(r, ok, "Tflush is never answered with an error")
}
