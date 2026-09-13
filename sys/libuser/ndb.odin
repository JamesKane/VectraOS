/*
The network database, read from a process, `docs/FLEET.md` step 3.

`sys/libndb` walks the text of `/lib/ndb/local` and never opens it -- so a
process that wants one attribute off one record opens the file itself and hands
the text over. This is that: read the local database, find the record where
`sys=` is a machine's name, and answer one of its attributes. `cmd/role` asks it
whether this machine's line carries `terminal=`, `cpu=` or `fs=`, and `/lib/init`
starts the services a present role names. A role's value is usually empty, so
`ok` -- not a non-empty value -- is what tells presence from absence.
*/
package libuser

import "vsys:libndb"

// NDB is the local database every machine reads its own lines out of, the same
// file `servers/netfs` and `servers/cs` open.
NDB :: "/lib/ndb/local"

/*
ndb_attr answers the value of `attr` on the record where `sys=name`, copied into
`buf`. `ok` is false when the database will not read, the record is absent, or it
carries no such attribute; it is true even when the value is empty, which is how
a role attribute like `terminal=` reads. The whole file is read once, because a
record continues across lines and the walk needs it entire.
*/
ndb_attr :: proc(name: string, attr: string, buf: []u8) -> (value: string, ok: bool) {
	text, read_ok := read_file(NDB, context.allocator)
	if !read_ok {
		return "", false
	}
	defer delete(text)
	v, found := libndb.find(string(text), "sys", name, attr)
	if !found {
		return "", false
	}
	n := copy(buf, v)
	return string(buf[:n]), true
}
