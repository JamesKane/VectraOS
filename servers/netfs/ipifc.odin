/*
ipifc -- the interfaces, the routes, and the files that set them.

A machine has a card per link, and `#E` serves each as `/dev/etherN`. This is
the stack's side of that: an interface per card, with an address, a mask, an
ARP table and the datagrams waiting on it, and a route table that says which
interface a destination leaves by and through whom.

    /net/ipifc/N/ctl     `add a.b.c.d m.m.m.m`, `remove`
    /net/ipifc/N/status  the card, its hardware address, its address and mask
    /net/iproute         the routes; `add dst mask gw`, `remove dst mask`
    /net/ndb             what this machine learned about itself, as text

An interface's own subnet is a route nobody has to add: a destination on it
leaves by that interface, addressed directly. Every other route names a
gateway, and the gateway is reached the same way. A destination no route
covers is dropped, which is Plan 9's `Enoroute`.

**An interface with no address still sends and receives.** `ipconfig` asks
for one by broadcasting from `0.0.0.0`, and the answer comes to the
broadcast address or to the address being offered. So a frame for an
unconfigured interface is taken whatever address it names, and a datagram for
`255.255.255.255` goes to the broadcast hardware address on the interface a
conversation is bound to, with no ARP asked.
*/
package netfs

import "vsys:abi"
import "vsys:libndb"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

MAX_IFC :: 2
MAX_ROUTES :: 8
NDB_TEXT_MAX :: 512

BROADCAST :: libnet.IP{255, 255, 255, 255}
BROADCAST_MAC :: libnet.MAC{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
ANY :: libnet.IP{0, 0, 0, 0}

/*
A datagram whose next hop is not in the ARP table waits in one of these
slots while the request for that address is out. There is a slot per waiting
hop, so a first packet to one fresh peer does not evict the one waiting on
another. One packet waits per hop, the newest, the way a Plan 9 `Arpent`
holds its last block. When the reply teaches us the address, `flush_pending`
sends what was waiting on it.
*/
PENDING_SLOTS :: 4

Pending :: struct {
	have:  bool,
	hop:   libnet.IP, // The address asked for, a gateway or the destination
	dst:   libnet.IP, // What the datagram's header names
	proto: u8,
	blen:  int,
	body:  [1500]u8,
}

Ifc :: struct {
	used:          bool,
	fd:            int, // /dev/etherN/data
	mac:           libnet.MAC,
	ip:            libnet.IP, // Zero until configured
	mask:          libnet.IP,
	arp:           libnet.Arp_Table,
	pending:       [PENDING_SLOTS]Pending,
	pending_evict: int,

	// What crossed the card, which `/net/etherN/stats` reports.
	frames_in:     int,
	frames_out:    int,
	ip_in:         int,
	ip_not_mine:   int,
	ip_bad:        int,
	arp_asked:     int,
}

ifcs: [MAX_IFC]Ifc
ifc_count: int

Route :: struct {
	used: bool,
	dst:  libnet.IP,
	mask: libnet.IP,
	gw:   libnet.IP,
}

routes: [MAX_ROUTES]Route

// What `ipconfig` learned, kept as text for whoever asks: `/net/ndb`.
// This machine's name, from the database record its card matched: `/net/sysname`.
sysname: [64]u8
sysname_len: int

ndb_note: [NDB_TEXT_MAX]u8
ndb_note_len: int

// The database, read once at start. A machine with no file has an empty one,
// and an interface then has no address until `ipconfig` asks for one.
NDB_MAX :: 4096
ndb_text: [NDB_MAX]u8
ndb_len: int

// ndb_load reads `/lib/ndb/local` into memory, once, before serving.
ndb_load :: proc "contextless" () {
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

// -- The interfaces -----------------------------------------------------------

/*
open_ifcs opens every card `#E` serves, in order, and answers how many. A
machine with no card answers zero, and the stack has nothing to serve.
*/
open_ifcs :: proc "contextless" () -> int #no_bounds_check {
	names := [?]string{"ether0", "ether1"}
	for i in 0 ..< MAX_IFC {
		path: [32]u8
		afd := libuser.open(libuser.cat_into(path[:], "/dev/", names[i], "/addr"), abi.O_RDONLY)
		if afd < 0 {
			break
		}
		raw: [6]u8
		n := libuser.read(int(afd), raw[:])
		_ = libuser.close(int(afd))
		if n != 6 {
			break
		}
		dfd := libuser.open(libuser.cat_into(path[:], "/dev/", names[i], "/data"), abi.O_RDWR)
		if dfd < 0 {
			break
		}
		f := &ifcs[i]
		f.used = true
		f.fd = int(dfd)
		f.mac = libnet.MAC{raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]}
		ifc_count = i + 1
	}
	return ifc_count
}

