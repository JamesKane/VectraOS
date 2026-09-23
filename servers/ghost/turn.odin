/*
The loop, `docs/GHOST.md` section 4: the Messages API's, as it exists.

    request     the transcript, the system prompt and the seven tools,
                written to the model's `request` as the API's JSON
    events      read back from `reply` one a read: text streams to the
                session's `reply` as it comes, a `tool_use` gathers its
                input from the deltas
    tools       each `tool_use` run in the sandbox, every result sent
                back in one message, `is_error` on the ones that failed
    stop        `end_turn` is Idle; `max_tokens`, `refusal` and anything
                else stop with the reason in `status`

The transcript is appended and never rewritten: the models refuse an
edited history, and a log that changes is not a log.

**The requester is for what a namespace cannot say**, and asks through
`confirm`: a write to a file that exists, the first time in a session; a
`run` whose script names `rm`, `kill` or `mv`; and every tool in the
`admin` class. The `ask` tool is the same file with the model's question.
No answer inside a minute is no. A `plumb` whose rule runs a program asks
too in the plan, and waits for the plumber to say which rule a message
takes, which it does not yet.
*/
package ghost

import "core:encoding/json"
import "vsys:abi"
import "vsys:libthread"
import "vsys:libuser"

MAX_ROUNDS :: 32
MAX_TOKENS :: 64000

Turn :: struct {
	si:     int,
	prompt: string,
}

Block_Kind :: enum u8 {
	Text,
	Tool,
}

// One content block of a reply, gathered from its events.
Block :: struct {
	kind:  Block_Kind,
	text:  [dynamic]u8, // A text block's text, or a tool's input as its deltas gave it
	id:    string,
	name:  string,
}

turn_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	t := (^Turn)(arg)
	si := t.si
	s := &sessions[si]
	if s.io == nil {
		s.io = libthread.ioproc(32 * 1024)
	}
	if s.io == nil {
		set_status(s, "Stopped no io proc")
	} else {
		run_turn(s, t.prompt)
	}
	s.running = false
	delete(t.prompt)
	free(t)
	answer_held(si)
	libthread.threadexits("")
}

run_turn :: proc(s: ^Session, prompt: string) {
	msg := make([dynamic]u8, 0, 256)
	defer delete(msg)
	append(&msg, `{"role": "user", "content": [{"type": "text", "text": `)
	json_str(&msg, prompt)
	append(&msg, `}]}`)
	transcript_add(s, string(msg[:]))
	log_line(s, "prompt ", prompt)

	for _ in 0 ..< MAX_ROUNDS {
		if s.budget > 0 && model_spent(s) >= s.budget {
			set_status(s, "Stopped budget")
			log_line(s, "stopped: the budget is spent")
			return
		}
		set_status(s, "Thinking")
		blocks := make([dynamic]Block, 0, 4)
		defer blocks_free(&blocks)
		stop, ok := model_turn(s, &blocks)
		if !ok {
			set_status(s, "Stopped the model did not answer")
			log_line(s, "stopped: the model did not answer")
			return
		}
		assistant_add(s, blocks[:])
		switch stop {
		case "tool_use":
			results := make([dynamic]u8, 0, 512)
			defer delete(results)
			append(&results, `{"role": "user", "content": [`)
			first := true
			for &b in blocks {
				if b.kind != .Tool {
					continue
				}
				text, is_error := run_tool(s, &b)
				if !first {
					append(&results, ", ")
				}
				first = false
				append(&results, `{"type": "tool_result", "tool_use_id": `)
				json_str(&results, b.id)
				append(&results, `, "content": `)
				json_str(&results, text)
				if is_error {
					append(&results, `, "is_error": true`)
				}
				append(&results, "}")
				delete(text)
			}
			append(&results, "]}")
			transcript_add(s, string(results[:]))
		case "end_turn", "stop_sequence":
			set_status(s, "Idle")
			return
		case:
			set_status(s, "Stopped ", stop)
			log_line(s, "stopped: ", stop)
			return
		}
	}
	set_status(s, "Stopped too many rounds")
}

transcript_add :: proc(s: ^Session, message: string) {
	if len(s.transcript) > 0 {
		append(&s.transcript, ", ")
	}
	append(&s.transcript, message)
}

