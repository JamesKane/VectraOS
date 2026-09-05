/*
dns -- the question a resolver asks and the answer it reads, RFC 1035's.

A query is a twelve-byte header and one question: the name as labels, each
a length byte and its letters, then a type and a class. An answer repeats the
question and follows it with records, each a name, a type, a class, a time to
live and data. Names in an answer may point back at earlier bytes, two bits
set in a length byte and an offset in the rest, which is how the same name is
not spelled twice. This reads the pointers and refuses a loop.

What a client here wants is one thing: an address for a name. `parse_dns`
answers the first `A` record, following a `CNAME` when the answer holds one.
`put_dns_answer` writes the answer a server gives, so `tests/net` and a test
server can speak both sides.
*/
package libnet

DNS_PORT :: u16(53)
DNS_HDR :: 12
DNS_MAX :: 512

DNS_TYPE_A :: u16(1)
DNS_TYPE_CNAME :: u16(5)
DNS_CLASS_IN :: u16(1)

// The most labels a name walk follows, so a pointer that loops ends.
@(private = "file")
DNS_HOPS :: 32

/*
put_dns_query writes a query for `name`'s address into `b` and answers its
length, or zero for a name that will not encode: a label over 63 bytes, or a
name over what a message holds. Recursion is asked for, which a resolver at a
router expects.
*/
put_dns_query :: proc "contextless" (b: []u8, id: u16, name: string) -> int #no_bounds_check {
	if len(b) < DNS_HDR + len(name) + 2 + 4 {
		return 0
	}
	put_be16(b, 0, id)
	put_be16(b, 2, 0x0100) // A query, recursion desired
	put_be16(b, 4, 1) // One question
	put_be16(b, 6, 0)
	put_be16(b, 8, 0)
	put_be16(b, 10, 0)
	at := put_dns_name(b, DNS_HDR, name)
	if at == 0 {
		return 0
	}
	put_be16(b, at, DNS_TYPE_A)
	put_be16(b, at + 2, DNS_CLASS_IN)
	return at + 4
}

// put_dns_name writes `name` as labels at `at` and answers the offset past
// the terminating zero, or zero for a name that will not encode.
put_dns_name :: proc "contextless" (b: []u8, at: int, name: string) -> int #no_bounds_check {
	pos := at
	start := 0
	for i := 0; i <= len(name); i += 1 {
		if i == len(name) || name[i] == '.' {
			n := i - start
			if n == 0 {
				if i == len(name) && start == len(name) && len(name) > 0 {
					break // A trailing dot
				}
				return 0
			}
			if n > 63 || pos + 1 + n + 1 > len(b) {
				return 0
			}
			b[pos] = u8(n)
			copy(b[pos + 1:pos + 1 + n], name[start:i])
			pos += 1 + n
			start = i + 1
		}
	}
	if pos >= len(b) {
		return 0
	}
	b[pos] = 0
	return pos + 1
}

/*
skip_dns_name steps over a name at `at`, pointers included, and answers the
offset after it, or zero for a name that runs off the message or loops. A
pointer ends the name where it stands; what it points at is not walked, since
only the length matters here.
*/
skip_dns_name :: proc "contextless" (p: []u8, at: int) -> int #no_bounds_check {
	pos := at
	for _ in 0 ..< DNS_HOPS {
		if pos >= len(p) {
			return 0
		}
		n := int(p[pos])
		if n == 0 {
			return pos + 1
		}
		if n & 0xC0 == 0xC0 {
			return pos + 2 <= len(p) ? pos + 2 : 0
		}
		pos += 1 + n
	}
	return 0
}

/*
read_dns_name copies the name at `at` into `into` as dotted text, following
pointers, and answers its length and the offset after the name as it stands
in the message. A name that loops or runs off the message answers zero.
*/
read_dns_name :: proc "contextless" (p: []u8, at: int, into: []u8) -> (length: int, after: int) #no_bounds_check {
	pos := at
	out := 0
	jumped := false
	for _ in 0 ..< DNS_HOPS {
		if pos >= len(p) {
			return 0, 0
		}
		n := int(p[pos])
		if n == 0 {
			if !jumped {
				after = pos + 1
			}
			return out, after
		}
		if n & 0xC0 == 0xC0 {
			if pos + 1 >= len(p) {
				return 0, 0
			}
			if !jumped {
				after = pos + 2
			}
			jumped = true
			pos = (n & 0x3F) << 8 | int(p[pos + 1])
			continue
		}
		if pos + 1 + n > len(p) || out + n + 1 > len(into) {
			return 0, 0
		}
		if out > 0 {
			into[out] = '.'
			out += 1
		}
		copy(into[out:out + n], p[pos + 1:pos + 1 + n])
		out += n
		pos += 1 + n
	}
	return 0, 0
}