// ifc_name answers `etherN` for interface `i`.
ifc_name :: proc "contextless" (i: int) -> string {
	names := [?]string{"ether0", "ether1"}
	return i >= 0 && i < len(names) ? names[i] : "ether?"
}

// primary_ip is the address this machine calls its own: the first
// interface's. `/net/local` and a dial string's `*` name it.
primary_ip :: proc "contextless" () -> libnet.IP #no_bounds_check {
	for i in 0 ..< ifc_count {
		if ifcs[i].ip != ANY {
			return ifcs[i].ip
		}
	}
	return ANY
}

// ifc_holding answers the interface whose address `ip` is, or -1.
ifc_holding :: proc "contextless" (ip: libnet.IP) -> int #no_bounds_check {
	if ip == ANY {
		return -1
	}
	for i in 0 ..< ifc_count {
		if ifcs[i].ip == ip {
			return i
		}
	}
	return -1
}

// same_subnet reports whether `a` and `b` agree under `mask`.
same_subnet :: proc "contextless" (a, b, mask: libnet.IP) -> bool {
	for i in 0 ..< 4 {
		if a[i] & mask[i] != b[i] & mask[i] {
			return false
		}
	}
	return true
}

// mask_bits counts a mask's ones, so a longer match wins a route lookup.
mask_bits :: proc "contextless" (mask: libnet.IP) -> int {
	n := 0
	for i in 0 ..< 4 {
		b := mask[i]
		for b != 0 {
			n += int(b & 1)
			b >>= 1
		}
	}
	return n
}

// on_link answers the interface whose subnet holds `ip`, or -1.
on_link :: proc "contextless" (ip: libnet.IP) -> int #no_bounds_check {
	for i in 0 ..< ifc_count {
		f := &ifcs[i]
		if f.ip != ANY && same_subnet(ip, f.ip, f.mask) {
			return i
		}
	}
	return -1
}

/*
route answers how to reach `dst`: the interface to leave by and the address to
resolve, which is `dst` itself on its own link and a gateway otherwise. The
longest route that covers `dst` wins, and a gateway must be on a link of this
machine's or the route is not one it can use.
*/
route :: proc "contextless" (dst: libnet.IP) -> (ifc: int, hop: libnet.IP, ok: bool) #no_bounds_check {
	if i := on_link(dst); i >= 0 {
		return i, dst, true
	}
	best := -1
	best_bits := -1
	for r in 0 ..< MAX_ROUTES {
		rt := &routes[r]
		if !rt.used || !same_subnet(dst, rt.dst, rt.mask) {
			continue
		}
		bits := mask_bits(rt.mask)
		if bits > best_bits && on_link(rt.gw) >= 0 {
			best = r
			best_bits = bits
		}
	}
	if best < 0 {
		return 0, ANY, false
	}
	gw := routes[best].gw
	return on_link(gw), gw, true
}

