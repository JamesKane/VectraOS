/*
Walking -- how a path becomes a chan.

Resolution is one element at a time, and each element does two things:

    walk1(ns, c, name):
        for member in union_members(c):        # c may present several trees
            if r := server_walk1(member, name):
                return cross_mounts(ns, r)     # r may itself be mounted over
        return ENOENT

`cross_mounts` is the second half, and it is the half that makes this a
namespace rather than a lookup table. On arrival at a file, it checks whether
*that file* is mounted over. If it is, it returns the first member of that
mount instead. A walk therefore alternates between asking servers and
consulting the mount table, and a single path element can cross from one server
to another.

Two consequences worth stating plainly:

  - **A path can traverse several servers.** `/net/tcp/0/data` may involve the
    root server and the network server -- or three servers, if someone bound a
    debug filter over `/net/tcp`.
  - **Walk is where the namespace costs something.** Every element is a mount
    table lookup plus at least one Twalk. 9P allows sixteen elements per Twalk.
    A batch is possible only across elements that stay within one server, and
    the walker discovers that as it goes. It therefore cannot plan one in
    advance. Not done yet, and the place to do it is `resolve`.
*/
package vfs

import "kernel:sync"
import "vsys:vectra9"

/*
A path of more than this many elements is a bug rather than a deep tree.

The bound is about termination more than depth. Once symlinks exist, a walk can
loop, and this is where the loop shows up. ELOOP is the errno for it whether or
not a symlink was involved, which is what Linux does too.
*/
MAX_PATH_ELEMENTS :: 64


/*
attach opens a server's tree and returns a chan on its root.

`aname` selects which tree, for a server that offers more than one. The empty
string is the default, and it is what every Vectra server currently answers.
This attempts no authentication. `afid` is NOFID, which is 9P's way to say the
client has none. A server that requires one refuses here, rather than silently
grants access.
*/
attach :: proc(sv: ^Server, aname: string = "", uname: string = "vectra") -> (^Chan, Errno) {
	if sv == nil {
		return nil, vectra9.ENODEV
	}

	if e := rpc_ready(sv); e != OK {
		return nil, e
	}

	fid := new_fid(sv)
	request := vectra9.Msg(
		vectra9.Tattach {
			fid = fid,
			afid = vectra9.NOFID,
			uname = uname,
			aname = aname,
			n_uname = vectra9.NONUNAME,
		},
	)
	reply: vectra9.Msg
	if e := rpc(sv, &request, &reply); e != OK {
		return nil, e
	}
	answer, ok := reply.(vectra9.Rattach)
	if !ok {
		return nil, vectra9.EPROTO
	}

	c := chan_alloc(sv, fid, answer.qid)
	if c == nil {
		return nil, vectra9.ENOMEM
	}
	return c, OK
}

/*
device_spec_len measures the `#name` prefix of a path.

The first character after `#` is always part of the name, even when it is a
slash. The root device is `#/`, as it is in Plan 9. A scan that stopped at the
first slash would name the empty device instead.
*/
@(private)
device_spec_len :: proc "contextless" (path: string) -> int {
	end := min(2, len(path))
	for end < len(path) && path[end] != '/' {
		end += 1
	}
	return end
}

/*
device_attach is section 5.8's first escape: `#name`, bypassing the namespace.

After a `Clean` fork there is literally no name for anything. Something has to
be able to ask for the console device with no path to it. Access is a
privilege, and a process without it cannot manufacture a channel out of
nothing. When there are processes to check, the check goes here.
*/
device_attach :: proc(spec: string, uname: string = "vectra") -> (^Chan, Errno) {
	if len(spec) < 2 || spec[0] != '#' {
		return nil, vectra9.EINVAL
	}

	sv := find_device(spec[1:device_spec_len(spec)])
	if sv == nil {
		return nil, vectra9.ENODEV
	}
	return attach(sv, "", uname)
}

// -- One element -------------------------------------------------------------

