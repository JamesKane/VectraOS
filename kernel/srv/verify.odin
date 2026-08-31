/*
The `/srv` self-test: a service published by name, mounted, and taken away.

Against the boot namespace, over the real mount at `/srv`, through the real
`#s`. The fixtures are two ordinary `vfs.Static_Tree` servers, because what is
under test is the publishing rather than the service.

Five claims, and the last two are the ones this milestone is for:

  - a posted service appears in `/srv`, and a name is refused twice
  - `/srv/name` reads back which service it is
  - `srv.mount` attaches it and binds it, and a file inside it can be read
  - **removing the name does not stop the service.** A mount made before the
    removal goes on working, and only a *new* mount by that name fails
  - **the listing cookie survives a change.** A name removed part-way through a
    listing skips no survivor and repeats none

The fourth is Plan 9's behaviour and the reason a posted service is a thing
rather than a lookup. The fifth is what a directory that mutates costs, and
`/srv` is the first one in Vectra that does.
*/
package srv

import "vsys:libodin"
import "kernel:vfs"
import "vsys:vectra9"

Verify_Result :: struct {
	using tally:   libodin.Tally,
	posted:        int, // Services this test published
	reserved:      int, // Names it created and never completed
	listed:        int, // Names it read back out of /srv
	passes:        int, // Treaddir calls the paced listing took
	mounted:       int, // Services it mounted and read through
}

@(private = "file")
check :: proc "contextless" (r: ^Verify_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

// -- Fixtures ----------------------------------------------------------------

@(private = "file")
ALPHA_NODES := [?]vfs.Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "hello", parent = 0, data = "alpha\n"},
}

@(private = "file")
BETA_NODES := [?]vfs.Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "hello", parent = 0, data = "beta\n"},
}

@(private = "file")
alpha_tree: vfs.Static_Tree
@(private = "file")
alpha_server: vfs.Server
@(private = "file")
beta_tree: vfs.Static_Tree
@(private = "file")
beta_server: vfs.Server

// How many names the cookie check posts. Enough that a listing paced one entry
// at a time takes several passes. That is what gives a removal somewhere to
// happen in the middle of.
@(private = "file")
PACED_NAMES :: 6

@(private = "file")
PACED :: [PACED_NAMES]string{"p0", "p1", "p2", "p3", "p4", "p5"}

// A listing that would not end is a listing this bound ends. A server that
// returned the same cookie twice would otherwise spin here rather than fail.
@(private = "file")
MAX_PASSES :: 32

// -- The test ----------------------------------------------------------------

verify :: proc(buf: []u8) -> Verify_Result #no_bounds_check {
	r: Verify_Result
	ns := vfs.boot_namespace

	if !check(&r, ns != nil, "the boot namespace exists") {
		return r
	}

	if !check(&r, vfs.static_init(&alpha_tree, "alpha", ALPHA_NODES[:]), "the alpha fixture came up") {
		return r
	}
	defer vfs.static_destroy(&alpha_tree)
	if !check(&r, vfs.static_init(&beta_tree, "beta", BETA_NODES[:]), "the beta fixture came up") {
		return r
	}
	defer vfs.static_destroy(&beta_tree)

	check(
		&r,
		vfs.server_init(&alpha_server, "alpha", vfs.static_handler, &alpha_tree) == .None,
		"and negotiated 9P2000.L",
	)
	check(
		&r,
		vfs.server_init(&beta_server, "beta", vfs.static_handler, &beta_tree) == .None,
		"and so did the second",
	)

	// Neither fixture is in the device table, so `#alpha` names nothing. The
	// only way to reach either is the name this test is about to post.
	_, escape_err := vfs.device_attach("#alpha")
	check(&r, escape_err != vfs.OK, "a fixture nobody registered has no `#name`")

	posted_before, removed_before := stats()
	empty_before := count()
	check(&r, empty_before == 0, "/srv starts empty")

	verify_post(&r, ns, buf)
	verify_mount(&r, ns, buf)
	verify_cookie(&r, ns, buf)
	verify_pending(&r, ns)

	// -- Nothing left behind -------------------------------------------------

	check(&r, count() == 0, "every name this test posted was removed")
	posted_after, removed_after := stats()
	check(&r, posted_after - posted_before == u64(r.posted), "and the server counted every post")
	check(
		&r,
		removed_after - removed_before == u64(r.posted + r.reserved),
		"and every removal, the reservation included",
	)
	return r
}

