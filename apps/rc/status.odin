/*
`$status`, and the wait that sets it.

A status is a string. Empty is success, and anything else is a reason,
which is what `if`, `&&`, `||` and `!` test. A pipeline's status is the
stages' joined by `|`. A child's comes back through `await` as `pid word`,
and the word is the status. The word is whatever the child said to
`exits`, or `fault`, or a nonzero number a program that used the numeric
exit answered with.
*/
package rc

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

STATUS_MAX :: 128

status :: proc(sh: ^Shell) -> string {
	return string(sh.status_buf[:sh.status_len])
}

set_status :: proc(sh: ^Shell, s: string) {
	n := min(len(s), STATUS_MAX)
	copy(sh.status_buf[:n], s[:n])
	sh.status_len = n
}

ok :: proc(sh: ^Shell) -> bool {
	return sh.status_len == 0
}

// wait_for collects one child and answers its status. `await` gives up
// every half second so a parked caller can hear a note; a shell that is
// waiting simply asks again.
wait_for :: proc(sh: ^Shell, pid: i64) -> string {
	word, _ := await_once(sh, pid)
	return word
}

// await_once collects one child -- `pid`, or any with zero -- asking again
// each time the kernel gives up, and answers its word. False when there is
// no such child.
await_once :: proc(sh: ^Shell, pid: i64) -> (word: string, ok: bool) {
	buf: [AWAIT_MAX]u8
	for {
		n := libuser.await(u64(pid), buf[:])
		if n == -i64(vectra9.EAGAIN) {
			continue
		}
		if n < 0 {
			return "", false
		}
		return word_after_pid(sh, buf[:n]), true
	}
}

// The most `await` answers: twenty digits of pid, a space, and the word.
AWAIT_MAX :: 21 + abi.EXITS_MAX

// word_after_pid is the status out of `pid word`, copied to the arena.
word_after_pid :: proc(sh: ^Shell, answer: []u8) -> string {
	i := 0
	for i < len(answer) && answer[i] != ' ' {
		i += 1
	}
	if i < len(answer) {
		i += 1
	}
	out := make([]u8, len(answer) - i, sh.temp)
	copy(out, answer[i:])
	return string(out)
}