/*
server_walk1 asks one server for one name.

The namespace fields come from where the walk came from, and nothing resets
them. A chan three directories inside a mounted tree is still inside that tree.
It still has to climb through the same `mounted_over` when a `..` eventually
reaches the root.
*/
@(private)
server_walk1 :: proc(from: ^Chan, name: string) -> (^Chan, Errno) #no_bounds_check {
	if from == nil {
		return nil, vectra9.EBADF
	}

	if e := rpc_ready(from.server); e != OK {
		return nil, e
	}

	newfid := new_fid(from.server)
	t := vectra9.Twalk {
		fid    = from.fid,
		newfid = newfid,
		count  = 1,
	}
	t.names[0] = name

	request := vectra9.Msg(t)
	reply: vectra9.Msg
	if e := rpc(from.server, &request, &reply); e != OK {
		return nil, e
	}
	answer, ok := reply.(vectra9.Rwalk)
	if !ok {
		return nil, vectra9.EPROTO
	}

	// A short Rwalk is 9P's "got that far and no further". With one name asked
	// for, the only short answer is zero, and it means the name is not there.
	// It is not an error reply, so it does not arrive as an Errno.
	if answer.count != 1 {
		return nil, vectra9.ENOENT
	}

	nc := chan_alloc(from.server, newfid, answer.qids[0])
	if nc == nil {
		return nil, vectra9.ENOMEM
	}
	nc.tree_root = from.tree_root
	nc.mounted_over = chan_incref(from.mounted_over)
	return nc, OK
}

/*
cross_mounts substitutes a mounted tree for the file it was mounted onto.

Consumes `c` on every path, including the one where nothing is mounted. It
returns the same pointer then. A caller can therefore always write `c, err =
cross_mounts(ns, c)`, and never has to know which happened.

Not a loop. A bind onto an already-mounted name resolves the name first, so
something already crossed the member the table stores. A second crossing here
would be a second lookup that can only find the same thing.
*/
@(private)
cross_mounts :: proc(ns: ^Namespace, c: ^Chan) -> (^Chan, Errno) {
	if ns == nil || c == nil {
		return c, OK
	}

	/*
	Two references come out from under the lock and a message is sent after it.

	The member is increfed because the clone below is a Twalk, and cannot happen
	inside a lock. An `unmount` in that window would otherwise free the chan the
	clone is reading. The mount point is increfed because it is about to become
	this chan's `union_head`, which is a reference by definition.
	*/
	first: ^Chan
	mp: ^Mount_Point

	// `findmount`'s two read locks, in its order: the namespace to find the
	// head, the head to read its first member.
	sync.rlock(&ns.lock)
	if head := mount_head(ns, c); head != nil {
		sync.rlock(&head.lock)
		if head.members != nil {
			first = chan_incref(head.members.chan)
			mp = mount_point_incref(head)
		}
		sync.runlock(&head.lock)
	}
	sync.runlock(&ns.lock)

	if first == nil {
		return c, OK
	}

	nc, err := chan_clone(first)
	chan_close(first)
	if err != OK {
		mount_point_release(mp)
		chan_close(c)
		return nil, err
	}

	// A member is the root of its own tree and carries no union head of its own,
	// so the clone brought none across. Release anyway, rather than depend on
	// that from here.
	mount_point_release(nc.union_head)
	nc.union_head = mp
	chan_close(c)
	return nc, OK
}

/*
walk1 resolves one path element within a namespace.

Returns a new reference. The caller's `c` is untouched, and still theirs to
close. `.` is a clone rather than an incref because the result may be opened
independently, and 9P has no way to open one fid twice.
*/
walk1 :: proc(ns: ^Namespace, c: ^Chan, name: string) -> (^Chan, Errno) {
	return walk1_ex(ns, c, name, true)
}