/*
verify_pending is posting as a file operation, up to the step this boot
cannot take yet.

Create reserves a name: listed, counted, readable as `pending`, and not a
service. A mount of it is ENXIO and a lookup answers nil. The write that
would complete it is refused here. This runs before userland exists, and a
descriptor number with no process behind it names nothing. The full arc
runs in `kernel/user/verify.odin`, where there is a process to hold the
number.
*/
@(private = "file")
verify_pending :: proc(r: ^Verify_Result, ns: ^vfs.Namespace) {
	c, err := vfs.create_path(ns, "/srv/embryo", vfs.O_WRONLY)
	if !check(r, err == vfs.OK && c != nil, "a create in /srv reserves a name") {
		return
	}
	r.reserved += 1
	check(r, count() == 1, "which occupies a slot")

	_, derr := vfs.create_path(ns, "/srv/embryo", vfs.O_WRONLY)
	check(r, derr == vectra9.EEXIST, "a second create of the same name is refused")

	dir, rerr := vfs.resolve(ns, "/srv")
	if check(r, rerr == vfs.OK && dir != nil, "the directory itself resolves") {
		check(
			r,
			vfs.chan_create(dir, "a/b", vfs.O_WRONLY, 0o600) == vectra9.EINVAL,
			"a name with a slash in it is refused",
		)
		vfs.chan_close(dir)
	}

	junk := [4]u8{'j', 'u', 'n', 'k'}
	_, werr := vfs.chan_write(c, 0, junk[:])
	check(r, werr == vectra9.EINVAL, "a write that is not a decimal number is refused")

	digit := [1]u8{'3'}
	_, werr = vfs.chan_write(c, 0, digit[:])
	check(
		r,
		werr == vectra9.EBADF,
		"and a number is refused too, because nothing here holds descriptors",
	)

	line: [16]u8
	rc, oerr := vfs.open_path(ns, "/srv/embryo", vfs.O_RDONLY)
	if check(r, oerr == vfs.OK && rc != nil, "the pending entry opens by name") {
		n, _ := vfs.chan_read(rc, 0, line[:])
		check(r, string(line[:n]) == "pending\n", "and reads as pending")
		vfs.chan_close(rc)
	}

	check(r, mount(ns, "/srv/embryo", "/mnt") == vectra9.ENXIO, "a pending name mounts nothing")
	check(r, lookup("embryo") == nil, "and no lookup calls it a service")

	check(r, vfs.chan_remove(c) == vfs.OK, "the reservation is removed like any name")
	vfs.chan_close(c)
	check(r, count() == 0, "and its slot is free again")
}

/*
verify_post publishes a name and checks what `/srv` then says about it.

The read is the interesting one. Plan 9 answers an open of `/srv/foo` with the
channel itself, and a read of it is not a thing a client does. Vectra has no
descriptor to hand over, so the file reports which service it is instead. A file
that could not be read would be a file with nothing to say about itself.
*/
@(private = "file")
verify_post :: proc(r: ^Verify_Result, ns: ^vfs.Namespace, buf: []u8) #no_bounds_check {
	check(r, post("", &alpha_server) == vectra9.EINVAL, "an empty name is refused")
	check(r, post("a/b", &alpha_server) == vectra9.EINVAL, "a name with a slash is refused")
	check(r, post("..", &alpha_server) == vectra9.EINVAL, "and so is a name a walk reaches by accident")
	check(r, post("alpha", nil) == vectra9.EINVAL, "and a service that is not one")

	if !check(r, post("alpha", &alpha_server) == vfs.OK, "a service posts under a name") {
		return
	}
	r.posted += 1
	check(r, count() == 1, "and /srv has it")
	check(r, post("alpha", &beta_server) == vectra9.EEXIST, "a second service may not take the same name")
	check(r, lookup("alpha") == &alpha_server, "and the name still finds the first")

	// The file, through the namespace rather than through the table.
	c, err := vfs.open_path(ns, "/srv/alpha", vfs.O_RDONLY)
	if !check(r, err == vfs.OK, "/srv/alpha opens") {
		return
	}
	defer vfs.chan_close(c)

	n, rerr := vfs.chan_read(c, 0, buf[:64])
	check(r, rerr == vfs.OK, "and reads")
	check(r, same(buf[:], n, "alpha direct\n"), "reporting the service and its transport")

	attr, aerr := vfs.chan_stat(c)
	check(r, aerr == vfs.OK, "and stats")
	check(r, attr.size == u64(n), "with the length a read of it gives")
	check(r, attr.mode & 0o777 == 0o600, "and permissions that say a service is a capability")

	// A name nobody posted is a name nobody can reach.
	_, missing := vfs.resolve(ns, "/srv/nothing")
	check(r, missing == vectra9.ENOENT, "a name nobody posted is not there")

	// The root of a served tree is not a file in it. A client that tries to
	// remove it is asking to delete the mount point from the inside.
	root, root_err := vfs.resolve(ns, "/srv")
	if check(r, root_err == vfs.OK, "/srv itself resolves") {
		check(r, vfs.chan_remove(root) == vectra9.EPERM, "and refuses to be removed")
		vfs.chan_close(root)
	}
}