// assistant_add appends the reply's content whole, the blocks as the
// model gave them, so the next request carries them back unedited.
assistant_add :: proc(s: ^Session, blocks: []Block) {
	msg := make([dynamic]u8, 0, 256)
	defer delete(msg)
	append(&msg, `{"role": "assistant", "content": [`)
	for b, i in blocks {
		if i > 0 {
			append(&msg, ", ")
		}
		switch b.kind {
		case .Text:
			append(&msg, `{"type": "text", "text": `)
			json_str(&msg, string(b.text[:]))
			append(&msg, "}")
		case .Tool:
			append(&msg, `{"type": "tool_use", "id": `)
			json_str(&msg, b.id)
			append(&msg, `, "name": `)
			json_str(&msg, b.name)
			append(&msg, `, "input": `)
			append(&msg, valid_object(string(b.text[:])) ? string(b.text[:]) : "{}")
			append(&msg, "}")
		}
	}
	append(&msg, "]}")
	transcript_add(s, string(msg[:]))
}

blocks_free :: proc(blocks: ^[dynamic]Block) {
	for &b in blocks {
		delete(b.text)
		delete(b.id)
		delete(b.name)
	}
	delete(blocks^)
}

// -- The model ----------------------------------------------------------------

model_path :: proc "contextless" (s: ^Session, file: string, buf: []u8) -> string {
	nb: [24]u8
	return libuser.cat_into(buf, g_model_dir, "/", libuser.itoa(nb[:], i64(s.msess)), "/", file)
}

