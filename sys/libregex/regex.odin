/*
Regular expressions, Plan 9's dialect, for `grep` and `sed`.

    c        a character; `\c` is c literally
    .        any character but newline
    [abc]    a class; `[^abc]` its complement; `a-z` a range
    ^  $     the start and end of the text
    e*  e+  e?   repetition
    e1e2     concatenation
    e1|e2    alternation
    (e)      grouping

Compiled to a small instruction list and run as a Thompson simulation: a
set of positions in the program advances one character at a time, so a
pattern costs time proportional to its length times the text's, never the
exponential a backtracker can. The match is leftmost, and longest at that
start. The first nine groups are captured, Pike's way: a position carries
the bounds it saw, and the first to reach a place keeps it. The plumber's
rules name a group as `$1`, and `sed` may one day.
*/
package libregex

import "base:runtime"

Op :: enum u8 {
	Char,
	Any,
	Class,
	Split,
	Jmp,
	Bol,
	Eol,
	Save, // `x` is the slot: the start of group n at 2n, its end at 2n+1
	Match,
}

// How many groups are captured: `$1` to `$9`, so nine, two slots each.
MAX_GROUPS :: 9
SLOTS :: 2 * MAX_GROUPS

Inst :: struct {
	op:    Op,
	c:     u8,
	x, y:  int, // Split: both branches; Jmp: x
	class: int, // Class: index into `classes`
}

Regex :: struct {
	prog:    [dynamic]Inst,
	classes: [dynamic][256]bool,
	fold:    bool, // case-insensitive: the text is lowered as it is read
	// The simulation's two thread lists and its visited marks, sized to the
	// program once at compile, because a match per line of input that
	// allocated them would be three heap blocks per line for ever.
	cur:     []int,
	nxt:     []int,
	mark:    []int,
	generation: int,
	groups:  int, // Groups in the pattern, captured up to MAX_GROUPS
	// A thread's captures, beside its position in `cur` and `nxt`.
	cur_caps: []int,
	nxt_caps: []int,
}

// -- Parsing into a program ---------------------------------------------------------

@(private = "file")
Parser :: struct {
	pat: string,
	pos: int,
	re:  ^Regex,
	err: bool,
}

// compile builds a regex from a pattern. `fold` ignores case. False for a
// pattern that does not parse.
compile :: proc(pattern: string, fold: bool, allocator: runtime.Allocator) -> (re: ^Regex, ok: bool) {
	re = new(Regex, allocator)
	re.prog = make([dynamic]Inst, 0, 2 * len(pattern) + 4, allocator)
	re.classes = make([dynamic][256]bool, 0, 4, allocator)
	re.fold = fold
	p := Parser{pat = pattern, re = re}
	// The program: the alternation, then Match. Each level emits code for
	// its operands as it goes, so the structure is `a Split ... Jmp` style
	// rather than a tree.
	parse_alt(&p)
	if p.err || p.pos != len(pattern) {
		destroy(re)
		return nil, false
	}
	append(&re.prog, Inst{op = .Match})
	n := len(re.prog)
	re.cur = make([]int, n, allocator)
	re.nxt = make([]int, n, allocator)
	re.mark = make([]int, n, allocator)
	re.cur_caps = make([]int, n * SLOTS, allocator)
	re.nxt_caps = make([]int, n * SLOTS, allocator)
	return re, true
}

destroy :: proc(re: ^Regex) {
	if re == nil {
		return
	}
	delete(re.prog)
	delete(re.classes)
	delete(re.cur)
	delete(re.nxt)
	delete(re.mark)
	delete(re.cur_caps)
	delete(re.nxt_caps)
	free(re)
}

@(private = "file")
emit :: proc(p: ^Parser, i: Inst) -> int {
	append(&p.re.prog, i)
	return len(p.re.prog) - 1
}

// parse_alt is `concat ('|' concat)*`. Code for `a|b`:
//     Split L1 L2; L1: a; Jmp L3; L2: b; L3:
@(private = "file")
parse_alt :: proc(p: ^Parser) {
	start := len(p.re.prog)
	parse_concat(p)
	for !p.err && p.pos < len(p.pat) && p.pat[p.pos] == '|' {
		p.pos += 1
		// A Split before what was emitted, then a Jmp after it.
		split := insert_split(p, start)
		jmp := emit(p, Inst{op = .Jmp})
		p.re.prog[split].y = len(p.re.prog)
		parse_concat(p)
		p.re.prog[jmp].x = len(p.re.prog)
	}
}

