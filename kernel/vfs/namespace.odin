/*
Namespace -- a private mapping from names to files.

Not a view of a global tree with permissions on it. There is no global tree. A
namespace is a root chan and a mount table. Everything a process can name is
reachable from those two things, or from `#name`, which is section 5.8's
deliberate escape hatch.

That is what `modular operating system` means here in concrete terms. A rebound
name swaps a service. A changed subsystem does not.

To test the network stack, run the real one and bind a fake `/net` over it in
one process. Every other process on the machine goes on using the real one.
*/
package vfs

import "kernel:sync"
import "vsys:vectra9"

Namespace :: struct {
	root:        ^Chan,
	mounts:      [MOUNT_BUCKETS]^Mount_Point,
	mount_count: int,
	refs:        int,

	/*
	Guards every field above it.

	Per namespace, because a namespace is the object processes choose to share.
	`rfork` with no flags hands the child this same pointer, so a `bind` in either
	is a mutation both see. That is the feature rather than an accident. Two
	processes in *different* namespaces contend for nothing here, which is what
	makes the granularity worth having.

	What it does not guard is anything reachable from a namespace other than
	this one -- chan reference counts, mount point member lists. Those are
	`object_lock`'s, and `lock.odin` says why.
	*/
	lock:        sync.Spinlock,
}

/*
How a child gets its namespace, following Plan 9's rfork.

The default, no flags, is *share*. That surprises people and is right. A later
`bind` in either process is visible to both, which is how a shell's `bind`
affects the commands it runs.

`Clean` is the interesting one. A process with an empty namespace cannot open a
file, because there are no names. It is a sandbox with nothing to escape from.
The parent then builds its world, and binds exactly what it should have.
`Clean` and `Copy` together is `Clean` -- there is nothing to copy.
*/
Fork_Flag :: enum {
	Copy, // Duplicate the mount table; both start identical and then diverge
	Clean, // Start empty -- no root, no mounts, no way to name anything
}

Fork_Flags :: bit_set[Fork_Flag]

ns_new :: proc() -> ^Namespace {
	ns := new(Namespace)
	if ns == nil {
		return nil
	}
	ns.refs = 1
	return ns
}

ns_incref :: proc(ns: ^Namespace) -> ^Namespace {
	if ns == nil {
		return nil
	}
	g := sync.acquire(&ns.lock)
	ns.refs += 1
	sync.release(&ns.lock, g)
	return ns
}

/*
ns_set_root installs the namespace root, cloning the caller's handle.

Cloned rather than increfed, because the root is the one chan the walker starts
from on every absolute path. A caller that later opened or closed its own copy
would otherwise reach into the namespace's state.

`..` at the root is the root: `root.tree_root` equals `root.qid` and its
`mounted_over` is nil, so the climb in `walk1` has nowhere to go. That is what
makes a chroot-equivalent free -- a process whose root is a subtree simply has
no name for anything outside it.
*/
ns_set_root :: proc(ns: ^Namespace, c: ^Chan) -> Errno {
	if ns == nil || c == nil {
		return vectra9.EINVAL
	}
	// The clone is a message and so happens before the lock. What the lock covers
	// is the swap, and what it hands back is the old root. That root closes after
	// the lock, because a close clunks a fid.
	root, err := chan_clone(c)
	if err != OK {
		return err
	}

	g := sync.acquire(&ns.lock)
	old := ns.root
	ns.root = root
	sync.release(&ns.lock, g)

	chan_close(old)
	return OK
}

/*
ns_root_ref takes a counted reference to the namespace root.

The root is a pointer another thread may replace, because `ns_set_root` swaps
it and closes the old one. A walker that read the field and then sent a message
would walk a clunked chan. Every reader goes through this and closes what it
gets.
*/
@(private)
ns_root_ref :: proc(ns: ^Namespace) -> ^Chan {
	if ns == nil {
		return nil
	}
	g := sync.acquire(&ns.lock)
	defer sync.release(&ns.lock, g)
	return chan_incref(ns.root)
}

