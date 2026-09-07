/*
Values and expressions: what `vars` lists and `eval` answers.

A value is a type row and where its bytes are. That is an address in the
target, or bits the engine holds for a register or a constant. `eval`
reads `name`, `name.member`, `name[i]`, `*p`, `$reg`, numbers, and
`+ - * /` between them, left to right with the usual precedence. A value
prints in the language of the unit that made it. A number, a `"string"`,
a `{member = value, ...}`, an enum's name, a pointer as hex, and a slice
as its length and first elements.

**A target's memory is data.** The engine reads a string by its length,
and a slice by its length, and a read past what a type bounds does not
happen. A
variable the compiler kept nowhere prints as optimised away.
*/
package dbgfs

import "vsys:libdebug"
import "vsys:libodin"
import "vsys:libuser"

Value :: struct {
	type:     int, // A type row, or -1 for a bare number
	addr:     u64,
	in_mem:   bool, // The bytes are at `addr`; otherwise in `bits`
	bits:     u64,
	gone:     bool, // No location: optimised away
}

// -- Reading typed bytes -----------------------------------------------------------------

type_size :: proc "contextless" (t: ^Target, type: int) -> int {
	rt, _, ok := libdebug.type_resolved(&t.dbg, type)
	if !ok {
		return 8
	}
	if rt.size == 0 {
		#partial switch rt.kind {
		case .Pointer, .Proc:
			return 8
		case .String, .Slice:
			return 16
		}
		return 8
	}
	return int(rt.size)
}

// value_bits reads a value's bytes as one word, up to eight.
value_bits :: proc "contextless" (t: ^Target, v: Value) -> (bits: u64, ok: bool) {
	if v.gone {
		return 0, false
	}
	if !v.in_mem {
		return v.bits, true
	}
	size := min(type_size(t, v.type), 8)
	buf: [8]u8
	if read_mem(t, v.addr, buf[:size]) != size {
		return 0, false
	}
	return libdebug.u64_of(buf[:size]), true
}

// value_word reads eight bytes at an offset into a value in memory.
value_word :: proc "contextless" (t: ^Target, v: Value, off: u64) -> (w: u64, ok: bool) {
	if !v.in_mem {
		return 0, false
	}
	buf: [8]u8
	if read_mem(t, v.addr + off, buf[:]) != 8 {
		return 0, false
	}
	return libdebug.u64_of(buf[:]), true
}

// var_value turns a variable row into a value, at the target's counter,
// with the frame base the stack pointer.
var_value :: proc "contextless" (t: ^Target, row: libdebug.Var) -> Value {
	v := Value{type = int(row.type)}
	if row.type == libdebug.NO_TYPE {
		v.type = -1
	}
	switch row.kind {
	case .Addr:
		v.in_mem = true
		v.addr = u64(row.offset)
	case .Fbreg:
		v.in_mem = true
		v.addr = u64(i64(libdebug.frame_sp(t.regs[:])) + row.offset)
	case .Breg:
		base, ok := libdebug.frame_reg(t.regs[:], row.reg)
		if !ok {
			v.gone = true
			return v
		}
		v.in_mem = true
		v.addr = u64(i64(base) + row.offset)
	case .Reg:
		bits, ok := libdebug.frame_reg(t.regs[:], row.reg)
		if !ok {
			v.gone = true
			return v
		}
		v.bits = bits
	case .Const:
		v.bits = u64(row.offset)
	case .Gone, .Other:
		v.gone = true
	}
	return v
}

// -- Printing ------------------------------------------------------------------------------

PRINT_DEPTH :: 2
SLICE_SHOW :: 4