// insert_split puts a Split in front of the code emitted since `start`,
// its first branch the code and its second left for the caller to aim, and
// shifts the code's own targets by one. The shape `|`, `*` and `?` share.
@(private = "file")
insert_split :: proc(p: ^Parser, start: int) -> int {
	body := p.re.prog[start:]
	moved := make([]Inst, len(body), context.temp_allocator)
	copy(moved, body)
	resize(&p.re.prog, start)
	split := emit(p, Inst{op = .Split})
	for ins in moved {
		append(&p.re.prog, shift(ins, 1, start))
	}
	p.re.prog[split].x = split + 1
	return split
}

// shift moves an instruction's targets by `by` if they lie at or after `from`.
@(private = "file")
shift :: proc(ins: Inst, by: int, from: int) -> Inst {
	out := ins
	if ins.op == .Split || ins.op == .Jmp {
		if ins.x >= from {
			out.x += by
		}
		if ins.op == .Split && ins.y >= from {
			out.y += by
		}
	}
	return out
}

@(private = "file")
parse_concat :: proc(p: ^Parser) {
	for !p.err && p.pos < len(p.pat) {
		c := p.pat[p.pos]
		if c == '|' || c == ')' {
			return
		}
		parse_repeat(p)
	}
}

// parse_repeat is an atom and its `*`, `+` or `?`. Code:
//     e*   L1: Split L2 L3; L2: e; Jmp L1; L3:
//     e+   L1: e; Split L1 L2; L2:
//     e?   Split L1 L2; L1: e; L2:
@(private = "file")
parse_repeat :: proc(p: ^Parser) {
	start := len(p.re.prog)
	parse_atom(p)
	if p.err {
		return
	}
	for p.pos < len(p.pat) {
		c := p.pat[p.pos]
		switch c {
		case '*':
			p.pos += 1
			split := insert_split(p, start)
			emit(p, Inst{op = .Jmp, x = split})
			p.re.prog[split].y = len(p.re.prog)
		case '+':
			p.pos += 1
			emit(p, Inst{op = .Split, x = start, y = len(p.re.prog) + 1})
		case '?':
			p.pos += 1
			split := insert_split(p, start)
			p.re.prog[split].y = len(p.re.prog)
		case:
			return
		}
	}
}

@(private = "file")
parse_atom :: proc(p: ^Parser) {
	c := p.pat[p.pos]
	p.pos += 1
	switch c {
	case '.':
		emit(p, Inst{op = .Any})
	case '^':
		emit(p, Inst{op = .Bol})
	case '$':
		emit(p, Inst{op = .Eol})
	case '(':
		group := p.re.groups
		p.re.groups += 1
		if group < MAX_GROUPS {
			emit(p, Inst{op = .Save, x = 2 * group})
		}
		parse_alt(p)
		if p.pos >= len(p.pat) || p.pat[p.pos] != ')' {
			p.err = true
			return
		}
		p.pos += 1
		if group < MAX_GROUPS {
			emit(p, Inst{op = .Save, x = 2 * group + 1})
		}
	case '[':
		parse_class(p)
	case '\\':
		if p.pos >= len(p.pat) {
			p.err = true
			return
		}
		emit(p, Inst{op = .Char, c = fold_char(p.re, p.pat[p.pos])})
		p.pos += 1
	case '*', '+', '?':
		p.err = true
	case:
		emit(p, Inst{op = .Char, c = fold_char(p.re, c)})
	}
}

@(private = "file")
parse_class :: proc(p: ^Parser) {
	set: [256]bool
	negate := false
	if p.pos < len(p.pat) && p.pat[p.pos] == '^' {
		negate = true
		p.pos += 1
	}
	first := true
	for {
		if p.pos >= len(p.pat) {
			p.err = true
			return
		}
		c := p.pat[p.pos]
		if c == ']' && !first {
			p.pos += 1
			break
		}
		first = false
		p.pos += 1
		if c == '\\' && p.pos < len(p.pat) {
			c = p.pat[p.pos]
			p.pos += 1
		}
		hi := c
		if p.pos + 1 < len(p.pat) && p.pat[p.pos] == '-' && p.pat[p.pos + 1] != ']' {
			hi = p.pat[p.pos + 1]
			p.pos += 2
		}
		for k := int(c); k <= int(hi); k += 1 {
			set[fold_char(p.re, u8(k))] = true
			if p.re.fold {
				set[u8(k)] = true
			}
		}
	}
	if negate {
		for i in 0 ..< 256 {
			set[i] = !set[i]
		}
		set['\n'] = false
	}
	append(&p.re.classes, set)
	emit(p, Inst{op = .Class, class = len(p.re.classes) - 1})
}

