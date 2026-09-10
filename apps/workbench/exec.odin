/*
exec -- `Execute Command...`, `docs/WORKBENCH.md` section 6.

A window with a list above a string gadget. What is typed is matched
against the names under `/bin`, the tools under `/lib/wb/tools`, the menu
items and the chords' actions, by letters in order or by initials, so `ec`
finds `Execute Command...` and `wrc` finds `window rc -i`. Return runs the
selected line, or what was typed when nothing matched. It is Spotlight's
line for a person who knows a name, and the menus stay for a person who
does not.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

MAX_CANDIDATES :: 256
MAX_SHOWN :: 12

exec_win: ^libmui.Window
exec_field: ^libmui.Object
exec_list: ^libmui.Object
exec_text: [96]u8

// Every line that can be run, read once: a candidate is what is shown, and
// its action is the line `run_action` takes.
candidates: [MAX_CANDIDATES]string
actions: [MAX_CANDIDATES]string
candidate_n: int
candidates_read: bool

shown: [MAX_SHOWN]string
shown_action: [MAX_SHOWN]string
shown_n: int

execute_open :: proc "contextless" () {
	context = wb_ctx
	if exec_win == nil {
		exec_win = new(libmui.Window)
	}
	if exec_win == nil || (exec_win.data_fd > 0 && !exec_win.done) {
		return
	}
	read_candidates()
	exec_list = libmui.list(MAX_SHOWN)
	exec_list.id = 2
	exec_field = libmui.field()
	exec_field.id = 1
	exec_field.edit = exec_text[:]
	exec_field.edit_n = 0
	col := libmui.group(false)
	libmui.add(col, exec_list)
	row := libmui.group(true)
	libmui.add(row, libmui.text("Command:"))
	libmui.add(row, exec_field)
	libmui.add(col, row)
	refilter()

	w := exec_win
	w.kind = .Normal
	w.bind_dev = false
	w.own_exit = false
	w.set_up = true
	w.want_w, w.want_h = 48 * libmui.FONT_W, (MAX_SHOWN + 2) * libmui.FONT_H + 24
	w.handler = exec_press
	if !libmui.window_open(w, "Execute Command", col) {
		return
	}
	w.focus = exec_field
	_ = libthread.threadcreate(window_thread, w)
}

// exec_press: typing refilters, Return runs, Escape closes, a click on the
// list selects.
exec_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	switch id {
	case -1:
		w.done = true
	case 1:
		if w.clicks == 0 {
			refilter()
			libmui.window_paint(w)
			return
		}
		// Return: the selected line, or the typed one.
		line := libmui.field_text(exec_field)
		if exec_list.sel >= 0 && exec_list.sel < shown_n {
			line = shown_action[exec_list.sel]
		}
		w.done = true
		if len(line) > 0 {
			run_action(line)
		}
	case 2:
		if w.clicks == 2 && w.arg >= 0 && w.arg < shown_n {
			w.done = true
			run_action(shown_action[w.arg])
		}
	}
}

// refilter fills the list with the candidates the typed text matches.
refilter :: proc "contextless" () {
	typed := libmui.field_text(exec_field)
	shown_n = 0
	for i in 0 ..< candidate_n {
		if shown_n >= MAX_SHOWN {
			break
		}
		if typed == "" || matches(candidates[i], typed) {
			shown[shown_n] = candidates[i]
			shown_action[shown_n] = actions[i]
			shown_n += 1
		}
	}
	exec_list.rows = shown[:shown_n]
	exec_list.top = 0
	exec_list.sel = shown_n > 0 ? 0 : -1
}

/*
matches says whether `typed` names a candidate: its letters in order
somewhere in the name, or the initials of the name's words, case blind.
*/
matches :: proc "contextless" (name: string, typed: string) -> bool {
	// Letters in order.
	k := 0
	for i in 0 ..< len(name) {
		if k < len(typed) && fold(name[i]) == fold(typed[k]) {
			k += 1
		}
	}
	if k == len(typed) {
		return true
	}
	// Initials.
	k = 0
	start := true
	for i in 0 ..< len(name) {
		c := name[i]
		if c == ' ' || c == '-' || c == '.' {
			start = true
			continue
		}
		if start && k < len(typed) && fold(c) == fold(typed[k]) {
			k += 1
		}
		start = false
	}
	return k == len(typed)
}

fold :: proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// read_candidates gathers every runnable line once: the menus, the tools,
// the chords' actions, and the programs under /bin.
read_candidates :: proc "contextless" () {
	context = wb_ctx
	if candidates_read {
		return
	}
	candidates_read = true
	add_candidate("Execute Command...", "execute")
	add_candidate("Shell", "shell")
	add_candidate("Reload", "reload")
	read_tools()
	for i in 0 ..< tool_n {
		add_candidate(tool_names[i], tool_action(tool_names[i]))
	}
	read_chords()
	if fd := libuser.open("/bin", abi.O_RDONLY); fd >= 0 {
		names := libuser.list_dir(int(fd))
		_ = libuser.close(int(fd))
		libuser.sort_strings(names)
		for name in names {
			add_candidate(name, libuser.join("window ", name))
		}
	}
}

add_candidate :: proc "contextless" (name: string, action: string) {
	if candidate_n < MAX_CANDIDATES {
		candidates[candidate_n] = name
		actions[candidate_n] = action
		candidate_n += 1
	}
}

// tool_action is a tool's command line, read from its file, as `run <line>`.
tool_action :: proc "contextless" (name: string) -> string {
	context = wb_ctx
	fd := libuser.open(libuser.join(TOOLS_DIR, name), abi.O_RDONLY)
	if fd < 0 {
		return "run"
	}
	line: [128]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	end := 0
	for end < int(n) && line[end] != '\n' {
		end += 1
	}
	return libuser.join("run ", string(line[:end]))
}

// read_chords adds the keys file's actions, so a chord's action can be
// typed as well as pressed.
read_chords :: proc "contextless" () {
	context = wb_ctx
	fd := libuser.open("/lib/keys", abi.O_RDONLY)
	if fd < 0 {
		return
	}
	text := make([]u8, 4096)
	n := libuser.read(int(fd), text)
	_ = libuser.close(int(fd))
	rest := string(text[:max(int(n), 0)])
	for len(rest) > 0 {
		line := rest
		if nl := index_byte(rest, '\n'); nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		if hash := index_byte(line, '#'); hash >= 0 {
			line = line[:hash]
		}
		chord, action := first_word(line)
		if chord == "" || action == "" {
			continue
		}
		end := len(action)
		for end > 0 && (action[end - 1] == ' ' || action[end - 1] == '\t') {
			end -= 1
		}
		action = action[:end]
		verb, _ := first_word(action)
		// The server's own actions are not lines this program runs.
		switch verb {
		case "close", "cycle", "zoom", "back", "move", "size", "raise", "send", "overview", "next", "prev":
			continue
		}
		add_candidate(action, action)
	}
}
