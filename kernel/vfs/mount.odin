/*
The mount table.

A mount point is keyed by the file being mounted **over**:

    key = (server identity, qid.path)

`qid.path` and not the whole qid, because `qid.version` changes whenever a
directory is modified. Keying on the version would unmount `/dev` the moment
somebody created a file in whatever `/dev` was mounted onto.

Each key holds an *ordered list* of members. One member is an ordinary mount;
several are a union directory, searched in list order:

    bind -a /dev/usb /dev        # after:  /dev then /dev/usb
    bind -b /tmp/bin /bin        # before: /tmp/bin then /bin

    /bin  ---+--> [0] /tmp/bin      searched first
             +--> [1] /bin          searched second

The table lives in the `Namespace`, not in a global. That is the entire point:
two processes looking up the same key get different answers, and neither is
more real than the other.
*/
package vfs

import "vsys:vectra9"

/*
Thirty-two buckets, chained.

A namespace with more than a few dozen mounts is unusual -- Plan 9's are
typically ten to thirty -- and a chain of two costs one pointer chase per path
element. This is sized for the common case on purpose; the pathological case
degrades linearly rather than failing.
*/
MOUNT_BUCKETS :: 32

Mount_Order :: enum {
	Replace, // Clear the list and become its only member
	Before, // Push onto the front: searched first
	After, // Push onto the back: searched last
}

// Create marks the member new files are made in. Exactly one member should
// carry it; `union_create_target` explains what happens when none does.
Mount_Flag :: enum {
	Create,
}

Mount_Flags :: bit_set[Mount_Flag]

Mount :: struct {
	chan:  ^Chan, // The root of the mounted tree
	flags: Mount_Flags,
	next:  ^Mount,
}

Mount_Point :: struct {
	server:  ^Server, // Identity half of the key: whose qid.path this is
	path:    u64,
	members: ^Mount,
	next:    ^Mount_Point, // Hash chain
}

@(private)
mount_hash :: proc "contextless" (sv: ^Server, path: u64) -> int {
	// The server pointer is 16-byte aligned at best, so its low bits are dead;
	// fold it down before mixing so two servers with adjacent allocations do
	// not collide on every file they serve.
	h := u64(uintptr(rawptr(sv))) >> 4
	h ~= path * 0x9E37_79B9_7F4A_7C15
	h ~= h >> 29
	return int(h % MOUNT_BUCKETS)
}

/*
mount_head finds the mount point a chan is the key of, or nil.

Called once per path element by `cross_mounts`, which is what makes a walk
alternate between asking servers and consulting the table -- and what lets a
single path element cross from one server to another.
*/
mount_head :: proc "contextless" (ns: ^Namespace, c: ^Chan) -> ^Mount_Point #no_bounds_check {
	if ns == nil || c == nil {
		return nil
	}
	for mp := ns.mounts[mount_hash(c.server, c.qid.path)]; mp != nil; mp = mp.next {
		if mp.server == c.server && mp.path == c.qid.path {
			return mp
		}
	}
	return nil
}

@(private)
mount_head_create :: proc(ns: ^Namespace, c: ^Chan) -> ^Mount_Point #no_bounds_check {
	if mp := mount_head(ns, c); mp != nil {
		return mp
	}
	mp := new(Mount_Point)
	if mp == nil {
		return nil
	}
	mp.server = c.server
	mp.path = c.qid.path

	bucket := mount_hash(c.server, c.qid.path)
	mp.next = ns.mounts[bucket]
	ns.mounts[bucket] = mp
	ns.mount_count += 1
	return mp
}

/*
bind makes `source` visible at the name `over` resolved to.

`mount` in Plan 9 is the same operation reaching a server through a posted
channel instead of an existing name; once `/srv` exists it will be a wrapper
around this and not a second implementation.

Both chans stay the caller's. The table takes its own handles: `source` is
cloned because the stored member is walked from independently, and `over` is
cloned because it becomes the `mounted_over` that every chan inside the mounted
tree will climb through on `..` -- for as long as any of them lives, which is
longer than the caller's own reference.
*/
bind :: proc(
	ns: ^Namespace,
	source: ^Chan,
	over: ^Chan,
	order: Mount_Order = .Replace,
	flags: Mount_Flags = {},
) -> Errno {
	if ns == nil || source == nil || over == nil {
		return vectra9.EINVAL
	}

	// Mounting a file over a directory, or the reverse, would produce a
	// namespace where the type of a name depends on which member answered.
	if chan_is_dir(source) != chan_is_dir(over) {
		return chan_is_dir(over) ? vectra9.ENOTDIR : vectra9.EISDIR
	}

	member_chan, err := chan_clone(source)
	if err != OK {
		return err
	}

	parent: ^Chan
	parent, err = chan_clone(over)
	if err != OK {
		chan_close(member_chan)
		return err
	}

	// This is what makes `..` work out of the mounted tree: the member is the
	// root of its tree, and the chan it was mounted onto is what lies above it.
	member_chan.tree_root = source.qid
	if member_chan.mounted_over != nil {
		chan_close(member_chan.mounted_over)
	}
	member_chan.mounted_over = parent
	member_chan.union_head = nil

	m := new(Mount)
	if m == nil {
		chan_close(member_chan)
		return vectra9.ENOMEM
	}
	m.chan = member_chan
	m.flags = flags

	mp := mount_head_create(ns, over)
	if mp == nil {
		chan_close(member_chan)
		free(m)
		return vectra9.ENOMEM
	}

	// A lock goes here, and around every other mutation in this file. One CPU
	// and no preemption is why there is not one yet.
	switch order {
	case .Replace:
		members_free(mp.members)
		mp.members = m
	case .Before:
		m.next = mp.members
		mp.members = m
	case .After:
		if mp.members == nil {
			mp.members = m
			break
		}
		tail := mp.members
		for tail.next != nil {
			tail = tail.next
		}
		tail.next = m
	}
	return OK
}