@(private = "file")
fold_char :: proc(re: ^Regex, c: u8) -> u8 {
	if re.fold && c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// -- Matching ---------------------------------------------------------------------------

/*
match finds the leftmost match in `text`, longest at that start, and
answers its bounds. The simulation keeps two lists of program positions,
this character's and the next's, and a match is recorded whenever the
Match instruction is reached; the last one recorded at a given start is
the longest there.
*/
match :: proc(re: ^Regex, text: string) -> (start, end: int, ok: bool) {
	return match_from(re, text, 0)
}

// match_from is `match` starting the search at `from`, for `s///g`.
match_from :: proc(re: ^Regex, text: string, from: int) -> (start, end: int, ok: bool) {
	return match_caps(re, text, from, nil)
}

/*
match_caps is `match_from` that also answers the groups. `caps[2n]` and
`caps[2n+1]` are the bounds of group n+1, or -1 when it took no part in the
match. `caps` may be nil, and is read only up to SLOTS.
*/
match_caps :: proc(re: ^Regex, text: string, from: int, caps: []int) -> (start, end: int, ok: bool) {
	cur, nxt, mark := re.cur, re.nxt, re.mark
	cur_caps, nxt_caps := re.cur_caps, re.nxt_caps
	generation := re.generation
	defer re.generation = generation
	fresh: [SLOTS]int
	for i in 0 ..< SLOTS {
		fresh[i] = -1
	}
	best_caps: [SLOTS]int
	for s := from; s <= len(text); s += 1 {
		ncur := 0
		generation += 1
		ncur = add_thread(re, cur, cur_caps, ncur, mark, generation, 0, text, s, fresh[:])
		best := -1
		for i := s; ; i += 1 {
			// Anything at Match now is a match ending at i. The first in the
			// list is the preferred one, and its groups are the answer.
			for k in 0 ..< ncur {
				if re.prog[cur[k]].op == .Match {
					best = i
					copy(best_caps[:], cur_caps[k * SLOTS:][:SLOTS])
					break
				}
			}
			if i >= len(text) || ncur == 0 {
				break
			}
			c := text[i]
			if re.fold && c >= 'A' && c <= 'Z' {
				c += 'a' - 'A'
			}
			generation += 1
			nnxt := 0
			for k in 0 ..< ncur {
				ins := re.prog[cur[k]]
				step := false
				switch ins.op {
				case .Char:
					step = ins.c == c
				case .Any:
					step = c != '\n'
				case .Class:
					step = re.classes[ins.class][c]
				case .Split, .Jmp, .Bol, .Eol, .Save, .Match:
				}
				if step {
					nnxt = add_thread(re, nxt, nxt_caps, nnxt, mark, generation, cur[k] + 1, text, i + 1, cur_caps[k * SLOTS:][:SLOTS])
				}
			}
			cur, nxt = nxt, cur
			cur_caps, nxt_caps = nxt_caps, cur_caps
			ncur = nnxt
		}
		if best >= 0 {
			if caps != nil {
				copy(caps, best_caps[:])
			}
			return s, best, true
		}
		// An anchored pattern cannot match later; a plain one may.
		if len(re.prog) > 0 && re.prog[0].op == .Bol && s == 0 {
			return 0, 0, false
		}
	}
	return 0, 0, false
}

// add_thread follows the epsilon edges out of `pc` and adds every
// character-consuming or matching position reached to `list`, once. Each
// carries the captures `caps` it arrived with. A Save on the way marks the
// position in a copy, so the other branch of a Split keeps its own.
@(private = "file")
add_thread :: proc(re: ^Regex, list: []int, list_caps: []int, count: int, mark: []int, generation: int, pc: int, text: string, at: int, caps: []int) -> int {
	count := count
	if pc >= len(re.prog) || mark[pc] == generation {
		return count
	}
	mark[pc] = generation
	ins := re.prog[pc]
	switch ins.op {
	case .Split:
		count = add_thread(re, list, list_caps, count, mark, generation, ins.x, text, at, caps)
		count = add_thread(re, list, list_caps, count, mark, generation, ins.y, text, at, caps)
	case .Jmp:
		count = add_thread(re, list, list_caps, count, mark, generation, ins.x, text, at, caps)
	case .Bol:
		if at == 0 || text[at - 1] == '\n' {
			count = add_thread(re, list, list_caps, count, mark, generation, pc + 1, text, at, caps)
		}
	case .Eol:
		if at == len(text) || text[at] == '\n' {
			count = add_thread(re, list, list_caps, count, mark, generation, pc + 1, text, at, caps)
		}
	case .Save:
		saved: [SLOTS]int
		copy(saved[:], caps)
		saved[ins.x] = at
		count = add_thread(re, list, list_caps, count, mark, generation, pc + 1, text, at, saved[:])
	case .Char, .Any, .Class, .Match:
		list[count] = pc
		copy(list_caps[count * SLOTS:][:SLOTS], caps)
		count += 1
	}
	return count
}