/*
verify_mount is the point of the whole file, and the removal is the point of the
mount.

`srv.mount` resolves the name in the namespace, so a bind over `/srv` or a fork
that dropped it changes what this can reach. Then the qid says which entry, and
the entry says which service.

**Removing the name leaves the mount standing.** That is Plan 9's behaviour, and
it is what makes a posted service a running thing rather than a lookup. What
ends is the ability to make a new mount by that name, and the check is both
halves of that in the same breath.
*/
@(private = "file")
verify_mount :: proc(r: ^Verify_Result, ns: ^vfs.Namespace, buf: []u8) #no_bounds_check {
	if !check(r, mount(ns, "/srv/alpha", "/mnt") == vfs.OK, "a posted service mounts by name") {
		return
	}
	r.mounted += 1
	check(r, read_is(ns, "/mnt/hello", buf, "alpha\n"), "and a file inside it reads")

	// A path that is not one of this server's files is not a service, however
	// much it looks like one.
	check(r, mount(ns, "/dev/cons", "/mnt") == vectra9.EINVAL, "a path that is not a /srv entry is refused")
	check(r, mount(ns, "/srv", "/mnt") == vectra9.EINVAL, "and neither is the directory itself")
	check(r, mount(ns, "/srv/nothing", "/mnt") == vectra9.ENOENT, "and neither is a name nobody posted")

	// -- The removal ---------------------------------------------------------

	/*
	A handle taken before the removal, and held across it.

	This is what says a fid names a *service* rather than a slot. The entry is
	about to go and a different service is about to take its slot. This fid must
	not follow the slot. A fid that did would be a capability on
	something its holder was never given.

	`Service.id` is what makes that true, and it is the whole reason a slot
	index is not the identity here. See `srv.odin`.
	*/
	stale, serr := vfs.open_path(ns, "/srv/alpha", vfs.O_RDONLY)
	check(r, serr == vfs.OK, "a handle taken before the removal")
	defer if stale != nil {
		vfs.chan_close(stale)
	}

	// Through the file protocol rather than through `remove`, because Tremove
	// is the half of Plan 9's `/srv` that needs no file descriptor. `srv.remove`
	// is checked below, on the paced names.
	rc, rerr := vfs.resolve(ns, "/srv/alpha")
	if !check(r, rerr == vfs.OK, "the entry resolves before it is removed") {
		return
	}
	check(r, vfs.chan_remove(rc) == vfs.OK, "and a Tremove takes the name away")
	vfs.chan_close(rc)
	r.posted -= 0 // The post is still counted; only the name went.

	check(r, count() == 0, "/srv is empty again")
	_, gone := vfs.resolve(ns, "/srv/alpha")
	check(r, gone == vectra9.ENOENT, "and the name is gone")
	check(r, lookup("alpha") == nil, "and the table agrees")

	// The whole point.
	check(r, read_is(ns, "/mnt/hello", buf, "alpha\n"), "the mount made before the removal still reads")
	check(
		r,
		mount(ns, "/srv/alpha", "/mnt") == vectra9.ENOENT,
		"and only a new mount by that name fails",
	)

	check(r, vfs.unmount_path(ns, "", "/mnt") == vfs.OK, "the mount comes down")
	_, unmounted := vfs.resolve(ns, "/mnt/hello")
	check(r, unmounted != vfs.OK, "and takes the file with it")

	// -- The slot the removal freed ------------------------------------------

	if stale == nil {
		return
	}
	_, held := vfs.chan_read(stale, 0, buf[:64])
	check(r, held == vectra9.ENOENT, "the handle held across the removal names nothing")

	// A different service, into the slot the removal just freed.
	if !check(r, post("beta", &beta_server) == vfs.OK, "a different service takes the free slot") {
		return
	}
	r.posted += 1

	n, again := vfs.chan_read(stale, 0, buf[:64])
	check(
		r,
		again == vectra9.ENOENT,
		"and the old handle still names nothing, rather than whatever took the slot",
	)
	check(r, !same(buf[:], n, "beta direct\n"), "which is the capability a slot index would have leaked")

	check(r, remove("beta") == vfs.OK, "the second service goes too")
}

