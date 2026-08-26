/*
Namespace -- a private mapping from names to files.

Not a view of a global tree with permissions on it. There is no global tree. A
namespace is a root chan and a mount table, and everything a process can name
is reachable from those two things or from `#name`, which is section 5.8's
deliberate escape hatch.

That is what "modular operating system" means here in concrete terms: a service
is swapped by rebinding a name, not by changing a subsystem. Testing the network
stack means running the real one and binding a fake `/net` over it in one
process, while every other process on the machine goes on using the real one.
*/
package vfs

import "vsys:vectra9"

Namespace :: struct {
	root:        ^Chan,
	mounts:      [MOUNT_BUCKETS]^Mount_Point,
	mount_count: int,
	refs:        int,
}

/*
How a child gets its namespace, following Plan 9's rfork.

The default -- no flags -- is *share*, which surprises people and is right: a
later `bind` in either process is visible to both, which is how a shell's `bind`
affects the commands it runs.

`Clean` is the interesting one. A process with an empty namespace cannot open a
file, because there are no names: it is a sandbox with nothing to escape from,
and the parent constructs its world by binding exactly what it should have.
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
	if ns != nil {
		ns.refs += 1
	}
	return ns
}

/*
ns_set_root installs the namespace root, cloning the caller's handle.

Cloned rather than increfed because the root is the one chan the walker starts
from on every absolute path, and a caller that later opened or closed its own
copy would otherwise be reaching into the namespace's state.

`..` at the root is the root: `root.tree_root` equals `root.qid` and its
`mounted_over` is nil, so the climb in `walk1` has nowhere to go. That is what
makes a chroot-equivalent free -- a process whose root is a subtree simply has
no name for anything outside it.
*/
ns_set_root :: proc(ns: ^Namespace, c: ^Chan) -> Errno {
	if ns == nil || c == nil {
		return vectra9.EINVAL
	}
	root, err := chan_clone(c)
	if err != OK {
		return err
	}
	if ns.root != nil {
		chan_close(ns.root)
	}
	ns.root = root
	return OK
}

/*
ns_fork produces the child's namespace.

Copy duplicates the mount table and shares the member chans, which is safe
because nothing in this package mutates one: a walk from a member allocates a
fresh fid rather than moving the member's, and `bind` and `unmount` replace
list entries rather than editing them. Reference counting is what makes the
sharing invisible.
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
	if ns.root != nil {
		if err := ns_set_root(child, ns.root); err != OK {
			ns_close(child)
			return nil
		}
	}

	for bucket in 0 ..< MOUNT_BUCKETS {
		for mp := ns.mounts[bucket]; mp != nil; mp = mp.next {
			copy_mp := new(Mount_Point)
			if copy_mp == nil {
				ns_close(child)
				return nil
			}
			copy_mp.server = mp.server
			copy_mp.path = mp.path
			copy_mp.next = child.mounts[bucket]
			child.mounts[bucket] = copy_mp
			child.mount_count += 1

			tail: ^Mount
			for m := mp.members; m != nil; m = m.next {
				copy_m := new(Mount)
				if copy_m == nil {
					ns_close(child)
					return nil
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
	return child
}

// ns_close drops a reference and tears the namespace down when the last one
// goes. Every chan it holds is released, which clunks every fid it opened --
// the only thing that stops a server's fid table filling up with the handles
// of processes that have exited.
ns_close :: proc(ns: ^Namespace) #no_bounds_check {
	if ns == nil {
		return
	}
	ns.refs -= 1
	if ns.refs > 0 {
		return
	}

	for bucket in 0 ..< MOUNT_BUCKETS {
		mp := ns.mounts[bucket]
		for mp != nil {
			next := mp.next
			members_free(mp.members)
			free(mp)
			mp = next
		}
		ns.mounts[bucket] = nil
	}
	ns.mount_count = 0

	if ns.root != nil {
		chan_close(ns.root)
		ns.root = nil
	}
	free(ns)
}