put_value :: proc "contextless" (t: ^Target, sink: ^libodin.Sink, v: Value, depth: int) {
	if v.gone {
		libodin.put_str(sink, "<optimised away>")
		return
	}
	if v.type < 0 {
		libodin.put_int(sink, i64(v.bits))
		return
	}
	rt, rti, ok := libdebug.type_resolved(&t.dbg, v.type)
	if !ok {
		libodin.put_str(sink, "?")
		return
	}
	#partial switch rt.kind {
	case .Base:
		bits, bok := value_bits(t, v)
		if !bok {
			libodin.put_str(sink, "<unreadable>")
			return
		}
		switch rt.enc {
		case 2: // boolean
			libodin.put_str(sink, bits & 0xff != 0 ? "true" : "false")
		case 5, 6: // signed
			libodin.put_int(sink, sign_extend(bits, int(rt.size)))
		case 4: // float
			libodin.put_str(sink, "float ")
			libodin.put_hex(sink, bits, 0)
		case 8, 0x10: // unsigned, UTF
			if rt.size == 1 && rt.enc == 8 {
				libodin.put_uint(sink, bits & 0xff)
			} else {
				libodin.put_uint(sink, bits)
			}
		case:
			libodin.put_hex(sink, bits, 0)
		}
	case .Pointer, .Proc:
		bits, bok := value_bits(t, v)
		if !bok {
			libodin.put_str(sink, "<unreadable>")
			return
		}
		libodin.put_hex(sink, bits, 0)
	case .Enum:
		bits, bok := value_bits(t, v)
		if !bok {
			libodin.put_str(sink, "<unreadable>")
			return
		}
		value := sign_extend(bits, int(max(rt.size, 1)))
		for i in int(rt.first) ..< int(rt.first + rt.count) {
			name, _, ev, mok := libdebug.member_row(&t.dbg, i)
			if mok && i64(ev) == value {
				libodin.put_str(sink, name)
				return
			}
		}
		libodin.put_int(sink, value)
	case .String:
		data, dok := value_word(t, v, 0)
		length, lok := value_word(t, v, 8)
		if !dok || !lok || !v.in_mem {
			libodin.put_str(sink, "<unreadable>")
			return
		}
		put_target_string(t, sink, data, length)
	case .Slice:
		data, dok := value_word(t, v, 0)
		length, lok := value_word(t, v, 8)
		if !dok || !lok || !v.in_mem {
			libodin.put_str(sink, "<unreadable>")
			return
		}
		elem := int(rt.target)
		// The element type is the `data` member's pointee.
		if rt.count > 0 {
			_, mtype, _, mok := libdebug.member_row(&t.dbg, int(rt.first))
			if mok {
				if pt, _, pok := libdebug.type_resolved(&t.dbg, int(mtype)); pok && pt.kind == .Pointer {
					elem = int(pt.target)
				}
			}
		}
		libodin.put_str(sink, "[")
		libodin.put_uint(sink, length)
		libodin.put_str(sink, "]{")
		if depth < PRINT_DEPTH && elem >= 0 && u32(elem) != libdebug.NO_TYPE {
			size := u64(type_size(t, elem))
			for i in 0 ..< int(min(length, SLICE_SHOW)) {
				if i > 0 {
					libodin.put_str(sink, ", ")
				}
				put_value(t, sink, Value{type = elem, in_mem = true, addr = data + u64(i) * size}, depth + 1)
			}
			if length > SLICE_SHOW {
				libodin.put_str(sink, ", ...")
			}
		}
		libodin.put_str(sink, "}")
	case .Array:
		libodin.put_str(sink, "[")
		libodin.put_uint(sink, u64(rt.count))
		libodin.put_str(sink, "]{")
		if depth < PRINT_DEPTH && v.in_mem && rt.target != libdebug.NO_TYPE {
			size := u64(type_size(t, int(rt.target)))
			for i in 0 ..< int(min(u64(rt.count), SLICE_SHOW)) {
				if i > 0 {
					libodin.put_str(sink, ", ")
				}
				put_value(t, sink, Value{type = int(rt.target), in_mem = true, addr = v.addr + u64(i) * size}, depth + 1)
			}
			if rt.count > SLICE_SHOW {
				libodin.put_str(sink, ", ...")
			}
		}
		libodin.put_str(sink, "}")
	case .Struct, .Union, .Map:
		if !v.in_mem {
			libodin.put_str(sink, "{...}")
			return
		}
		libodin.put_str(sink, "{")
		if depth < PRINT_DEPTH {
			for i in int(rt.first) ..< int(rt.first + rt.count) {
				name, mtype, off, mok := libdebug.member_row(&t.dbg, i)
				if !mok {
					break
				}
				if i > int(rt.first) {
					libodin.put_str(sink, ", ")
				}
				libodin.put_str(sink, name)
				libodin.put_str(sink, " = ")
				if mtype == libdebug.NO_TYPE {
					libodin.put_str(sink, "?")
					continue
				}
				put_value(t, sink, Value{type = int(mtype), in_mem = true, addr = v.addr + off}, depth + 1)
			}
		} else {
			libodin.put_str(sink, "...")
		}
		libodin.put_str(sink, "}")
	case:
		bits, bok := value_bits(t, v)
		if bok {
			libodin.put_hex(sink, bits, 0)
		} else {
			libodin.put_str(sink, "?")
		}
	}
	_ = rti
}