// model_open takes a session on the model's directory, the first time,
// and names the model when `ctl` did. A model's server answers these at
// once, so they are made from the thread.
model_open :: proc(s: ^Session) -> bool {
	if s.msess >= 0 {
		return true
	}
	pb: [PATH_MAX]u8
	fd := libuser.open(libuser.cat_into(pb[:], g_model_dir, "/new"), abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	nb: [24]u8
	n := libuser.read(int(fd), nb[:])
	_ = libuser.close(int(fd))
	if n <= 0 {
		return false
	}
	num, ok := libuser.atoi(trim(string(nb[:n])))
	if !ok {
		return false
	}
	s.msess = int(num)
	if s.mlen > 0 {
		line: [NAME_MAX + 8]u8
		cfd := libuser.open(model_path(s, "ctl", pb[:]), abi.O_WRONLY)
		if cfd >= 0 {
			_ = libuser.write(int(cfd), transmute([]u8)libuser.cat_into(line[:], "model ", model_of(s)))
			_ = libuser.close(int(cfd))
		}
	}
	return true
}

model_hangup :: proc "contextless" (s: ^Session) {
	pb: [PATH_MAX]u8
	fd := libuser.open(model_path(s, "ctl", pb[:]), abi.O_WRONLY)
	if fd >= 0 {
		_ = libuser.write(int(fd), transmute([]u8)string("hangup"))
		_ = libuser.close(int(fd))
	}
	s.msess = -1
}

// model_spent reads the model's `usage` line: tokens in and out so far.
model_spent :: proc(s: ^Session) -> int {
	if s.msess < 0 {
		return 0
	}
	pb: [PATH_MAX]u8
	fd := libuser.open(model_path(s, "usage", pb[:]), abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	buf: [128]u8
	n := libuser.read(int(fd), buf[:])
	_ = libuser.close(int(fd))
	if n <= 0 {
		return 0
	}
	total := 0
	rest := string(buf[:n])
	for len(rest) > 0 {
		w: string
		w, rest = word(rest)
		if w == "in" || w == "out" {
			v: string
			v, rest = word(rest)
			if x, ok := libuser.atoi(trim(v)); ok {
				total += int(x)
			}
		}
	}
	return total
}

/*
model_turn writes one request and reads its reply's events to the end,
gathering the blocks. The text streams to the session's `reply` as each
delta lands. Answers the stop reason, and false when the model would not
take the request or the stream ended with none.
*/
model_turn :: proc(s: ^Session, blocks: ^[dynamic]Block) -> (stop: string, ok: bool) {
	if !model_open(s) {
		return "", false
	}
	req := make([dynamic]u8, 0, 4096)
	defer delete(req)
	append(&req, `{"model": `)
	json_str(&req, s.mlen > 0 ? model_of(s) : "default")
	append(&req, `, "max_tokens": 64000, "stream": true`)
	if s.elen > 0 {
		append(&req, `, "output_config": {"effort": `)
		json_str(&req, string(s.effort[:s.elen]))
		append(&req, "}")
	}
	append(&req, `, "system": `)
	json_str(&req, SYSTEM)
	append(&req, `, "tools": `)
	append(&req, TOOLS_JSON)
	append(&req, `, "messages": [`)
	append(&req, ..s.transcript[:])
	append(&req, "]}")

	pb: [PATH_MAX]u8
	fd := libuser.open(model_path(s, "request", pb[:]), abi.O_WRONLY)
	if fd < 0 {
		return "", false
	}
	// In pieces that fit a frame; the close ends the request.
	at := 0
	for at < len(req) {
		piece := min(len(req) - at, 4096)
		if libthread.iowrite(s.io, int(fd), req[at:at + piece]) != i64(piece) {
			_ = libuser.close(int(fd))
			return "", false
		}
		at += piece
	}
	_ = libuser.close(int(fd))

	rfd := libuser.open(model_path(s, "reply", pb[:]), abi.O_RDONLY)
	if rfd < 0 {
		return "", false
	}
	defer libuser.close(int(rfd))
	ev := make([]u8, 16 * 1024)
	defer delete(ev)
	stop_reason := ""
	for {
		n := libthread.ioread(s.io, int(rfd), ev)
		if n <= 0 {
			break
		}
		if r := take_event(s, blocks, trim(string(ev[:n]))); r != "" {
			stop_reason = r
		}
	}
	return stop_reason, stop_reason != ""
}

/*
take_event reads one stream event into the blocks. Answers the stop
reason when the event carries one. The strings it answers are the
program's own, because the event's parse is freed here.
*/
take_event :: proc(s: ^Session, blocks: ^[dynamic]Block, line: string) -> string {
	v, err := json.parse_string(line, .JSON, true)
	defer json.destroy_value(v)
	if err != .None {
		return ""
	}
	o, is_obj := v.(json.Object)
	if !is_obj {
		return ""
	}
	switch str_of(o, "type") {
	case "content_block_start":
		cb, _ := obj_of(o, "content_block")
		b := Block {
			text = make([dynamic]u8, 0, 64),
		}
		if str_of(cb, "type") == "tool_use" {
			b.kind = .Tool
			b.id = clone(str_of(cb, "id"))
			b.name = clone(str_of(cb, "name"))
		}
		append(blocks, b)
	case "content_block_delta":
		if len(blocks) == 0 {
			return ""
		}
		b := &blocks[len(blocks) - 1]
		d, _ := obj_of(o, "delta")
		switch str_of(d, "type") {
		case "text_delta":
			text := str_of(d, "text")
			append(&b.text, text)
			append(&s.reply, text)
			answer_held(index_of(s))
		case "input_json_delta":
			append(&b.text, str_of(d, "partial_json"))
		}
	case "message_delta":
		d, _ := obj_of(o, "delta")
		if r := str_of(d, "stop_reason"); r != "" {
			return stop_word(r)
		}
	}
	return ""
}

// stop_word answers the stop reasons as the program's own strings, so
// they outlive the event they came in.
stop_word :: proc "contextless" (r: string) -> string {
	switch r {
	case "end_turn":
		return "end_turn"
	case "tool_use":
		return "tool_use"
	case "max_tokens":
		return "max_tokens"
	case "refusal":
		return "refusal"
	case "stop_sequence":
		return "stop_sequence"
	case "pause_turn":
		return "pause_turn"
	}
	return "unknown"
}

index_of :: proc "contextless" (s: ^Session) -> int {
	for i in 0 ..< MAX_SESSIONS {
		if &sessions[i] == s {
			return i
		}
	}
	return 0
}

// -- The tools ----------------------------------------------------------------

/*
run_tool runs one `tool_use` and answers its result's text, the caller's
to free, and whether it failed. Every step is a line in `log`.
*/
run_tool :: proc(s: ^Session, b: ^Block) -> (text: string, is_error: bool) {
	input := string(b.text[:])
	log_line(s, "tool ", b.name, " ", input)
	set_status(s, "Running ", b.name)
	text, is_error = dispatch(s, b.name, input)
	log_result(s, text, is_error)
	return
}

log_result :: proc(s: ^Session, text: string, is_error: bool) {
	append(&s.log, is_error ? "  error " : "  ok ")
	n := 0
	for i in 0 ..< len(text) {
		if n >= 200 {
			append(&s.log, "...")
			break
		}
		c := text[i]
		append(&s.log, c == '\n' ? ' ' : c)
		n += 1
	}
	append(&s.log, '\n')
}

dispatch :: proc(s: ^Session, name: string, input: string) -> (text: string, is_error: bool) {
	v, err := json.parse_string(input == "" ? "{}" : input, .JSON, true)
	defer json.destroy_value(v)
	args, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return clone("the input is not a JSON object"), true
	}
	// The `admin` class asks before every tool.
	if class_of(s) == "admin" && name != "ask" {
		q := make([dynamic]u8, 0, 128)
		defer delete(q)
		add(&q, name, " ", input)
		if !yes(confirm(s, string(q[:]))) {
			return clone("the person said no"), true
		}
	}
	switch name {
	case "read":
		return tool_read(s, str_of(args, "path"), int_of(args, "offset"), int_of(args, "count"))
	case "ls":
		return tool_simple(s, .Ls, str_of(args, "path"))
	case "write":
		return tool_write(s, str_of(args, "path"), str_of(args, "text"))
	case "run":
		return tool_run_script(s, str_of(args, "script"))
	case "plumb":
		t := tool_new(s, .Plumb)
		defer tool_free(t)
		t.text = str_of(args, "message")
		return sandboxed(s, t)
	case "ask":
		q := make([dynamic]u8, 0, 128)
		defer delete(q)
		add(&q, "ask ", str_of(args, "question"))
		if opts, has := arr_of(args, "options"); has {
			append(&q, " (")
			for o, i in opts {
				if os, is := o.(json.String); is {
					if i > 0 {
						append(&q, " / ")
					}
					append(&q, string(os))
				}
			}
			append(&q, ")")
		}
		return clone(confirm(s, string(q[:]))), false
	case "look":
		return clone("no window to look at: the window is GHOST step 3"), true
	}
	return clone("no such tool"), true
}

// sandboxed runs a tool call on the session's io proc and answers the
// child's output: `ok` and what follows, or `error` and why.
sandboxed :: proc(s: ^Session, t: ^Tool_Run) -> (text: string, is_error: bool) {
	s.tool = t
	_ = libthread.iorun(s.io, tool_run, t)
	s.tool = nil
	head, body := tool_head(t)
	if len(head) >= 2 && head[:2] == "ok" {
		return clone(body), false
	}
	if len(head) >= 6 && head[:6] == "error " {
		return clone(head[6:]), true
	}
	return clone(string(t.out[:t.nout])), true
}

tool_simple :: proc(s: ^Session, op: Op, path: string) -> (string, bool) {
	if path == "" {
		return clone("a path is wanted"), true
	}
	t := tool_new(s, op)
	defer tool_free(t)
	t.path = path
	return sandboxed(s, t)
}

tool_read :: proc(s: ^Session, path: string, offset, count: i64) -> (string, bool) {
	if path == "" {
		return clone("a path is wanted"), true
	}
	t := tool_new(s, .Read)
	defer tool_free(t)
	t.path = path
	t.offset = offset
	t.count = count
	text, failed := sandboxed(s, t)
	if !failed {
		head, _ := tool_head(t)
		_, ver := word(head)
		if v, ok := libuser.atoi(trim(ver)); ok {
			seen_set(s, path, u32(v))
		}
	}
	return text, failed
}

/*
tool_write is the staleness check and the requester. The child answers
`stale` when the file moved since the ghost read it, `exists` when it is
there and no yes has been given this session, and `ok` with the new
version when it wrote.
*/
tool_write :: proc(s: ^Session, path: string, text: string) -> (string, bool) {
	if path == "" {
		return clone("a path is wanted"), true
	}
	expect := i64(-1)
	for e in s.seen {
		if e.path == path {
			expect = i64(e.version)
		}
	}
	for attempt in 0 ..< 2 {
		t := tool_new(s, .Write)
		defer tool_free(t)
		t.path = path
		t.text = text
		t.expect = expect
		t.confirmed = s.write_ok
		_ = libthread.iorun(s.io, tool_run, t)
		head, _ := tool_head(t)
		verb, ver := word(head)
		switch verb {
		case "ok":
			if v, ok := libuser.atoi(trim(ver)); ok {
				seen_set(s, path, u32(v))
			}
			nb: [24]u8
			return clone(libuser.cat_into(t.iobuf[:], "wrote ", libuser.itoa(nb[:], i64(len(text))), " bytes")), false
		case "stale":
			return clone("stale: the file changed since it was read; read it again"), true
		case "exists":
			if attempt > 0 {
				return clone("the file exists"), true
			}
			q := make([dynamic]u8, 0, 128)
			defer delete(q)
			add(&q, "write ", path)
			if !yes(confirm(s, string(q[:]))) {
				return clone("the person said no"), true
			}
			s.write_ok = true
			if v, ok := libuser.atoi(trim(ver)); ok {
				expect = v
			}
		case "error":
			return clone(ver), true
		case:
			return clone(string(t.out[:t.nout])), true
		}
	}
	return clone("the write did not settle"), true
}

// tool_run_script runs rc on the script, asking first when it names a
// program that takes things away.
tool_run_script :: proc(s: ^Session, script: string) -> (string, bool) {
	if script == "" {
		return clone("a script is wanted"), true
	}
	if names_danger(script) {
		q := make([dynamic]u8, 0, 128)
		defer delete(q)
		add(&q, "run ", script)
		if !yes(confirm(s, string(q[:]))) {
			return clone("the person said no"), true
		}
	}
	t := tool_new(s, .Run)
	defer tool_free(t)
	t.script = script
	s.tool = t
	_ = libthread.iorun(s.io, tool_run, t)
	s.tool = nil
	out := make([dynamic]u8, 0, t.nout + 64)
	append(&out, ..t.out[:t.nout])
	status := tool_status(t)
	if t.killed {
		append(&out, "\n(killed: past its deadline)")
	} else if status != "" {
		append(&out, "\n(exit: ")
		append(&out, status)
		append(&out, ")")
	}
	return string(out[:]), t.killed || status != ""
}

// names_danger says a script names `rm`, `kill` or `mv` as a word.
names_danger :: proc "contextless" (script: string) -> bool {
	i := 0
	for i < len(script) {
		for i < len(script) && !word_char(script[i]) {
			i += 1
		}
		b := i
		for i < len(script) && word_char(script[i]) {
			i += 1
		}
		w := script[b:i]
		// A path's last element is the program's name.
		for j := len(w) - 1; j >= 0; j -= 1 {
			if w[j] == '/' {
				w = w[j + 1:]
				break
			}
		}
		if w == "rm" || w == "kill" || w == "mv" {
			return true
		}
	}
	return false
}

word_char :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '/' || c == '.' || c == '-'
}

