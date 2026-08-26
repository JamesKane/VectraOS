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

/*
Mount_Point is reference counted, and outlives the table it was filed in.

The table holds one reference; every `Chan.union_head` holds another. That is
not bookkeeping for its own sake -- a chan reached through a union keeps a
pointer to the mount point so `readdir` can find the other members, and
unmounting while that chan is alive would otherwise free the object it points
at. `unmount` therefore dissolves rather than deletes: the members go, the
struct stays until the last chan lets go, and a chan holding an empty mount
point behaves like one that was never in a union at all.

`members` is guarded by `object_lock`, not by the namespace's lock, for the
same reason: a mount point can be reached from a chan whose namespace has
already been torn down, and a lock you can only find through the namespace is
no lock at all by then.
*/
Mount_Point :: struct {
	server:  ^Server, // Identity half of the key: whose qid.path this is
	path:    u64,
	members: ^Mount,
	refs:    int,

	/*
	Bumped every time `members` changes, so a walker can tell whether the list
	it just searched held still while it was searching.

	Plan 9 does not need this: it read-locks the mount head for the whole union
	search, which it can do because its locks put a process to sleep and a 9P
	call under one is ordinary. Vectra's lock is the interrupt flag, so holding
	it across a message is not an option -- see `lock.odin` -- and the search
	has to let go between members. That leaves one hole, and it is a real one:
	a member removed from the *front* of the list shifts every later member
	down by one, and a walker resuming at index 1 skips the entry that used to
	be there. The file it was looking for is still bound, still in the same
	tree, and the walk says ENOENT.

	The counter closes it without a lock. A search that finds nothing is only
	believed if the list is the same one it started on; otherwise the search
	was inconclusive and runs again. See `walk1_ex`.
	*/
	generation: u64,
	next:    ^Mount_Point, // Hash chain
}

// members_changed records that a walker's view of this mount point is stale.
// Requires `object_lock`.
@(private)
members_changed :: proc "contextless" (mp: ^Mount_Point) {
	mp.generation += 1
}

// mount_point_generation reads that counter. A walker compares it before and
// after searching; equal means the answer is trustworthy.
@(private)
mount_point_generation :: proc "contextless" (mp: ^Mount_Point) -> u64 {
	if mp == nil {
		return 0
	}
	g := vlock(&object_lock)
	defer vunlock(&object_lock, g)
	return mp.generation
}

mount_point_incref :: proc(mp: ^Mount_Point) -> ^Mount_Point {
	if mp == nil {
		return nil
	}
	g := vlock(&object_lock)
	mp.refs += 1
	vunlock(&object_lock, g)
	return mp
}

/*
mount_point_release drops a reference and frees the last one.

Whatever drives the count to zero has already been unlinked -- the table's own
reference is the one `mount_point_unlink` drops -- so `members` is nil by
construction here and there is nothing left to send a message about.
*/
mount_point_release :: proc(mp: ^Mount_Point) {
	if mp == nil {
		return
	}
	g := vlock(&object_lock)
	mp.refs -= 1
	last := mp.refs <= 0
	vunlock(&object_lock, g)
	if last {
		free(mp)
	}
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

**The caller must hold `ns.lock`**, and must not let go of it before it has
either finished with the result or taken a reference to it. Returning a bare
pointer out from under the lock is `mount_head_ref`'s job.
*/
@(private)
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

/*
mount_head_ref is `mount_head` for a caller that does not hold the lock.

Returns a counted reference, or nil. The caller releases it with
`mount_point_release`. This is the only way out of the table for anything that
means to keep the pointer.
*/
mount_head_ref :: proc(ns: ^Namespace, c: ^Chan) -> ^Mount_Point {
	if ns == nil {
		return nil
	}
	g := vlock(&ns.lock)
	defer vunlock(&ns.lock, g)
	return mount_point_incref(mount_head(ns, c))
}

// mount_head_create requires `ns.lock`, like `mount_head`. The table's own
// reference is the one this hands out.
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
	mp.refs = 1

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

	// The member is the root of its own tree, not a member of whatever union
	// `source` was reached through. The clone inherited that reference; drop
	// it rather than overwriting the field and losing the count.
	if member_chan.union_head != nil {
		mount_point_release(member_chan.union_head)
		member_chan.union_head = nil
	}

	m := new(Mount)
	if m == nil {
		chan_close(member_chan)
		return vectra9.ENOMEM
	}
	m.chan = member_chan
	m.flags = flags

	/*
	Everything above this point sent messages; nothing below it does.

	That split is the whole locking discipline in one procedure. The two clones
	are Twalks and cannot happen under a lock, so the table is not touched until
	both have landed -- and `.Replace` hands the list it displaces back to the
	caller's stack rather than freeing it here, because freeing a member clunks
	a fid, which is another message.
	*/
	displaced: ^Mount

	gl := vlock(&ns.lock)
	mp := mount_head_create(ns, over)
	if mp == nil {
		vunlock(&ns.lock, gl)
		chan_close(member_chan)
		free(m)
		return vectra9.ENOMEM
	}

	go := vlock(&object_lock)
	switch order {
	case .Replace:
		displaced = mp.members
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
	members_changed(mp)
	vunlock(&object_lock, go)
	vunlock(&ns.lock, gl)

	members_free(displaced)
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

	// Members come off the list under the lock and are freed off it, for the
	// same reason `bind` displaces rather than frees: closing a member chan
	// clunks a fid, and a fid is a message.
	removed: ^Mount
	err := OK

	gl := vlock(&ns.lock)
	go := vlock(&object_lock)

	mp := mount_head(ns, over)
	if mp == nil {
		err = vectra9.EINVAL
	} else if source == nil {
		removed = mp.members
		mp.members = nil
	} else {
		tail: ^Mount
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
				m.next = nil
				if tail == nil {
					removed = m
				} else {
					tail.next = m
				}
				tail = m
			} else {
				prev = m
			}
			m = next
		}
		if removed == nil {
			err = vectra9.EINVAL
		}
	}

	// An empty mount point leaves the table. It does not necessarily leave
	// memory: a chan reached through it still holds a reference, and finds an
	// empty list, which is exactly what "this union has been dissolved" should
	// look like from inside.
	if err == OK {
		members_changed(mp)
	}

	orphaned := false
	if err == OK && mp.members == nil {
		orphaned = mount_point_unlink(ns, mp)
	}

	vunlock(&object_lock, go)
	vunlock(&ns.lock, gl)

	if orphaned {
		free(mp)
	}
	members_free(removed)
	return err
}