/*
parse_dns reads the answer to the query `id` and answers the first address
in it. The question is stepped over; then each answer record is read, and
an `A` record for the name asked -- or for a name a `CNAME` record led to --
is the answer. A reply for another query, an error code, or a message with
no address in it answers false.
*/
parse_dns :: proc "contextless" (p: []u8, id: u16, name: string) -> (ip: IP, ok: bool) #no_bounds_check {
	if len(p) < DNS_HDR || get_be16(p, 0) != id {
		return {}, false
	}
	flags := get_be16(p, 2)
	if flags & 0x8000 == 0 || flags & 0x000F != 0 {
		return {}, false
	}
	questions := int(get_be16(p, 4))
	answers := int(get_be16(p, 6))
	at := DNS_HDR
	for _ in 0 ..< questions {
		at = skip_dns_name(p, at)
		if at == 0 || at + 4 > len(p) {
			return {}, false
		}
		at += 4
	}
	// The name an address must be for: the one asked, until a CNAME says
	// otherwise. Compared without case, as names are.
	want: [256]u8
	want_len := min(len(name), len(want))
	copy(want[:want_len], name[:want_len])
	for _ in 0 ..< answers {
		owner: [256]u8
		n, after := read_dns_name(p, at, owner[:])
		if after == 0 || after + 10 > len(p) {
			return {}, false
		}
		kind := get_be16(p, after)
		class := get_be16(p, after + 2)
		rdlen := int(get_be16(p, after + 8))
		data := after + 10
		if data + rdlen > len(p) {
			return {}, false
		}
		if class == DNS_CLASS_IN && names_equal(owner[:n], want[:want_len]) {
			switch kind {
			case DNS_TYPE_A:
				if rdlen == 4 {
					for i in 0 ..< 4 {ip[i] = p[data + i]}
					return ip, true
				}
			case DNS_TYPE_CNAME:
				target: [256]u8
				tn, _ := read_dns_name(p, data, target[:])
				if tn > 0 {
					copy(want[:], target[:tn])
					want_len = tn
				}
			}
		}
		at = data + rdlen
	}
	return {}, false
}

// names_equal compares two names without regard to case or a trailing dot.
names_equal :: proc "contextless" (a, b: []u8) -> bool #no_bounds_check {
	x := a
	y := b
	if len(x) > 0 && x[len(x) - 1] == '.' {x = x[:len(x) - 1]}
	if len(y) > 0 && y[len(y) - 1] == '.' {y = y[:len(y) - 1]}
	if len(x) != len(y) {
		return false
	}
	for i in 0 ..< len(x) {
		c := x[i]
		d := y[i]
		if c >= 'A' && c <= 'Z' {c += 32}
		if d >= 'A' && d <= 'Z' {d += 32}
		if c != d {
			return false
		}
	}
	return true
}

/*
put_dns_answer writes the answer a server gives to the query in `q`: the
header saying so, the question repeated, and one `A` record for it naming
`ip`, with the owner written as a pointer to the question. Answers the
length, or zero for a query that will not parse.
*/
put_dns_answer :: proc "contextless" (b: []u8, q: []u8, ip: IP) -> int #no_bounds_check {
	if len(q) < DNS_HDR {
		return 0
	}
	qend := skip_dns_name(q, DNS_HDR)
	if qend == 0 || qend + 4 > len(q) || qend + 4 + 16 > len(b) {
		return 0
	}
	copy(b[:qend + 4], q[:qend + 4])
	put_be16(b, 2, 0x8180) // A response, recursion available
	put_be16(b, 4, 1)
	put_be16(b, 6, 1)
	put_be16(b, 8, 0)
	put_be16(b, 10, 0)
	at := qend + 4
	b[at] = 0xC0
	b[at + 1] = u8(DNS_HDR) // The owner: the question's name
	put_be16(b, at + 2, DNS_TYPE_A)
	put_be16(b, at + 4, DNS_CLASS_IN)
	put_be32(b, at + 6, 300) // Time to live
	put_be16(b, at + 10, 4)
	for i in 0 ..< 4 {b[at + 12 + i] = ip[i]}
	return at + 16
}

// dns_question answers the name a query asks about, as dotted text in
// `into`, and its length; zero for a query that will not parse.
dns_question :: proc "contextless" (q: []u8, into: []u8) -> int #no_bounds_check {
	if len(q) < DNS_HDR || get_be16(q, 4) < 1 {
		return 0
	}
	n, _ := read_dns_name(q, DNS_HDR, into)
	return n
}