seen_set :: proc(s: ^Session, path: string, version: u32) {
	for &e in s.seen {
		if e.path == path {
			e.version = version
			return
		}
	}
	append(&s.seen, Seen{path = clone(path), version = version})
}

/*
confirm asks the person, through `confirm`, and waits. The status says
Waiting, and a read parked on `confirm` answers the question now. The
answer is the next write to `confirm`, or `no` from the clock after a
minute. What it answers is the session's buffer, good until the next ask.
*/
confirm :: proc(s: ^Session, question: string) -> string {
	clear(&s.question)
	append(&s.question, question)
	s.asking = true
	s.delivered = false
	s.deadline = now + CONFIRM_DEADLINE
	set_status(s, "Waiting")
	log_line(s, "confirm ", question)
	answer_held(index_of(s))
	_ = libthread.recvp(s.answered)
	answer := string(s.answer[:s.alen])
	log_line(s, "  answer ", answer)
	return answer
}

yes :: proc "contextless" (answer: string) -> bool {
	return answer == "yes" || answer == "y"
}

// -- JSON ---------------------------------------------------------------------

// add appends each of `parts`.
add :: proc(out: ^[dynamic]u8, parts: ..string) {
	for p in parts {
		append(out, p)
	}
}

// json_str appends `s` as a JSON string, quoted and escaped.
json_str :: proc(out: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	append(out, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			append(out, `\"`)
		case '\\':
			append(out, `\\`)
		case '\n':
			append(out, `\n`)
		case '\r':
			append(out, `\r`)
		case '\t':
			append(out, `\t`)
		case:
			if c < 0x20 {
				append(out, `\u00`)
				append(out, hex[c >> 4])
				append(out, hex[c & 15])
			} else {
				append(out, c)
			}
		}
	}
	append(out, '"')
}

