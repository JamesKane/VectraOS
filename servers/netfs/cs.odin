/*
cs -- `/net/cs`, the name a dial string carries turned into an address.

A program writes a dial string and reads back what to open:

    write  tcp!fs!9fs
    read   /net/tcp/clone 10.0.2.15!564

That is the whole of the connection server. The names come from
`/lib/ndb/local`, which `sys/libndb` reads: `sys=fs` answers an `ip`, and
`tcp=9fs` answers a `port`. A part that is already a number is used as it
stands, so `tcp!10.0.2.15!9` needs no database at all.

**It lives in `netfs` rather than beside it.** `docs/FLEET.md` gives `cs` a
server of its own, and it will want one when `dns` arrives to answer the names
this file cannot. Until then a second server would only be a union member over
the `/net` this one already serves. So the file is here, and the split is a
later change with no caller to break.

**A translation belongs to the fid that asked for it.** Two programs dialling at
once must not read each other's answer. The write remembers what it worked out
against the fid it came in on, and the read answers that.
*/
package netfs

import "vsys:abi"
import "vsys:libndb"
import "vsys:libodin"
import "vsys:libuser"
import "vsys:vectra9"

CS_SLOTS :: 8
CS_TEXT :: 96

Cs_Slot :: struct {
	used: bool,
	fid:  vectra9.Fid,
	len:  int,
	text: [CS_TEXT]u8,
}

cs_slots: [CS_SLOTS]Cs_Slot

// The database, read once at start. A machine with no file has an empty one,
// and every name then has to be a number.
NDB_MAX :: 4096
ndb_text: [NDB_MAX]u8
ndb_len: int

// cs_load reads `/lib/ndb/local` into memory, once, before serving. A machine
// without the file simply has no names.
cs_load :: proc "contextless" () {
	fd := libuser.open("/lib/ndb/local", abi.O_RDONLY)
	if fd < 0 {
		return
	}
	at := 0
	for at < NDB_MAX {
		n := libuser.read(int(fd), ndb_text[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(fd))
	ndb_len = at
}

ndb :: proc "contextless" () -> string #no_bounds_check {
	return string(ndb_text[:ndb_len])
}

// -- The translation ----------------------------------------------------------

// numeric reports whether every byte is a digit. That is what makes a part of a
// dial string an address or a port rather than a name.
numeric :: proc "contextless" (s: string) -> bool #no_bounds_check {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// dotted reports whether a part looks like an address rather than a name.
dotted :: proc "contextless" (s: string) -> bool #no_bounds_check {
	dots := 0
	for i in 0 ..< len(s) {
		if s[i] == '.' {
			dots += 1
		} else if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return dots == 3
}

// cut splits `s` at the first `!`, which is what separates a dial string's
// three parts.
cut :: proc "contextless" (s: string) -> (head: string, rest: string, ok: bool) #no_bounds_check {
	for i in 0 ..< len(s) {
		if s[i] == '!' {
			return s[:i], s[i + 1:], true
		}
	}
	return s, "", false
}

/*
cs_translate turns `proto!host!service` into the line a caller opens: the
protocol's clone file, and the far end to connect to. A host that is already an
address and a service that is already a number are used as they stand. Anything
else is a query of the database, and a name it does not carry is a failure.
*/
cs_translate :: proc "contextless" (query: string, into: []u8) -> int #no_bounds_check {
	// Trim the newline a shell or a program leaves on the end.
	q := query
	for len(q) > 0 && (q[len(q) - 1] == '\n' || q[len(q) - 1] == '\r') {
		q = q[:len(q) - 1]
	}

	proto, rest, ok := cut(q)
	if !ok {
		return 0
	}
	if proto != "tcp" && proto != "udp" {
		return 0
	}
	host, service, ok2 := cut(rest)
	if !ok2 {
		return 0
	}

	ip := host
	if !dotted(host) {
		found, has := libndb.find(ndb(), "sys", host, "ip")
		if !has {
			return 0
		}
		ip = found
	}

	port := service
	if !numeric(service) {
		found, has := libndb.find(ndb(), proto, service, "port")
		if !has {
			return 0
		}
		port = found
	}

	sink := libodin.sink_from(into)
	libodin.put_str(&sink, "/net/")
	libodin.put_str(&sink, proto)
	libodin.put_str(&sink, "/clone ")
	libodin.put_str(&sink, ip)
	libodin.put_str(&sink, "!")
	libodin.put_str(&sink, port)
	libodin.put_str(&sink, "\n")
	return len(libodin.str(&sink))
}

// -- The answer, per fid ------------------------------------------------------

// cs_write works out a translation and remembers it for the fid that asked.
cs_write :: proc "contextless" (fid: vectra9.Fid, query: string) -> bool #no_bounds_check {
	scratch: [CS_TEXT]u8
	n := cs_translate(query, scratch[:])
	if n == 0 {
		return false
	}
	slot := cs_slot(fid)
	if slot < 0 {
		return false
	}
	e := &cs_slots[slot]
	e.used = true
	e.fid = fid
	e.len = n
	copy(e.text[:], scratch[:n])
	return true
}

/*
cs_read answers what this fid's write worked out, and forgets it. A second read
then answers nothing, and a caller sees the end of the answers.

**The offset is ignored, on purpose.** A caller writes the dial string and then
reads, on one descriptor, so the write has already moved the offset past where
the answer begins. This is a file whose read is a reply rather than a window on
bytes, as Plan 9's `cs` is. The reply is taken whole.
*/
cs_read :: proc "contextless" (fid: vectra9.Fid) -> string #no_bounds_check {
	for i in 0 ..< CS_SLOTS {
		e := &cs_slots[i]
		if e.used && e.fid == fid {
			e.used = false
			return string(e.text[:e.len])
		}
	}
	return ""
}

// cs_forget drops a fid's answer, which a clunk does.
cs_forget :: proc "contextless" (fid: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< CS_SLOTS {
		if cs_slots[i].used && cs_slots[i].fid == fid {
			cs_slots[i].used = false
		}
	}
}

// cs_slot finds this fid's slot, or a free one.
cs_slot :: proc "contextless" (fid: vectra9.Fid) -> int #no_bounds_check {
	for i in 0 ..< CS_SLOTS {
		if cs_slots[i].used && cs_slots[i].fid == fid {
			return i
		}
	}
	for i in 0 ..< CS_SLOTS {
		if !cs_slots[i].used {
			return i
		}
	}
	return -1
}