// put_target_string prints a string out of the target by its length, up to
// a bound, quoted, with what is not printable escaped.
put_target_string :: proc "contextless" (t: ^Target, sink: ^libodin.Sink, data: u64, length: u64) {
	buf: [128]u8
	n := int(min(length, u64(len(buf))))
	got := n > 0 ? read_mem(t, data, buf[:n]) : 0
	libodin.put_str(sink, "\"")
	for i in 0 ..< max(got, 0) {
		c := buf[i]
		if c >= 0x20 && c < 0x7f && c != '"' {
			libodin.put_byte(sink, c)
		} else {
			libodin.put_str(sink, "\\x")
			libodin.put_hex(sink, u64(c), 2)
		}
	}
	if u64(got) < length {
		libodin.put_str(sink, "...")
	}
	libodin.put_str(sink, "\"")
}

sign_extend :: proc "contextless" (bits: u64, size: int) -> i64 {
	switch size {
	case 1: return i64(i8(bits))
	case 2: return i64(i16(bits))
	case 4: return i64(i32(bits))
	}
	return i64(bits)
}

// -- The variables at the counter ------------------------------------------------------------

// vars_text lists every variable visible at the counter, innermost scope
// first, each once, up to the buffer.
vars_text :: proc "contextless" (t: ^Target, out: []u8) -> int {
	sink := libodin.sink_from(out)
	if !t.stopped {
		libodin.put_str(&sink, "not stopped\n")
		return len(libodin.str(&sink))
	}
	if !t.has_dbg {
		libodin.put_str(&sink, "no debug file for this program\n")
		return len(libodin.str(&sink))
	}
	pc := libdebug.frame_pc(t.regs[:])
	scope, ok := libdebug.scope_at(&t.dbg, pc)
	if !ok {
		return len(libodin.str(&sink))
	}
	seen: [64]string
	nseen := 0
	for _ in 0 ..< 32 {
		s, sok := libdebug.scope_row(&t.dbg, scope)
		if !sok {
			break
		}
		for i in int(s.first) ..< int(s.first + s.nvars) {
			row, _ := libdebug.var_row(&t.dbg, i)
			if len(row.name) == 0 || (!libdebug.var_holds(row, pc) && row.kind != .Gone) {
				continue
			}
			dup := false
			for j in 0 ..< nseen {
				if seen[j] == row.name {
					dup = true
					break
				}
			}
			if dup || nseen >= len(seen) {
				continue
			}
			seen[nseen] = row.name
			nseen += 1
			if len(out) - len(libodin.str(&sink)) < 160 {
				libodin.put_str(&sink, "...\n")
				return len(libodin.str(&sink))
			}
			libodin.put_str(&sink, row.name)
			libodin.put_str(&sink, " = ")
			put_value(t, &sink, var_value(t, row), 0)
			libodin.put_str(&sink, "\n")
		}
		if s.parent == libdebug.NO_SCOPE {
			break
		}
		scope = int(s.parent)
	}
	return len(libodin.str(&sink))
}

// -- Expressions ---------------------------------------------------------------------------------

Parser :: struct {
	t:    ^Target,
	text: string,
	at:   int,
	err:  string,
}

skip_space :: proc "contextless" (p: ^Parser) {
	for p.at < len(p.text) && p.text[p.at] == ' ' {
		p.at += 1
	}
}

is_ident :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == ':'
}

// parse_expr is `term (('+' | '-') term)*`.
parse_expr :: proc "contextless" (p: ^Parser) -> Value {
	v := parse_term(p)
	for p.err == "" {
		skip_space(p)
		if p.at >= len(p.text) || (p.text[p.at] != '+' && p.text[p.at] != '-') {
			break
		}
		op := p.text[p.at]
		p.at += 1
		w := parse_term(p)
		a, aok := value_bits(p.t, v)
		b, bok := value_bits(p.t, w)
		if !aok || !bok {
			p.err = "no value to add"
			break
		}
		v = Value{type = -1, bits = op == '+' ? a + b : a - b}
	}
	return v
}