valid_object :: proc(text: string) -> bool {
	v, err := json.parse_string(text, .JSON, true)
	defer json.destroy_value(v)
	_, is_obj := v.(json.Object)
	return err == .None && is_obj
}

str_of :: proc(o: json.Object, key: string) -> string {
	if v, has := o[key]; has {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return ""
}

int_of :: proc(o: json.Object, key: string) -> i64 {
	if v, has := o[key]; has {
		#partial switch t in v {
		case json.Integer:
			return i64(t)
		case json.Float:
			return i64(t)
		}
	}
	return 0
}

obj_of :: proc(o: json.Object, key: string) -> (json.Object, bool) {
	if v, has := o[key]; has {
		if sub, is := v.(json.Object); is {
			return sub, true
		}
	}
	return nil, false
}

arr_of :: proc(o: json.Object, key: string) -> (json.Array, bool) {
	if v, has := o[key]; has {
		if a, is := v.(json.Array); is {
			return a, true
		}
	}
	return nil, false
}

trim :: proc "contextless" (s: string) -> string {
	b := 0
	e := len(s)
	for b < e && (s[b] == ' ' || s[b] == '\n' || s[b] == '\t' || s[b] == '\r') {
		b += 1
	}
	for e > b && (s[e - 1] == ' ' || s[e - 1] == '\n' || s[e - 1] == '\t' || s[e - 1] == '\r') {
		e -= 1
	}
	return s[b:e]
}