/*
unmount removes one member, or the whole mount point when `source` is nil.

Matching is by (server, qid.path) rather than by chan identity, because the
caller resolved `/dev/usb` again to name what to remove and got a different
`Chan` than the one the table holds. The qid is the file's permanent identity;
the chan is just a handle on it.
*/
unmount :: proc(ns: ^Namespace, source: ^Chan, over: ^Chan) -> Errno #no_bounds_check {
	if ns == nil || over == nil {
		return vectra9.EINVAL
	}
	mp := mount_head(ns, over)
	if mp == nil {
		return vectra9.EINVAL
	}

	if source == nil {
		members_free(mp.members)
		mp.members = nil
	} else {
		removed := false
		prev: ^Mount
		m := mp.members
		for m != nil {
			next := m.next
			if m.chan.server == source.server && m.chan.qid.path == source.qid.path {
				if prev == nil {
					mp.members = next
				} else {
					prev.next = next
				}
				chan_close(m.chan)
				free(m)
				removed = true
			} else {
				prev = m
			}
			m = next
		}
		if !removed {
			return vectra9.EINVAL
		}
	}

	if mp.members == nil {
		mount_point_unlink(ns, mp)
	}
	return OK
}

@(private)
mount_point_unlink :: proc(ns: ^Namespace, mp: ^Mount_Point) #no_bounds_check {
	bucket := mount_hash(mp.server, mp.path)
	prev: ^Mount_Point
	for cur := ns.mounts[bucket]; cur != nil; cur = cur.next {
		if cur == mp {
			if prev == nil {
				ns.mounts[bucket] = cur.next
			} else {
				prev.next = cur.next
			}
			ns.mount_count -= 1
			free(mp)
			return
		}
		prev = cur
	}
}

@(private)
members_free :: proc(head: ^Mount) {
	m := head
	for m != nil {
		next := m.next
		chan_close(m.chan)
		free(m)
		m = next
	}
}

// member_count reports how many trees a mount point presents as one. One is an
// ordinary mount; more is a union.
member_count :: proc "contextless" (mp: ^Mount_Point) -> int {
	n := 0
	for m := mp != nil ? mp.members : nil; m != nil; m = m.next {
		n += 1
	}
	return n
}

/*
union_create_target picks the member a new file is made in.

Plan 9's rule, and it has two halves: take the first member flagged `Create`,
and *do not fall through* if creating there fails. The second half is the one
that matters. Falling through would put a new file in `/bin` in whichever tree
happened to be writable that day, with no way for the caller to know which -- a
create that fails where the namespace chose is a comprehensible error; one that
silently lands elsewhere surfaces weeks later as a file nobody can find.

Nil means no member is flagged, which is EPERM at the call site rather than a
guess. See docs/VECTRA9.md section 7.4.
*/
union_create_target :: proc "contextless" (mp: ^Mount_Point) -> ^Chan {
	for m := mp != nil ? mp.members : nil; m != nil; m = m.next {
		if .Create in m.flags {
			return m.chan
		}
	}
	return nil
}

// -- Binding by name ---------------------------------------------------------

/*
The three of these exist so that no caller has to remember which side of a bind
gets `resolve` and which gets `resolve_mount_point`.

Getting that backwards produces a namespace that looks right and is not: the
bind succeeds, the name resolves to the same file it did before, and the new
member is never searched, because it was filed under a key nothing looks up.
An API that can be held wrong in a way that fails silently is an API with a bug
in it, so this is the one that should be reached for.
*/
bind_path :: proc(
	ns: ^Namespace,
	source_path: string,
	target_path: string,
	order: Mount_Order = .Replace,
	flags: Mount_Flags = {},
) -> Errno {
	source, err := resolve(ns, source_path)
	if err != OK {
		return err
	}
	defer chan_close(source)

	over: ^Chan
	over, err = resolve_mount_point(ns, target_path)
	if err != OK {
		return err
	}
	defer chan_close(over)

	return bind(ns, source, over, order, flags)
}

/*
mount_device attaches a `#name` tree and binds it at a path.

The kernel-side half of what `mount` will be once `/srv` exists: same
operation, reaching the server through the device table instead of through a
posted channel.
*/
mount_device :: proc(
	ns: ^Namespace,
	spec: string,
	target_path: string,
	order: Mount_Order = .Replace,
	flags: Mount_Flags = {},
) -> Errno {
	source, err := device_attach(spec)
	if err != OK {
		return err
	}
	defer chan_close(source)

	over: ^Chan
	over, err = resolve_mount_point(ns, target_path)
	if err != OK {
		return err
	}
	defer chan_close(over)

	return bind(ns, source, over, order, flags)
}

// unmount_path removes one member from a mount point, or every member when
// `source_path` is empty.
unmount_path :: proc(ns: ^Namespace, source_path: string, target_path: string) -> Errno {
	over, err := resolve_mount_point(ns, target_path)
	if err != OK {
		return err
	}
	defer chan_close(over)

	if source_path == "" {
		return unmount(ns, nil, over)
	}

	source: ^Chan
	source, err = resolve(ns, source_path)
	if err != OK {
		return err
	}
	defer chan_close(source)

	return unmount(ns, source, over)
}