parse_term :: proc "contextless" (p: ^Parser) -> Value {
	v := parse_unary(p)
	for p.err == "" {
		skip_space(p)
		if p.at >= len(p.text) || (p.text[p.at] != '*' && p.text[p.at] != '/') {
			break
		}
		op := p.text[p.at]
		p.at += 1
		w := parse_unary(p)
		a, aok := value_bits(p.t, v)
		b, bok := value_bits(p.t, w)
		if !aok || !bok {
			p.err = "no value to multiply"
			break
		}
		if op == '/' && b == 0 {
			p.err = "divide by zero"
			break
		}
		v = Value{type = -1, bits = op == '*' ? a * b : a / b}
	}
	return v
}

// parse_unary is `-x`, `*p`, or a postfix expression.
parse_unary :: proc "contextless" (p: ^Parser) -> Value {
	skip_space(p)
	if p.at < len(p.text) && p.text[p.at] == '-' {
		p.at += 1
		v := parse_unary(p)
		bits, ok := value_bits(p.t, v)
		if !ok {
			p.err = "no value to negate"
			return {}
		}
		return Value{type = -1, bits = u64(-i64(bits))}
	}
	if p.at < len(p.text) && p.text[p.at] == '*' {
		p.at += 1
		v := parse_unary(p)
		return deref(p, v)
	}
	return parse_postfix(p)
}

deref :: proc "contextless" (p: ^Parser, v: Value) -> Value {
	rt, _, ok := libdebug.type_resolved(&p.t.dbg, v.type)
	if v.type < 0 || !ok || rt.kind != .Pointer {
		p.err = "not a pointer"
		return {}
	}
	addr, aok := value_bits(p.t, v)
	if !aok {
		p.err = "unreadable pointer"
		return {}
	}
	return Value{type = int(rt.target), in_mem = true, addr = addr}
}

// parse_postfix is a primary followed by `.member` and `[index]`.
parse_postfix :: proc "contextless" (p: ^Parser) -> Value {
	v := parse_primary(p)
	for p.err == "" && p.at < len(p.text) {
		switch p.text[p.at] {
		case '.':
			p.at += 1
			start := p.at
			for p.at < len(p.text) && is_ident(p.text[p.at]) {
				p.at += 1
			}
			v = member(p, v, p.text[start:p.at])
		case '[':
			p.at += 1
			idx := parse_expr(p)
			skip_space(p)
			if p.at >= len(p.text) || p.text[p.at] != ']' {
				p.err = "missing ]"
				return {}
			}
			p.at += 1
			i, iok := value_bits(p.t, idx)
			if !iok {
				p.err = "no index"
				return {}
			}
			v = index(p, v, i)
		case:
			return v
		}
	}
	return v
}

// member steps into a struct's field, through a pointer if the value is
// one.
member :: proc "contextless" (p: ^Parser, v: Value, name: string) -> Value {
	base := v
	rt, _, ok := libdebug.type_resolved(&p.t.dbg, v.type)
	if v.type < 0 || !ok {
		p.err = "no members"
		return {}
	}
	if rt.kind == .Pointer {
		base = deref(p, v)
		if p.err != "" {
			return {}
		}
		rt, _, ok = libdebug.type_resolved(&p.t.dbg, base.type)
		if !ok {
			p.err = "no members"
			return {}
		}
	}
	if !base.in_mem || (rt.kind != .Struct && rt.kind != .Union && rt.kind != .String && rt.kind != .Slice && rt.kind != .Map) {
		p.err = "no members"
		return {}
	}
	for i in int(rt.first) ..< int(rt.first + rt.count) {
		mname, mtype, off, mok := libdebug.member_row(&p.t.dbg, i)
		if mok && mname == name {
			return Value{type = mtype == libdebug.NO_TYPE ? -1 : int(mtype), in_mem = true, addr = base.addr + off}
		}
	}
	p.err = "no such member"
	return {}
}