/*
ns_fork produces the child's namespace.

Copy duplicates the mount table and shares the member chans. That is safe
because nothing in this package mutates one. A walk from a member allocates a
fresh fid rather than moves the member's, and `bind` and `unmount` replace list
entries rather than edit them. Reference counting is what makes the sharing
invisible.
*/
ns_fork :: proc(ns: ^Namespace, flags: Fork_Flags = {}) -> ^Namespace #no_bounds_check {
	if ns == nil {
		return nil
	}
	if .Clean in flags {
		return ns_new()
	}
	if .Copy not_in flags {
		return ns_incref(ns)
	}

	child := ns_new()
	if child == nil {
		return nil
	}

	/*
	The root is cloned first, on its own, because cloning is a message: it
	cannot happen inside the lock the copy below needs.

	`ns.root` is read under the parent's lock and a reference taken, so a
	concurrent `ns_set_root` cannot free it between the read and the clone.
	*/
	gr := sync.acquire(&ns.lock)
	parent_root := chan_incref(ns.root)
	sync.release(&ns.lock, gr)

	if parent_root != nil {
		err := ns_set_root(child, parent_root)
		chan_close(parent_root)
		if err != OK {
			ns_close(child)
			return nil
		}
	}

	/*
	The table copy holds the parent's lock throughout, and may. It allocates and
	increments counts, and does neither of the two things a lock here must not do.
	It sends no message, and it never takes the child's lock -- the child is not
	published until this returns, so nothing else can reach it.
	*/
	gl := sync.acquire(&ns.lock)
	go := sync.acquire(&object_lock)
	ok := true

	copy_loop: for bucket in 0 ..< MOUNT_BUCKETS {
		for mp := ns.mounts[bucket]; mp != nil; mp = mp.next {
			copy_mp := new(Mount_Point)
			if copy_mp == nil {
				ok = false
				break copy_loop
			}
			copy_mp.server = mp.server
			copy_mp.path = mp.path
			copy_mp.refs = 1
			copy_mp.next = child.mounts[bucket]
			child.mounts[bucket] = copy_mp
			child.mount_count += 1

			tail: ^Mount
			for m := mp.members; m != nil; m = m.next {
				copy_m := new(Mount)
				if copy_m == nil {
					ok = false
					break copy_loop
				}
				copy_m.chan = chan_incref(m.chan)
				copy_m.flags = m.flags
				if tail == nil {
					copy_mp.members = copy_m
				} else {
					tail.next = copy_m
				}
				tail = copy_m
			}
		}
	}

	sync.release(&object_lock, go)
	sync.release(&ns.lock, gl)

	if !ok {
		// Whatever the copy produced is a well-formed namespace. To tear it down is
		// the ordinary path, and that clunks the fids the copy took.
		ns_close(child)
		return nil
	}
	return child
}

// ns_close drops a reference and tears the namespace down when the last one
// goes. It releases every chan it holds, which clunks every fid it opened.
// That is the only thing that stops a server's fid table from filling with the
// handles of processes that exited.
ns_close :: proc(ns: ^Namespace) #no_bounds_check {
	if ns == nil {
		return
	}
	g := sync.acquire(&ns.lock)
	ns.refs -= 1
	last := ns.refs <= 0
	sync.release(&ns.lock, g)
	if !last {
		return
	}

	/*
	Nothing else can reach this namespace now, because the last reference was
	ours. The loop below therefore runs unlocked, and has to. Every `members_free`
	clunks a fid, and a mount point that outlives the table still needs its
	reference dropped, which may free it.

	`object_lock` is still taken for the member lists themselves. A chan that
	holds one of these mount points through `union_head` can outlive the
	namespace, and go on reading them.
	*/
	for bucket in 0 ..< MOUNT_BUCKETS {
		mp := ns.mounts[bucket]
		ns.mounts[bucket] = nil
		for mp != nil {
			next := mp.next
			mp.next = nil

			go := sync.acquire(&object_lock)
			members := mp.members
			mp.members = nil
			members_changed(mp)
			mp.refs -= 1
			orphaned := mp.refs <= 0
			sync.release(&object_lock, go)

			members_free(members)
			if orphaned {
				free(mp)
			}
			mp = next
		}
	}
	ns.mount_count = 0

	if ns.root != nil {
		chan_close(ns.root)
		ns.root = nil
	}
	free(ns)
}