/*
walk1_ex is walk1 with the final crossing made optional.

`cross = false` stops one step short: it returns the file the mount table is
keyed on rather than what is mounted there. Exactly one kind of caller wants
that -- `bind` and `unmount`, which are naming a mount point rather than
looking through it. Plan 9 spells the same distinction `Amount` against `Aopen`
in `namec`, and it is not cosmetic.

A bind whose target something already crossed would key a *new* mount point on
the first member's root. A second `bind -a` would then nest a second union
inside the first rather than join it, and nothing would ever search the new
member.
*/
@(private)
walk1_ex :: proc(ns: ^Namespace, c: ^Chan, name: string, cross: bool) -> (^Chan, Errno) {
	if c == nil {
		return nil, vectra9.EBADF
	}
	if name == "" || name == "." {
		return chan_clone(c)
	}
	if name == ".." {
		return walk_up(ns, c)
	}

	// Only the union directory itself is a union. A name resolved *inside* one
	// comes from whichever member provided it. A search of the others for its
	// children would join trees the namespace never joined.
	mp := c.union_head
	if mp == nil {
		nc, err := server_walk1(c, name)
		if err != OK {
			return nil, err
		}
		if !cross {
			return nc, OK
		}
		return cross_mounts(ns, nc)
	}

	/*
	The union search, under the mount point's read lock for the whole of it.

	This is `walk()` in Plan 9's `chan.c`: `rlock(&mh->lock)`, one walk per
	member, `runlock` after. The lock sleeps, so a message under it is
	ordinary. A `bind` that wants the list waits for this search to end
	rather than shifting members under it. A counter used to say whether the
	list moved, and the search ran again if it did. The lock is the
	design that counter stood in for.

	The lock goes before `cross_mounts`, which takes other locks of its own.
	Holding this one across it would nest read locks on two mount points. A
	writer queued on the second would then wait for a reader that is waiting
	on the first.

	ENOENT until something more specific happens. A member that answers EACCES
	told us something worth reporting. A member that simply does not have the
	file told us nothing, and must not stop the search.
	*/
	sync.rlock(&mp.lock)
	if member_count(mp) == 0 {
		sync.runlock(&mp.lock)
		nc, err := server_walk1(c, name)
		if err != OK {
			return nil, err
		}
		if !cross {
			return nc, OK
		}
		return cross_mounts(ns, nc)
	}

	last := Errno(vectra9.ENOENT)
	for idx := 0; idx < MAX_UNION_MEMBERS; idx += 1 {
		member, _, present := member_ref_at(mp, idx)
		if !present {
			break
		}
		nc, err := server_walk1(member, name)
		chan_close(member)
		if err == OK {
			sync.runlock(&mp.lock)
			if !cross {
				return nc, OK
			}
			return cross_mounts(ns, nc)
		}
		if err != vectra9.ENOENT {
			last = err
		}
	}
	sync.runlock(&mp.lock)
	return nil, last
}

/*
walk_up is `..`, which is the hard part.

A walk of `..` out of the root of a mounted tree must land at the parent of the
**mount point**. It must not land at the parent the server would name:

    mount /srv/net  /net
    cd /net/tcp
    cd ..            -> /net    (the server would say: its own root)
    cd ..            -> /       (the mount point's parent -- a *different*
                                 server, which the network server has never
                                 heard of and cannot name)

The server physically cannot answer the second one. It does not know it was
mounted, does not know where, and has no name for anything above its own root.
So the namespace answers it, by climbing `mounted_over` until it is standing
somewhere that has a parent its own server can name.

The climb is a loop rather than a single step, because mounts nest. A tree
mounted onto the root of a tree mounted onto the root of a third leaves three
roots stacked on one file. `..` has to leave all of them at once.
*/
@(private)
walk_up :: proc(ns: ^Namespace, c: ^Chan) -> (^Chan, Errno) {
	base := c
	for base.mounted_over != nil && base.qid.path == base.tree_root.path {
		base = base.mounted_over
	}

	// `..` at the namespace root is the root. There is no escaping upward,
	// which is what makes a chroot-equivalent free.
	if root := ns_root_ref(ns); root != nil {
		defer chan_close(root)
		if base.server == root.server && base.qid.path == root.qid.path {
			return chan_clone(root)
		}
	}

	up, err := server_walk1(base, "..")
	if err != OK {
		return nil, err
	}
	return cross_mounts(ns, up)
}

// -- Whole paths -------------------------------------------------------------

/*
next_element yields one path component, skipping runs of slashes.

Hand-rolled rather than reached for from core:strings, which is one import away
from an allocator this runs above.
*/
@(private)
next_element :: proc "contextless" (path: string, from: int) -> (name: string, next: int) {
	i := from
	for i < len(path) && path[i] == '/' {
		i += 1
	}
	if i >= len(path) {
		return "", len(path)
	}
	j := i
	for j < len(path) && path[j] != '/' {
		j += 1
	}
	return path[i:j], j
}

/*
resolve turns a path into a chan.

Two forms are accepted and a third deliberately is not:

    /dev/cons     absolute, from the namespace root
    #c/cons       from a device, bypassing the namespace entirely
    dev/cons      EINVAL -- relative to what?

The third needs a process to be relative to, and there are no processes yet.
When there are, a current directory is a chan on the process and this grows one
more starting point rather than a second implementation.

The starting chan is crossed before the first element, so a `bind` over `/`
itself takes effect. Every intermediate is closed as the walk moves past it,
so a failed resolve leaks nothing and a successful one returns exactly one
reference.
*/
resolve :: proc(ns: ^Namespace, path: string) -> (^Chan, Errno) {
	return resolve_ex(ns, path, true)
}