/*
verify_cookie is the check a mutable directory needs and a fixed one does not.

Six names are posted and the listing is paced one entry at a time. That is what
puts a removal in the middle of it rather than between two of them. The name
removed is one the listing has already passed.

**An ordinal cookie would fail here and an id cookie does not.** With
positions, removing an entry the listing already passed shifts every later one
down by one. `resume after position three` then skips a name nobody removed. With ids,
`resume after id three` means the same thing however the table moved.

The check is exact rather than approximate. Six names come back and each comes
back once, the removed one included, because the listing had already passed it
when it went. A skip or a repeat is what an ordinal cookie would have produced.
*/
@(private = "file")
verify_cookie :: proc(r: ^Verify_Result, ns: ^vfs.Namespace, buf: []u8) #no_bounds_check {
	names := PACED
	for i in 0 ..< PACED_NAMES {
		if !check(r, post(names[i], &beta_server) == vfs.OK, "a name posts for the paced listing") {
			return
		}
		r.posted += 1
	}
	check(r, count() == PACED_NAMES, "and /srv has all of them")

	c, err := vfs.open_path(ns, "/srv", vfs.O_RDONLY | vfs.O_DIRECTORY)
	if !check(r, err == vfs.OK, "/srv opens as a directory") {
		return
	}
	defer vfs.chan_close(c)

	seen: [PACED_NAMES]int
	total := 0
	passes := 0
	removed_at := 2 // Remove after this many entries have come back
	did_remove := false

	// One entry's worth of room per pass. `dirent_size` of the longest name
	// here, and nothing over.
	room := vectra9.dirent_size("p0")

	offset := u64(0)
	for passes < MAX_PASSES {
		n, e := vfs.readdir(c, offset, buf[:room])
		if e != vfs.OK {
			check(r, false, "the paced listing reads")
			return
		}
		if n == 0 {
			break
		}
		passes += 1

		cursor := vectra9.cursor_from(buf[:n])
		for {
			entry, more := vectra9.next_dirent(&cursor)
			if !more {
				break
			}
			for i in 0 ..< PACED_NAMES {
				if entry.name == names[i] {
					seen[i] += 1
				}
			}
			total += 1
			offset = entry.offset
		}

		if !did_remove && total >= removed_at {
			// A name the listing has already passed. Its slot goes back on the
			// free list, and every position after it moves.
			check(r, remove(names[0]) == vfs.OK, "a name is removed part-way through the listing")
			did_remove = true
		}
	}

	r.passes = passes
	r.listed = total
	check(r, passes > 2, "the listing really was paced, rather than answered in one pass")
	check(r, total == PACED_NAMES, "and returned every name that was there when it reached it")
	check(r, seen[0] == 1, "the removed name among them, once, from before it went")

	repeats := 0
	missing := 0
	for i in 1 ..< PACED_NAMES {
		if seen[i] == 0 {
			missing += 1
		}
		if seen[i] > 1 {
			repeats += 1
		}
	}
	check(r, missing == 0, "no surviving name was skipped, which an ordinal cookie would have done")
	check(r, repeats == 0, "and none came back twice")

	// -- The table's limits --------------------------------------------------

	filled := 0
	for filled < MAX_SERVICES {
		if post(fill_name(filled), &beta_server) != vfs.OK {
			break
		}
		filled += 1
	}
	check(r, count() == MAX_SERVICES, "the table fills to exactly its size")
	check(r, post("overflow", &beta_server) == vectra9.ENOSPC, "and refuses one more")

	for i in 0 ..< filled {
		_ = remove(fill_name(i))
	}
	for i in 1 ..< PACED_NAMES {
		check(r, remove(names[i]) == vfs.OK, "every paced name removes")
	}
	r.posted += filled
	check(r, remove("p1") == vectra9.ENOENT, "and a name already gone is not there twice")
}

// -- Helpers -----------------------------------------------------------------

// Sixty-four distinct short names, without an allocator or a formatter. Two
// characters, so `dirent_size` stays what the paced listing assumed.
@(private = "file")
FILL := "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-"

@(private = "file")
fill_names: [64][2]u8

@(private = "file")
fill_name :: proc "contextless" (i: int) -> string #no_bounds_check {
	fill_names[i][0] = 'f'
	fill_names[i][1] = FILL[i]
	return string(fill_names[i][:])
}

@(private = "file")
same :: proc "contextless" (got: []u8, n: int, want: string) -> bool #no_bounds_check {
	if n != len(want) {
		return false
	}
	for i in 0 ..< n {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

@(private = "file")
read_is :: proc(ns: ^vfs.Namespace, path: string, buf: []u8, want: string) -> bool {
	c, err := vfs.open_path(ns, path, vfs.O_RDONLY)
	if err != vfs.OK {
		return false
	}
	defer vfs.chan_close(c)

	n, rerr := vfs.chan_read(c, 0, buf[:64])
	return rerr == vfs.OK && same(buf, n, want)
}
