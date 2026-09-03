/*
test -- evaluate a condition, and exit true (empty) or false.

    -e f  exists      -f f  is a plain file    -d f  is a directory
    -s f  has bytes   -z s  is empty           -n s  is not empty
    s1 = s2   s1 != s2   n1 -eq -ne -lt -le -gt -ge n2
    ! e   e1 -a e2   e1 -o e2   ( e )
*/
package test

import "vsys:abi"
import "vsys:libuser"

args: []string
at: int

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args = libuser.args(block)[1:]
	if len(args) == 0 {
		libuser.exits("false")
	}
	result := expr_or()
	if at != len(args) {
		libuser.eprint("test: syntax error\n")
		libuser.exits("usage")
	}
	libuser.exits(result ? "" : "false")
}

peek :: proc() -> string {
	return at < len(args) ? args[at] : ""
}

expr_or :: proc() -> bool {
	v := expr_and()
	for at < len(args) && args[at] == "-o" {
		at += 1
		w := expr_and()
		v = v || w
	}
	return v
}

expr_and :: proc() -> bool {
	v := expr_not()
	for at < len(args) && args[at] == "-a" {
		at += 1
		w := expr_not()
		v = v && w
	}
	return v
}

expr_not :: proc() -> bool {
	if peek() == "!" {
		at += 1
		return !expr_not()
	}
	return primary()
}

primary :: proc() -> bool {
	if at >= len(args) {
		return false
	}
	a := args[at]
	if a == "(" {
		at += 1
		v := expr_or()
		if peek() == ")" {
			at += 1
		}
		return v
	}
	// A unary test.
	if len(a) == 2 && a[0] == '-' && at + 1 < len(args) && !is_binary_op(args[at + 1]) {
		operand := args[at + 1]
		at += 2
		st: abi.Stat
		switch a[1] {
		case 'e':
			return libuser.stat(operand, &st) == 0
		case 'f':
			return libuser.stat(operand, &st) == 0 && st.mode & abi.DMDIR == 0
		case 'd':
			return libuser.stat(operand, &st) == 0 && st.mode & abi.DMDIR != 0
		case 's':
			return libuser.stat(operand, &st) == 0 && st.length > 0
		case 'z':
			return len(operand) == 0
		case 'n':
			return len(operand) > 0
		}
		at -= 2
	}
	// A binary test.
	if at + 2 < len(args) && is_binary_op(args[at + 1]) {
		lhs, op, rhs := args[at], args[at + 1], args[at + 2]
		at += 3
		switch op {
		case "=":
			return lhs == rhs
		case "!=":
			return lhs != rhs
		}
		l, lok := libuser.atoi(lhs)
		r, rok := libuser.atoi(rhs)
		if !lok || !rok {
			libuser.eprint("test: ", lhs, " ", op, " ", rhs, ": not numbers\n")
			libuser.exits("usage")
		}
		switch op {
		case "-eq":
			return l == r
		case "-ne":
			return l != r
		case "-lt":
			return l < r
		case "-le":
			return l <= r
		case "-gt":
			return l > r
		case "-ge":
			return l >= r
		}
	}
	// A string alone is true when it is not empty.
	at += 1
	return len(a) > 0
}

is_binary_op :: proc(s: string) -> bool {
	switch s {
	case "=", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
		return true
	}
	return false
}