// -- The fixed prefix ---------------------------------------------------------

SYSTEM :: "You are the ghost, an agent in the Vectra shell. You act through files: every program here serves one, and your tools read and write them. Your tools run in a namespace that holds what your task was given and nothing else. The task's directory is /n/work. A write to a file that exists, and a script that takes things away, ask the person first. Everything you do is logged."

/*
The seven tools, the API's JSON, in a fixed order with the cache
breakpoint after the last, because a tool list that reorders is a cache
that never hits. An application's verbs are appended after them in step
2, through tool search.
*/
TOOLS_JSON: string : `[{"name": "read", "description": "Read a file's bytes. The version the read saw is what a later write to it is held to.", "input_schema": {"type": "object", "properties": {"path": {"type": "string"}, "offset": {"type": "integer"}, "count": {"type": "integer"}}, "required": ["path"]}}, ` +
	`{"name": "ls", "description": "List a directory, one entry a line, a directory's name ending in a slash.", "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}, ` +
	`{"name": "write", "description": "Write text to a file, replacing what it held. Refused as stale when the file changed since it was last read.", "input_schema": {"type": "object", "properties": {"path": {"type": "string"}, "text": {"type": "string"}}, "required": ["path", "text"]}}, ` +
	`{"name": "run", "description": "Run an rc script in the task's namespace and answer its output. It has a deadline.", "input_schema": {"type": "object", "properties": {"script": {"type": "string"}}, "required": ["script"]}}, ` +
	`{"name": "plumb", "description": "Send a message to the plumber, which routes it to a program by its rules.", "input_schema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]}}, ` +
	`{"name": "ask", "description": "Ask the person a question and wait for the answer.", "input_schema": {"type": "object", "properties": {"question": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}}}, "required": ["question"]}}, ` +
	`{"name": "look", "description": "Look at a window's pixels, for an application that serves no dict.", "input_schema": {"type": "object", "properties": {"window": {"type": "string"}}, "required": ["window"]}, "cache_control": {"type": "ephemeral"}}]`