/*
source_for is the address a datagram to `dst` leaves with: the interface's
that `route` picks, or the bound interface's for a broadcast, which may be
nothing yet. A protocol asks before it sums its pseudo-header.
*/
source_for :: proc "contextless" (dst: libnet.IP, bound: int) -> (libnet.IP, bool) #no_bounds_check {
	if k := ifc_holding(dst); k >= 0 {
		return dst, true
	}
	if dst == BROADCAST {
		i := bound >= 0 && bound < ifc_count ? bound : 0
		return ifcs[i].ip, ifc_count > 0
	}
	i, _, ok := route(dst)
	if !ok {
		return ANY, false
	}
	return ifcs[i].ip, true
}

// -- The control files --------------------------------------------------------

/*
ifc_ctl takes one line for interface `i`. `add a.b.c.d m.m.m.m` gives it an
address, replacing the one it had, and `remove` takes the address away. The
ARP table stays: what was learned about the link is still true of it.
*/
ifc_ctl :: proc "contextless" (i: int, text: string) -> bool #no_bounds_check {
	if i < 0 || i >= ifc_count {
		return false
	}
	verb, rest := word(text)
	switch verb {
	case "add":
		a, r2 := word(rest)
		m, _ := word(r2)
		ip, ok := address(a)
		if !ok {
			return false
		}
		mask := libnet.IP{255, 255, 255, 0}
		if len(m) > 0 {
			mask, ok = address(m)
			if !ok {
				return false
			}
		}
		ifcs[i].ip = ip
		ifcs[i].mask = mask
		probe_gateway()
		return true
	case "remove":
		ifcs[i].ip = ANY
		ifcs[i].mask = ANY
		return true
	}
	return false
}

/*
route_ctl takes one line for the table. `add dst mask gw` puts a route in,
replacing one with the same destination and mask, and `remove dst mask` takes
one out. A default route is `add 0.0.0.0 0.0.0.0 gw`.
*/
route_ctl :: proc "contextless" (text: string) -> bool #no_bounds_check {
	verb, rest := word(text)
	d, r2 := word(rest)
	m, r3 := word(r2)
	dst, ok1 := address(d)
	mask, ok2 := address(m)
	if !ok1 || !ok2 {
		return false
	}
	switch verb {
	case "add":
		g, _ := word(r3)
		gw, ok3 := address(g)
		if !ok3 {
			return false
		}
		return route_add(dst, mask, gw)
	case "remove":
		for r in 0 ..< MAX_ROUTES {
			rt := &routes[r]
			if rt.used && rt.dst == dst && rt.mask == mask {
				rt.used = false
			}
		}
		return true
	}
	return false
}

route_add :: proc "contextless" (dst, mask, gw: libnet.IP) -> bool #no_bounds_check {
	slot := -1
	for r in 0 ..< MAX_ROUTES {
		rt := &routes[r]
		if rt.used && rt.dst == dst && rt.mask == mask {
			slot = r
			break
		}
		if !rt.used && slot < 0 {
			slot = r
		}
	}
	if slot < 0 {
		return false
	}
	routes[slot] = Route{used = true, dst = dst, mask = mask, gw = gw}
	probe_gateway()
	return true
}

// default_gateway answers the gateway of the default route, if there is one.
default_gateway :: proc "contextless" () -> (libnet.IP, bool) #no_bounds_check {
	for r in 0 ..< MAX_ROUTES {
		rt := &routes[r]
		if rt.used && rt.dst == ANY && rt.mask == ANY {
			return rt.gw, true
		}
	}
	return ANY, false
}

// ndb_set replaces what `/net/ndb` says.
ndb_set :: proc "contextless" (text: []u8) -> bool #no_bounds_check {
	if len(text) > NDB_TEXT_MAX {
		return false
	}
	copy(ndb_note[:], text)
	ndb_note_len = len(text)
	return true
}