/*
mount_point_unlink takes a mount point out of the table and drops the table's
reference to it. Requires `ns.lock` and `object_lock`.

The count is decremented inline rather than through `mount_point_release`,
which would take `object_lock` a second time -- harmless, since it nests, but
the free has to happen outside both locks and doing it here would put a heap
call under the namespace lock for no reason.
*/
@(private)
mount_point_unlink :: proc(ns: ^Namespace, mp: ^Mount_Point) -> (orphaned: bool) #no_bounds_check {
	bucket := mount_hash(mp.server, mp.path)
	prev: ^Mount_Point
	for cur := ns.mounts[bucket]; cur != nil; cur = cur.next {
		if cur == mp {
			if prev == nil {
				ns.mounts[bucket] = cur.next
			} else {
				prev.next = cur.next
			}
			cur.next = nil
			ns.mount_count -= 1
			mp.refs -= 1
			return mp.refs <= 0
		}
		prev = cur
	}
	return false
}

/*
member_ref_at returns a counted reference to the member at `idx`.

Index rather than pointer, and a reference rather than a borrow, because the
two callers that walk a union -- `walk1_ex` and `readdir_union` -- send a
message per member and cannot hold a lock while they do. Re-finding the member
by position each time is what makes that safe: the list may have changed, and
the worst that costs is a member visited twice or skipped, which is already
what rebinding a union mid-walk means. What it cannot do is hand back a pointer
to something freed.

`ok` is false past the end. The caller closes what it gets.
*/
@(private)
member_ref_at :: proc(mp: ^Mount_Point, idx: int) -> (c: ^Chan, flags: Mount_Flags, ok: bool) {
	if mp == nil || idx < 0 {
		return nil, {}, false
	}
	g := vlock(&object_lock)
	defer vunlock(&object_lock, g)

	i := 0
	for m := mp.members; m != nil; m = m.next {
		if i == idx {
			return chan_incref(m.chan), m.flags, true
		}
		i += 1
	}
	return nil, {}, false
}

/*
members_free closes a list of members that is no longer in any table.

Never called with a lock held: every `chan_close` here may clunk a fid, and a
fid is a message. `bind` and `unmount` both detach first and call this after.
*/
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

/*
mount_point_refs reports how many holders a mount point has.

Introspection for the self-test, and the only way to see the invariant that
matters directly: a mount point in a table with one chan reached through it has
exactly two references, and dissolving it must leave exactly one. The
alternative -- inferring it from behaviour after the fact -- does not work,
because a `Mount_Point` freed one reference early still reads as a valid empty
one until something else claims the block.
*/
mount_point_refs :: proc "contextless" (mp: ^Mount_Point) -> int {
	if mp == nil {
		return 0
	}
	g := vlock(&object_lock)
	defer vunlock(&object_lock, g)
	return mp.refs
}

// member_count reports how many trees a mount point presents as one. One is an
// ordinary mount; more is a union. Zero is a mount point that has been
// dissolved and is still referenced -- see `Mount_Point`.
member_count :: proc "contextless" (mp: ^Mount_Point) -> int {
	if mp == nil {
		return 0
	}
	g := vlock(&object_lock)
	defer vunlock(&object_lock, g)

	n := 0
	for m := mp.members; m != nil; m = m.next {
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
union_create_target :: proc(mp: ^Mount_Point) -> ^Chan {
	if mp == nil {
		return nil
	}
	g := vlock(&object_lock)
	defer vunlock(&object_lock, g)

	for m := mp.members; m != nil; m = m.next {
		if .Create in m.flags {
			// A counted reference, because the answer outlives the lock and
			// the member could be unbound the instant it is released. The
			// caller closes it.
			return chan_incref(m.chan)
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
