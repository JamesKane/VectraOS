/*
ndb -- query the network database for the shell.

    ndb attr [filter value]

Prints the `sys=` of every record that has `attr=`, one per line; with a filter,
only those whose `filter=` is `value`. `ndb cpu` names the CPU servers, and `ndb
cpu cputype amd64` the ones of an architecture -- which is what `fleet` reads to
send work across the rack. `libndb` and `role` name a record by `sys=`; this
walks them the other way, so a script can loop over a role. `docs/FLEET.md`
section 8.
*/
package ndb

import "vsys:abi"
import "vsys:libndb"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) < 1 {
		libuser.eprint("usage: ndb attr [filter value]\n")
		libuser.exits("usage")
	}
	attr := args[0]
	fattr, fval := "", ""
	if len(args) >= 3 {
		fattr = args[1]
		fval = args[2]
	}

	text, ok := libuser.read_file(libuser.NDB, context.allocator)
	if !ok {
		libuser.eprint("ndb: can't read ", libuser.NDB, "\n")
		libuser.exits("read")
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	at := 0
	for {
		rec, next, more := libndb.record_at(string(text), at)
		if !more {
			break
		}
		at = next
		if _, has := libndb.attr_of(rec, attr); !has {
			continue
		}
		if fattr != "" {
			if v, hf := libndb.attr_of(rec, fattr); !hf || v != fval {
				continue
			}
		}
		if sys, hs := libndb.attr_of(rec, "sys"); hs && sys != "" {
			libuser.bio_puts(&out, sys)
			libuser.bio_putc(&out, '\n')
		}
	}
	libuser.bio_flush(&out)
	libuser.exits("")
}