/*
resolve_addresses finds each interface in the database by the address on its
card. A record carrying `ether=` for the card names the `ip` the interface
answers to, and `ipmask=` its mask, a class C when the record has none. So a
fleet keeps one database, and every machine reads its own lines out of it.
A `sys=gw` record is the default route, usable once an interface is on its
link. An interface with no record has no address, and waits for `ipconfig`.
*/
resolve_addresses :: proc "contextless" () #no_bounds_check {
	for i in 0 ..< ifc_count {
		f := &ifcs[i]
		hex: [16]u8
		sink := libodin.sink_from(hex[:])
		for k in 0 ..< 6 {
			libodin.put_uint(&sink, u64(f.mac[k]), 16, 2)
		}
		key := libodin.str(&sink)
		// The record's  is this machine's name, served as .
		if sn, hs := libndb.find(ndb(), "ether", key, "sys"); hs && sysname_len == 0 {
			sysname_len = copy(sysname[:], sn)
		}
		if text, has := libndb.find(ndb(), "ether", key, "ip"); has {
			if ip, ok := address(text); ok {
				f.ip = ip
				f.mask = libnet.IP{255, 255, 255, 0}
				if mtext, hasm := libndb.find(ndb(), "ether", key, "ipmask"); hasm {
					if mask, mok := address(mtext); mok {
						f.mask = mask
					}
				}
			}
		}
	}
	if text, has := libndb.find(ndb(), "sys", "gw", "ip"); has {
		if ip, ok := address(text); ok {
			_ = route_add(ANY, ANY, ip)
		}
	}
}

// -- What the files say -------------------------------------------------------

render_ifc_status :: proc "contextless" (sink: ^libodin.Sink, i: int) #no_bounds_check {
	f := &ifcs[i]
	libodin.put_str(sink, ifc_name(i))
	libodin.put_str(sink, " ")
	put_mac(sink, f.mac)
	libodin.put_str(sink, " ")
	put_ip(sink, f.ip)
	libodin.put_str(sink, " ")
	put_ip(sink, f.mask)
	libodin.put_str(sink, "\n")
}

render_routes :: proc "contextless" (sink: ^libodin.Sink) #no_bounds_check {
	for r in 0 ..< MAX_ROUTES {
		rt := &routes[r]
		if !rt.used {
			continue
		}
		put_ip(sink, rt.dst)
		libodin.put_str(sink, " ")
		put_ip(sink, rt.mask)
		libodin.put_str(sink, " ")
		put_ip(sink, rt.gw)
		libodin.put_str(sink, " ")
		if i := on_link(rt.gw); i >= 0 {
			libodin.put_str(sink, ifc_name(i))
		} else {
			libodin.put_str(sink, "-")
		}
		libodin.put_str(sink, "\n")
	}
}

render_ether_stats :: proc "contextless" (sink: ^libodin.Sink, i: int) #no_bounds_check {
	f := &ifcs[i]
	libodin.put_str(sink, "in ")
	libodin.put_uint(sink, u64(f.frames_in))
	libodin.put_str(sink, " out ")
	libodin.put_uint(sink, u64(f.frames_out))
	libodin.put_str(sink, " ip ")
	libodin.put_uint(sink, u64(f.ip_in))
	libodin.put_str(sink, " notmine ")
	libodin.put_uint(sink, u64(f.ip_not_mine))
	libodin.put_str(sink, " bad ")
	libodin.put_uint(sink, u64(f.ip_bad))
	libodin.put_str(sink, " arpasked ")
	libodin.put_uint(sink, u64(f.arp_asked))
	libodin.put_str(sink, "\n")
}

render_arp :: proc "contextless" (sink: ^libodin.Sink) #no_bounds_check {
	for i in 0 ..< ifc_count {
		for k in 0 ..< libnet.ARP_ENTRIES {
			e := &ifcs[i].arp.entries[k]
			if !e.valid {
				continue
			}
			put_ip(sink, e.ip)
			libodin.put_str(sink, " ")
			put_mac(sink, e.mac)
			libodin.put_str(sink, " ")
			libodin.put_str(sink, ifc_name(i))
			libodin.put_str(sink, "\n")
		}
	}
}