// index steps into an array's or a slice's element.
index :: proc "contextless" (p: ^Parser, v: Value, i: u64) -> Value {
	rt, _, ok := libdebug.type_resolved(&p.t.dbg, v.type)
	if v.type < 0 || !ok || !v.in_mem {
		p.err = "not indexable"
		return {}
	}
	#partial switch rt.kind {
	case .Array:
		if i >= u64(rt.count) || rt.target == libdebug.NO_TYPE {
			p.err = "index out of range"
			return {}
		}
		size := u64(type_size(p.t, int(rt.target)))
		return Value{type = int(rt.target), in_mem = true, addr = v.addr + i * size}
	case .Slice, .String:
		data, dok := value_word(p.t, v, 0)
		length, lok := value_word(p.t, v, 8)
		if !dok || !lok || i >= length {
			p.err = "index out of range"
			return {}
		}
		elem := -1
		if rt.kind == .String {
			bt, bok := libdebug.type_named(&p.t.dbg, "u8")
			elem = bok ? bt : -1
			return Value{type = elem, in_mem = true, addr = data + i}
		}
		_, mtype, _, mok := libdebug.member_row(&p.t.dbg, int(rt.first))
		if mok {
			if pt, _, pok := libdebug.type_resolved(&p.t.dbg, int(mtype)); pok && pt.kind == .Pointer {
				elem = int(pt.target)
			}
		}
		if elem < 0 {
			p.err = "no element type"
			return {}
		}
		return Value{type = elem, in_mem = true, addr = data + i * u64(type_size(p.t, elem))}
	}
	p.err = "not indexable"
	return {}
}

// parse_primary is a number, a `$register`, a name, or a parenthesised
// expression.
parse_primary :: proc "contextless" (p: ^Parser) -> Value {
	skip_space(p)
	if p.at >= len(p.text) {
		p.err = "nothing to evaluate"
		return {}
	}
	c := p.text[p.at]
	switch {
	case c == '(':
		p.at += 1
		v := parse_expr(p)
		skip_space(p)
		if p.at >= len(p.text) || p.text[p.at] != ')' {
			p.err = "missing )"
			return {}
		}
		p.at += 1
		return v
	case c == '$':
		p.at += 1
		start := p.at
		for p.at < len(p.text) && is_ident(p.text[p.at]) {
			p.at += 1
		}
		bits, ok := libdebug.frame_named(p.t.regs[:], p.text[start:p.at])
		if !ok {
			p.err = "no such register"
			return {}
		}
		return Value{type = -1, bits = bits}
	case c >= '0' && c <= '9':
		start := p.at
		if p.at + 1 < len(p.text) && c == '0' && p.text[p.at + 1] == 'x' {
			p.at += 2
			hs := p.at
			for p.at < len(p.text) && is_ident(p.text[p.at]) {
				p.at += 1
			}
			v, ok := parse_hex(p.text[hs:p.at])
			if !ok {
				p.err = "bad number"
				return {}
			}
			return Value{type = -1, bits = v}
		}
		for p.at < len(p.text) && p.text[p.at] >= '0' && p.text[p.at] <= '9' {
			p.at += 1
		}
		v, ok := libuser.atoi(p.text[start:p.at])
		if !ok {
			p.err = "bad number"
			return {}
		}
		return Value{type = -1, bits = u64(v)}
	case is_ident(c):
		start := p.at
		for p.at < len(p.text) && is_ident(p.text[p.at]) {
			p.at += 1
		}
		name := p.text[start:p.at]
		if !p.t.has_dbg {
			p.err = "no debug file for this program"
			return {}
		}
		row, ok := libdebug.var_at(&p.t.dbg, libdebug.frame_pc(p.t.regs[:]), name)
		if !ok {
			p.err = "no such variable"
			return {}
		}
		return var_value(p.t, row)
	}
	p.err = "bad expression"
	return {}
}

// eval_text evaluates one expression and writes its value, or the reason
// it has none.
eval_text :: proc "contextless" (t: ^Target, text: string, out: []u8) -> int {
	sink := libodin.sink_from(out)
	if !t.stopped {
		libodin.put_str(&sink, "not stopped\n")
		return len(libodin.str(&sink))
	}
	p := Parser{t = t, text = text}
	v := parse_expr(&p)
	skip_space(&p)
	if p.err == "" && p.at < len(p.text) {
		p.err = "trailing text"
	}
	if p.err != "" {
		libodin.put_str(&sink, "error: ")
		libodin.put_str(&sink, p.err)
		libodin.put_str(&sink, "\n")
		return len(libodin.str(&sink))
	}
	put_value(t, &sink, v, 0)
	libodin.put_str(&sink, "\n")
	return len(libodin.str(&sink))
}