/*
resolve_mount_point resolves a path and stops short of what is mounted on it.

This is the chan `bind` and `unmount` want: the *key*, not the value. A resolve
of `/dev` normally answers with whatever is bound there. That is the one answer
a caller about to change what is bound there must not get. See `walk1_ex`.
*/
resolve_mount_point :: proc(ns: ^Namespace, path: string) -> (^Chan, Errno) {
	return resolve_ex(ns, path, false)
}

@(private)
resolve_ex :: proc(ns: ^Namespace, path: string, cross_last: bool) -> (^Chan, Errno) {
	if ns == nil || len(path) == 0 {
		return nil, vectra9.EINVAL
	}

	cur: ^Chan
	err := OK
	start := 0

	if path[0] == '#' {
		end := device_spec_len(path)
		cur, err = device_attach(path[:end])
		if err != OK {
			return nil, err
		}
		start = end
	} else if path[0] == '/' {
		root := ns_root_ref(ns)
		if root == nil {
			return nil, vectra9.ENOENT
		}
		cur, err = chan_clone(root)
		chan_close(root)
		if err != OK {
			return nil, err
		}

		// The root is crossed too, so a `bind` over `/` itself takes effect. The
		// exception is a root that *is* what the caller is about to rebind. That is
		// the one case where `cross_last` is false with no elements left to walk.
		first, _ := next_element(path, 0)
		if cross_last || first != "" {
			cur, err = cross_mounts(ns, cur)
			if err != OK {
				return nil, err
			}
		}
	} else {
		return nil, vectra9.EINVAL
	}

	pos := start
	for depth := 0; pos < len(path); depth += 1 {
		if depth >= MAX_PATH_ELEMENTS {
			chan_close(cur)
			return nil, vectra9.ELOOP
		}

		name: string
		name, pos = next_element(path, pos)
		if name == "" {
			break
		}

		// Every element but the last must be a directory. Saying so here turns
		// `/dev/cons/oops` into ENOTDIR rather than whatever a server happens
		// to answer when asked to walk out of a file.
		if !chan_is_dir(cur) {
			chan_close(cur)
			return nil, vectra9.ENOTDIR
		}

		peek, _ := next_element(path, pos)
		next: ^Chan
		next, err = walk1_ex(ns, cur, name, cross_last || peek != "")
		chan_close(cur)
		if err != OK {
			return nil, err
		}
		cur = next
	}

	return cur, OK
}

/*
open_path is the common case: resolve, then open.

Separate from `resolve`, because `bind` and `unmount` want a chan nothing
opened. And a caller that opens has to close on every later error, while one
that only resolved does not.
*/
open_path :: proc(ns: ^Namespace, path: string, flags: u32 = O_RDONLY) -> (^Chan, Errno) {
	c, err := resolve(ns, path)
	if err != OK {
		return nil, err
	}
	if e := chan_open(c, flags); e != OK {
		chan_close(c)
		return nil, e
	}
	return c, OK
}

/*
create_path makes a file where the path says, and returns it open.

The split is by the last slash. Everything before it must resolve to a
directory, and the name after it is the server's to accept or refuse. The
resolve crosses mounts like any other, so what `/srv/foo` creates *in*
depends on the namespace. A bind over `/srv` catches a create the same way
it catches an open.

The chan handed back is the one the resolve produced, mutated by Tlcreate
into the new file. That is why there is no clone here: the directory handle
was this call's own, and nothing else holds it. See `chan_create`.

ENOTDIR when the parent is a file, EINVAL when the path has no name to
create. Whether the name may exist already is the server's answer, not this
layer's.
*/
create_path :: proc(ns: ^Namespace, path: string, flags: u32, mode: u32 = 0o600) -> (^Chan, Errno) {
	last := -1
	for i in 0 ..< len(path) {
		if path[i] == '/' {
			last = i
		}
	}
	if last < 0 || last + 1 >= len(path) {
		return nil, vectra9.EINVAL
	}
	name := path[last + 1:]
	parent := last == 0 ? "/" : path[:last]

	c, err := resolve(ns, parent)
	if err != OK {
		return nil, err
	}
	if !chan_is_dir(c) {
		chan_close(c)
		return nil, vectra9.ENOTDIR
	}
	if e := chan_create(c, name, flags, mode); e != OK {
		chan_close(c)
		return nil, e
	}
	return c, OK
}
