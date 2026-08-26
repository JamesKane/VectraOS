/*
Walking -- how a path becomes a chan.

Resolution is one element at a time, and each element does two things:

    walk1(ns, c, name):
        for member in union_members(c):        # c may present several trees
            if r := server_walk1(member, name):
                return cross_mounts(ns, r)     # r may itself be mounted over
        return ENOENT

`cross_mounts` is the second half, and it is the half that makes this a
namespace rather than a lookup table: having arrived at a file, check whether
*it* is mounted over, and if so return the first member of that mount instead.
A walk therefore alternates between asking servers and consulting the mount
table, and a single path element can cross from one server to another.

Two consequences worth stating plainly:

  - **A path can traverse several servers.** `/net/tcp/0/data` may involve the
    root server and the network server -- or three servers, if someone bound a
    debug filter over `/net/tcp`.
  - **Walk is where the namespace costs something.** Every element is a mount
    table lookup plus at least one Twalk. Batching -- 9P allows sixteen
    elements per Twalk -- is possible only across elements that stay within one
    server, which the walker discovers as it goes and so cannot plan in
    advance. Not done yet, and the place to do it is `resolve`.
*/
package vfs

import "vsys:vectra9"

/*
A path of more than this many elements is a bug rather than a deep tree.

The bound is not about depth so much as termination: once symlinks exist, a
walk can be made to loop, and the loop will be found here. ELOOP is the errno
for it whether or not a symlink was involved, which is what Linux does too.
*/
MAX_PATH_ELEMENTS :: 64

/*
attach opens a server's tree and returns a chan on its root.

`aname` selects which tree, for a server that offers more than one -- the empty
string is the default and is what every Vectra server currently answers.
Authentication is not attempted: `afid` is NOFID, which is 9P's way of saying
the client has none, and a server that requires one will refuse here rather
than silently granting access.
*/
attach :: proc(sv: ^Server, aname: string = "", uname: string = "vectra") -> (^Chan, Errno) {
	if sv == nil {
		return nil, vectra9.ENODEV
	}

	fid := vectra9.alloc_fid(&sv.session)
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
slash: the root device is `#/`, following Plan 9, and a scan that stopped at
the first slash would name the empty device instead.
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

After a `Clean` fork there is literally no name for anything, and something has
to be able to say "give me the console device" without a path to it. Access is
a privilege -- a process without it cannot manufacture a channel out of nothing
-- and when there are processes to check, the check goes here.
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

The namespace fields are inherited from where the walk came from, not reset: a
chan three directories inside a mounted tree is still inside that tree, and
still has to climb through the same `mounted_over` when a `..` eventually
reaches the root.
*/
@(private)
server_walk1 :: proc(from: ^Chan, name: string) -> (^Chan, Errno) #no_bounds_check {
	if from == nil {
		return nil, vectra9.EBADF
	}

	newfid := vectra9.alloc_fid(&from.server.session)
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

Consumes `c` on every path, including the one where nothing is mounted -- it
returns the same pointer then, so a caller can always write `c, err =
cross_mounts(ns, c)` and never has to know which happened.

Not a loop. Binding onto an already-mounted name resolves the name first, so
the member stored in the table has already been crossed; a second crossing here
would be a second lookup that can only find the same thing.
*/
@(private)
cross_mounts :: proc(ns: ^Namespace, c: ^Chan) -> (^Chan, Errno) {
	mp := mount_head(ns, c)
	if mp == nil || mp.members == nil {
		return c, OK
	}

	nc, err := chan_clone(mp.members.chan)
	if err != OK {
		chan_close(c)
		return nil, err
	}
	nc.union_head = mp
	chan_close(c)
	return nc, OK
}

/*
walk1 resolves one path element within a namespace.

Returns a new reference; the caller's `c` is untouched and still theirs to
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
looking through it. Plan 9 spells the same distinction `Amount` versus `Aopen`
in `namec`, and it is not cosmetic: a bind whose target had been crossed would
key a *new* mount point on the first member's root, so a second `bind -a` would
nest a second union inside the first instead of joining it, and the new member
would never be searched.
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

	// Only the union directory itself is a union: a name resolved *inside* one
	// comes from whichever member provided it, and searching the others for
	// its children would union trees the namespace never joined.
	mp := c.union_head
	if mp == nil || mp.members == nil {
		nc, err := server_walk1(c, name)
		if err != OK {
			return nil, err
		}
		if !cross {
			return nc, OK
		}
		return cross_mounts(ns, nc)
	}

	// ENOENT until something more specific happens. A member that answers
	// EACCES has told us something worth reporting; a member that simply does
	// not have the file has not, and must not stop the search.
	last := Errno(vectra9.ENOENT)
	for m := mp.members; m != nil; m = m.next {
		nc, err := server_walk1(m.chan, name)
		if err == OK {
			if !cross {
				return nc, OK
			}
			return cross_mounts(ns, nc)
		}
		if err != vectra9.ENOENT {
			last = err
		}
	}
	return nil, last
}

/*
walk_up is `..`, which is the hard part.

Walking `..` out of the root of a mounted tree must land at the parent of the
**mount point**, not at the parent the server would name:

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

The climb is a loop rather than a single step because mounts nest: a tree
mounted onto the root of a tree mounted onto the root of a third leaves three
roots stacked on one file, and `..` has to leave all of them at once.
*/
@(private)
walk_up :: proc(ns: ^Namespace, c: ^Chan) -> (^Chan, Errno) {
	base := c
	for base.mounted_over != nil && base.qid.path == base.tree_root.path {
		base = base.mounted_over
	}

	// `..` at the namespace root is the root. There is no escaping upward,
	// which is what makes a chroot-equivalent free.
	if ns != nil &&
	   ns.root != nil &&
	   base.server == ns.root.server &&
	   base.qid.path == ns.root.qid.path {
		return chan_clone(ns.root)
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

This is the chan `bind` and `unmount` want: the *key*, not the value. Resolving
`/dev` normally answers with whatever is bound there, which is the one thing a
caller about to change what is bound there must not be given. See `walk1_ex`.
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
		if ns.root == nil {
			return nil, vectra9.ENOENT
		}
		cur, err = chan_clone(ns.root)
		if err != OK {
			return nil, err
		}

		// The root is crossed too, so a `bind` over `/` itself takes effect --
		// unless the root *is* what the caller is about to rebind, which is
		// the one case `cross_last` is false with no elements left to walk.
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

Separate from `resolve` because binding and unmounting want a chan they have
not opened, and because a caller that opens has to close on every later error
while one that only resolved does not.
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
