# Ghost: an agent in the shell, on files, in a namespace

**Written before the code.** Every plan before this one is for a person at
the machine, and this one is for the program that works beside them. A
model runs on the machine when a small one will do and in the cloud when
the task wants a frontier one. It acts through the same files a person
uses and drives applications through a control tree every application
serves. It lives in a namespace that holds what it may touch and nothing
else. `docs/HANDOFF.md` section 6 points here.

The name is `ghost`, and the machine's third idea is that the ghost is
part of the shell. Not a window bolted on, not a chat box in front of
someone else's cloud, and not a second-class citizen of anything. A shell
script can ask it, a program can ask it, and a chord summons it. Every
answer it gives and every action it takes is a file a person can read.

**What a person sees.** A chord opens the ghost's window on any
workspace, or `ask 'why is the build slow'` at a prompt. The ghost reads
the build's output, opens the debugger on the process that stalled, and
says what it found. `ask -w /usr/glenda/src/pong 'add a pause key'` gives
it that directory and the editor, and nothing else, and a requester asks
before the first write. `cat /mnt/ghost/3/log` is every step it took. A
game on `sys/libapp` writes a line to `/mnt/ghost/new` and gets a
commentator.

## 1. What is taken, and from where

**From Plan 9, the whole shape.** `acme` is an editor whose every part is
a file under `/mnt/acme`, and a program that writes `ctl` drives it. That
is the application contract here, and every application serves one. The
`plumber` routes a message from one program to another by rules in a file.
That is how the ghost hands a file name to the editor.

A namespace is per process, so a sandbox is a mount table and not a policy
in the agent's code. `webfs` is an HTTP client as a file server, and
`factotum` holds the API key so no program ever does. `rio`'s `wctl` is
already a control file, and `docs/WORKBENCH.md` widened it.

**From ARexx.** Every Amiga application had a port, a command set, and a
page in its manual that listed the commands. A script addressed a port
by name and sent it words. The port here is a directory, the words are
lines to `ctl`, and the manual page is a file the application serves.
And ARexx's lesson that the person's scripting and the program's
automation are one mechanism, so `rc` drives an application exactly as
the ghost does.

**From AppleScript.** The dictionary. An application publishes its
vocabulary in a form a tool can read, and a tool that reads it knows
what the application can do. Section 5's `dict` file is that, and it is
what the ghost turns into tool definitions.

**From the Claude API.** The agent loop as it exists, with a request as a
list of messages and a list of tools. A reply is content blocks with
`tool_use` among them, and the loop runs until the model stops. Prompt
caching as a stable prefix, server-side compaction for a session that runs
long, and a memory directory the model reads and writes. The wire format
between the ghost and any model is that API's JSON, verbatim, for the
cloud and the machine alike. It is the one a frontier model already
speaks, and a local engine is written to it.

**From Omarchy.** That an operating system can ship with the agent as
part of the setup rather than as a download. Its Quattro release added
three things worth keeping. The agent's state is shown where a person
is looking. A crashed program is handed to the agent from the notice
that says it crashed. And one switch turns all of it off.

Taken further, because here the agent is a file server and every
application is one too. So the state is a word on `wctl`, and the crash
is a parked process rather than a core file.

**Not taken.** A chat window as the whole of it, and a plugin API per
application. A model in the kernel, or a file system that a model indexes.
Screenshots as the primary way to drive a program. Permission by popup for
every action in place of a sandbox. Section 2 says why.

## 2. The models this refuses, and what each got wrong

**The assistant as an application.** A window with a text box that can
answer questions and reach nothing. Every other program on the machine is
opaque to it. The answer to `open this in the editor` is then a paragraph
about how a person might. The ghost's reach is the namespace, and the
namespace reaches everything.

**A plugin interface per application.** COM, AppleEvents as most
programs shipped them, and editor extension APIs. Each application
grows a second surface for automation beside its first for people, and
the two drift. Here an application has one surface, its files, and the
person and the ghost use the same one.

**The model in the operating system.** A semantic file system, a kernel
that answers natural language, or an inference engine in ring 0. A
model format has a half life of a few years, and `docs/HARDWARE.md`
section 2 says what a kernel that owns one becomes. The kernel here
never sees a token. A model is a program that serves a directory.

**Screenshots as the way in.** Computer use over pixels works when
nothing better exists, and it is slow, costly and blind to what a
program knows about itself. Here every application says what it can do
in a file, and pixels are the fallback for one that does not.

**Permission by popup.** An agent that asks before every action trains a
person to say yes. A sandbox that cannot name a file cannot touch it, and
needs no popup. The requester here is for the few actions a namespace
cannot express, and section 4 names them. A jailbroken model inside the
sandbox still cannot see what it cannot name.

## 3. Models as files

`servers/modelfs` serves a directory a model answers from. It has
backends, and a client cannot tell which one it has.

    /mnt/model/ctl          the models this server offers, one per line
    /mnt/model/new          read it for a session number
    /mnt/model/N/ctl        model <name>, and hangup
    /mnt/model/N/request    write the request, as the Messages API's JSON
    /mnt/model/N/reply      a read that parks, and answers the reply as
                            the API's stream events, one per read
    /mnt/model/N/usage      tokens in, tokens out, cache reads, and the
                            cost so far, one line

**The format is the API's, on both sides.** A request is `model`,
`system`, `messages`, `tools` and `max_tokens`. A reply is the stream of
`content_block_start`, `content_block_delta` and `message_delta` events,
with `stop_reason` at the end. A local backend implements a subset and
refuses the rest by name. The ghost, a shell script and a program in
`sys/libapp` all write the same JSON, and the JSON is
`core:encoding/json`'s.

**The local backend is an engine in Odin.** A GGUF reader, the
llama-family forward pass, and quantised matrix multiply in four and eight
bits with `#simd`. A key-value cache, the tokenizer from the file's own
vocabulary, and a sampler. One proc per core through `sys/libthread`,
sharing the weights under `RFMEM`. It runs on every architecture and on
QEMU, slowly, and its size is about four thousand lines. A model of one to
eight billion parameters at four bits fits the board's memory. That is the
size a machine on a desk runs.

**The escape hatch is a port.** `llama.cpp` under `docs/DEVTOOLS.md`'s
POSIX library is a second backend the day the Odin engine is behind on
an architecture or a model family. It speaks the same directory, and a
client cannot tell.

**The accelerators are backends too.** `sys/libgpu`'s compute queue,
`docs/HARDWARE.md` step 5, runs the matrix multiply. The NPU runs a
graph the vendor's compiler emitted, through `sys/libnpu`, when such a
graph runs a decode step, and not before. Each is a backend behind the
same files.

**The stub backend is for the self-test.** `modelfs -e script` answers
from a file of canned replies, tool calls included. Every check in this
document runs against it. A boot then proves the loop, the sandbox, the
requester and the application contract with no model on the disk. A real
model is a manual check, and section 8's boot lines say which.

Proves: a request written to the stub comes back as events. A request
to a small model on the disk completes a sentence on QEMU.

## 4. The ghost: the loop, the tools, and the namespace it runs in

`servers/ghost` is one per user session, started with `factotum`, and
serves `/mnt/ghost`. A session is a directory, the draw server's shape.

    /mnt/ghost/new          read it for a session number
    /mnt/ghost/N/ctl        model, effort, budget, work <dir>, class <c>
    /mnt/ghost/N/prompt     write a message from the person
    /mnt/ghost/N/reply      a read that parks, and streams the answer
    /mnt/ghost/N/confirm    a read that parks until the ghost needs a yes
    /mnt/ghost/N/log        every step: the tool, its input, its result
    /mnt/ghost/N/status     Thinking, Running <tool>, Waiting, Idle
    /mnt/ghost/N/tools      the tools this session offers, as the API's JSON
    /mnt/ghost/N/ns         the namespace the tools run in, as `ns` prints

A session persists as `$home/lib/ghost/sessions/N`, an append-only
transcript, so a session survives the server and is a file a person can
read or grep. The transcript is never edited, because the frontier
models refuse an edited history and a log that changes is not a log.

**The loop is the API's.** Write the request, read the events, run each
`tool_use`, and send every result back in one message, with `is_error` on
the ones that failed. Stop on `end_turn`, `max_tokens` or `refusal`. A
`refusal` ends the turn with its category in `status`. The cloud backend
asks the API for its default fallback, so a model that will answer takes
the refused request.

**The tools, and why there are seven.** The API's own authors say to start
with a shell for breadth. An action gets a tool of its own when the
harness must gate, render, audit or parallelise it. On a machine where
everything is a file, that yields a short list.

    read path [offset count]   a file's bytes, parallel-safe
    ls path                    a directory, with the Dir fields
    write path text            refused if the qid version moved since
                               the last read, which is the staleness
                               check Plan 9 gives for free
    run script                 rc, in the session's namespace, its
                               output back, with a deadline
    plumb message              a message to the plumber, section 5
    ask question [options]     a requester on the screen, or a line on
                               the terminal, and the loop waits
    look window                the window's pixels as an image, for an
                               application with no dict

And one tool per verb of every application's `dict`, generated from the
file, section 5. The seven are the fixed prefix, and the application tools
are appended after it with the API's tool search over them. A session with
forty applications mounted carries seven schemas in context and finds the
rest by name. The order is deterministic, because a tool list that
reorders is a cache that never hits.

**The namespace is the sandbox.** The tools run in a child the ghost forks
with `RFNAMEG`, `RFNOMNT` and `RFNOTEG`, as the user `ghost` from
`docs/FLEET.md` section 4. `RFNOMNT` means the child may not mount or bind
again, so the table the ghost built is the table the tools have. A class
file names what goes in it.

    # /lib/ghost/ns/edit: a task on a directory, with the editor
    bind $work /n/work
    bind /mnt/app/editor /mnt/app/editor
    bind /mnt/plumb /mnt/plumb
    bind /$cputype/bin /bin
    bind -a /rc/bin /bin

There is no `/net`, no `/proc`, no `/srv`, no `/dev` beyond `null` and
`cons`, and no `$home`. A `write` outside `/n/work` fails on the mode
because the user is `ghost`, and a `run` cannot dial because there is
nothing to dial through. The model server and the web server are in the
ghost's own namespace and not in the tools'. A task that talks the model
into `run curl` finds no `curl` and no network. The class `debug` adds
`/proc` and the debugger's tree. The class `admin` adds what a person
names, and asks first.

**The requester is for what a namespace cannot say.** Four actions ask
through `confirm`. A write to a file that exists, the first time in a
session. A `run` whose script names `rm`, `kill` or `mv`. A `plumb` whose
rule runs a program, and any tool call in the `admin` class. The window
shows a `libmui` requester with the tool's input in it, `ask` shows a
line, and no answer inside a minute is no.

**A parked `confirm` is a lamp.** `apps/ghost` writes `state working`
to its window's `wctl` when `status` leaves Idle, `state waiting` when
a read of `confirm` would answer, and `state idle` after. The frame
shows the lamp and the workspace lamp goes hot, `docs/WORKBENCH.md`
section 4. A person on another workspace sees that the machine wants a
yes without finding the window. `ask` on a terminal writes the same
words to its own window's `wctl` when it has one, and nothing when it
has not.

**The budget is a line.** `ctl budget 200000` is tokens for the session,
and `usage` on the model's directory is what counts against it. A wall
clock deadline is an `alarm`, and `run` has one of its own per call. A
session that runs out stops at the next tool call with the reason in
`status`, and the transcript says where.

**Memory is a directory.** `$home/lib/ghost/memory` is the memory tool's
backend, one file per fact. The model reads and writes it through the
`memory` tool the API defines, which the ghost implements over `read`,
`write` and `ls`. It is the person's to edit, and `ls` lists what the
ghost remembers.

**A session that runs long.** The cloud backend asks for compaction and
appends the reply's content whole, compaction blocks included. A
transcript that keeps only the text loses the summary. Context editing
clears old tool results first, since a `read` of a log is stale a turn
later. The local engine has a shorter window and the ghost summarises for
it with the same model.

**`cmd/ask` is the line client.** `ask 'what is using the disk'` opens a
session, writes the prompt, streams the reply to the terminal, and
answers a requester with a line. `-w dir` names the work directory,
`-c class` the namespace class, and `-m model` the model. `-p pid`
names a process, and the `debug` class then binds that process's
`/proc` directory and the debugger's tree, and no other process. It is a page
of `rc`-shaped code over the files above, and it is what the self-test
drives.

Proves, against the stub. A scripted tool call that writes inside
`/n/work` lands, and one outside answers permission denied. A `run
curl` answers no such file. A `read /proc/1/status` answers no such
file. A `write` to a file the script changed under it answers stale. A
`kill` in a script parks on `confirm`, and the test answers no. And one
control, the child forked without `RFNOMNT`, so a `run bind` succeeds
and the sandbox check fails.

## 5. Applications, and the contract that makes them scriptable

An application that wants to be driven serves a tree under `/mnt/app/
<name>`, and three files are the contract.

    ctl        lines of verbs, one per line, the way every ctl here works
    dict       the vocabulary: one verb per line, its arguments, and one
               sentence, in the form the ghost turns into a tool
    event      a read that parks, and answers what the application did,
               one line per event, for a script that waits for one

    # /mnt/app/editor/dict
    open path            open a file in a new window
    goto line            move the cursor to a line in the current window
    replace from to      replace the first match in the selection
    save                 write the current window
    text                 read: the current window's text, on the `text` file

A line of `dict` is a verb, its argument names, and a description, and
a tool is generated from it with a string per argument. An application
that wants a typed argument writes `line:int`. A file beside `ctl` that
answers a read is listed with `read:` and becomes a `read` the ghost
knows the meaning of.

**An argument that can carry any text is the last on its line.** A
`ctl` line is split on spaces, and a file name with a space in it, or a
notice's text, is where that breaks. So a verb takes one such argument,
last, as the rest of the line, and `open path` reads to the newline. A
verb that needs two writes them as `rc` quotes them and reads them with
`rc`'s tokenizer, never with a split of its own. The tool generator
quotes the same way.

Omarchy's shell built its notices by pasting the text into bash, and a
video's title ran as a command. A line that is a verb and its rest
cannot be made to.

**`libmui` serves the contract for free.** A toolkit program's gadgets
have names, because a hotkey needs a label. The toolkit serves
`gadgets/<name>` under the application's tree. A read answers a gadget's
state, a write presses it or sets it, and `dict` is generated from the
gadget tree. So every toolkit program is scriptable the day it links, with
no line written. An application adds verbs of its own beside the generated
ones.

**The plumber is how programs talk.** `servers/plumber` serves
`/mnt/plumb`, with `send` and a directory of ports. A message is a source,
a destination, a working directory, a type, attributes and data, as Plan
9's is. `/lib/plumb/rules` says which port gets it.

    type is text
    data matches '([a-zA-Z0-9_/.-]+\.odin):([0-9]+)'
    arg isfile $1
    data set $file
    attr add addr=$2
    plumb to edit

A person's `plumb pong.odin:31` and the ghost's `plumb` tool are one
mechanism, and an application that reads `/mnt/plumb/edit` opens what
arrives. The ghost is a port too, `/mnt/plumb/ghost`, so a rule can
route a question to it.

**The applications that serve a tree first.** `intuition`'s `wctl` is one
already, and gets a `dict`. The terminal serves `send` for a line typed
and `text` for the grid. Workbench serves `open`, `run` and `workspace`.
The debugger is `docs/DEVTOOLS.md` section 7's tree and needs no change,
so the ghost debugs by writing `break` and reading `bt`.

**A crash is the desktop's notice, and the answer is a click.** `window`
parks a program that faults and posts the notice, `docs/WORKBENCH.md`
section 6. The click runs `ask -c debug -p N 'this program faulted'`.
The ghost attaches, reads `status` and `bt`, opens the top frame's
`vars`, and says what it found. It writes nothing and files nothing. A
fix is a second prompt, in the `edit` class, on the source, and the
requester asks before the first write as it always does.

An editor is the application that most wants a `dict` and does not exist
yet. `sam`'s command language is its `dict` when it does, and `acme`'s
files are its tree.

**A program asks the ghost the same way.** A write to `/mnt/ghost/new`
and a prompt. `sys/libapp` wraps it in one call for a game that wants
a narrator, and `libmui` gets no object for it, because a file is
enough.

**The hatch is pixels.** For an application with no tree, `look` reads its
window's store as an image. Writes to the window's `mouse` and `cons`
files press and type, and the draw server serves both already. It is slow
and it works, and the day the application serves a `dict` the ghost stops
looking.

Proves, against the stub. A scripted `dict` verb reaches a toolkit
test program's gadget and its state reads back changed. A `plumb` of a
file name opens it in the test program. `event` answers the press. And
a script drives the same gadget with `echo` and `cat`, because the
contract is files.

## 6. The cloud, and the wire to it

The cloud backend is `modelfs -c anthropic`, and it is a client of two
servers. `servers/webfs` is Plan 9's HTTP client as files, `/mnt/web/
clone`, a `ctl` that takes a URL and a method, `postbody`, and a `body`
that streams. `cmd/tlsclient` is a TLS 1.3 client over `core:crypto`, with
X.509 parsing and a root store at `/lib/tls/roots`. It wraps the dial the
way `docs/FLEET.md`'s sealing does. Both need `docs/FLEET.md` step 0 for
`/net`.

**The key is `factotum`'s.** `key proto=apikey host=api.anthropic.com
!key=...` is a line written once, and `webfs` asks `factotum` for the
header when the URL's host matches. `modelfs` never sees the key, the
ghost never sees it, and a tool cannot read it because `factotum` is
not in the tools' namespace.

**The request, as the API wants it.** `POST /v1/messages` with `x-api-key`
and `anthropic-version: 2023-06-01`, `stream: true` always, and
`max_tokens` of sixty-four thousand, because a stream has no timeout to
fear. The model is `claude-opus-5` unless `ctl` names another, thinking is
adaptive by leaving the parameter out, and `output_config.effort` is
`ctl`'s `effort` word.

The system prompt and the seven tools are the fixed prefix, with a
`cache_control` breakpoint after them. The application tools follow
through tool search. The transcript is appended and never rewritten, so
the cache hits every turn. An operator instruction mid-session is a system
message appended to the transcript, not an edit of the prefix. Every tool
is `strict`, so an argument is the type the `dict` said.

**What is refused, and what happens.** A reply with `stop_reason` of
`refusal` carries a category. The request asked for the API's default
fallback, so the answer comes from a model that will give one. The
transcript records both. A reply of `max_tokens` is continued.

**The router is a file.** `/lib/ghost/route` says which model a
session starts on.

    class edit     claude-opus-5
    class debug    claude-opus-5
    class ask      local:qwen3-4b     # a question at a prompt
    offline        local:qwen3-4b
    tools > 20     claude-opus-5
    context > 32k  claude-opus-5

A person's `ctl model` word wins over every line. The local model answers
a short question, a classification and a summary. The frontier model gets
the task with tools, the long context, and the code. `offline` is what a
machine with no route uses. A session that started local stays local,
because a model change mid-session empties the cache and the two
transcripts differ.

Proves: a request through the stub `webfs` comes back as events with
the key from `factotum` in the header the test reads. A live request,
by hand, with a key in `factotum`, answers from the cloud.

## 7. The fleet, and where a model runs

A model server is a file server, so it runs where the accelerator is
and is imported everywhere else. `import big /mnt/model` on a terminal
puts the board's NPU behind a terminal's ghost, and `docs/FLEET.md`
section 8's `fleet/on` picks the machine by an `ndb` attribute,
`model=`. The weights live on the file server under `/lib/models`, one
copy, and a machine that starts `modelfs -l /lib/models/qwen3-4b.gguf`
reads them through the mount.

The ghost's `run` tool is `rc`, and `rc` has `rx`. A task that wants the
fast machine says so in a script, and the fleet's plan does the rest. The
ghost knows nothing about machines, and `ndb` knows nothing about models
beyond a word.

Proves: a ghost on the amd64 machine completes a prompt through a
`modelfs` imported from the arm64 machine, on the bench.

## 8. MCP, both ways

The Model Context Protocol is the ecosystem's shape for tools, and a
namespace is this tree's. A bridge each way costs little and buys the
ecosystem.

**`servers/mcpfs` mounts an MCP server as files.** `/mnt/mcp/<server>/
<tool>/schema` reads the tool's schema, and a write to `call` with the
arguments answers the result on the same file. The server runs over a
pipe for a local one and through `webfs` for a remote one. Mounted
under `/mnt/app`, an MCP server is one more application with a `dict`,
and the ghost cannot tell.

**`cmd/mcpserve` is the namespace as an MCP server.** It speaks the
protocol on descriptors zero and one. It offers the seven tools and every
mounted application's verbs, in the namespace it was started in. Over a
`cpu` connection or a serial line, an agent on another machine drives this
one's applications through the same contract, in the same sandbox. Claude
Code on the host is one such agent.

Proves: a scripted MCP server over a pipe appears under `/mnt/app`, and
its tool answers through the ghost. `mcpserve` over a pipe answers a
tool list and a `read`.

## 9. The order

Each step ends with a boot line against the stub, and each is usable
before the next starts. Steps 0 and 1 need nothing this tree has not
built.

### Step 0: `modelfs`

`servers/modelfs`, `sys/libinfer`, the stub. About 5,200 lines, four
thousand of it the engine. Needs the disk and the heap.

Boot line: the stub answers a request as events. By hand: a small model
completes a sentence on QEMU.

### Step 1: `ghost` and `ask`

`servers/ghost`, `cmd/ask`, `/lib/ghost/ns`, the memory backend. About
3,000 lines. Needs step 0, and `docs/FLEET.md` step 2 for the user
`ghost`. Until then there is one user, the mode check waits, and the boot
line says so.

Boot line: section 4's sandbox checks, and its control.

### Step 2: the application contract

`sys/libmui`'s `gadgets` and `dict`, `servers/plumber`, the terminal's
and Workbench's trees, the tool generator and tool search. About 2,400
lines. Needs `docs/WORKBENCH.md` step 3.

Boot line: section 5's gadget, plumb and event checks.

### Step 3: the window and the chords

`apps/ghost`, the Workbench menu, the chord, `sys/libapp`'s call, the
`state` words, and the fault notice's action. About 1,600 lines. Needs step 2 and `docs/WORKBENCH.md` step 4.

Boot line: the window opens on a session, a requester answers
`confirm`, and the frame's lamp is hot while it waits.

### Step 4: the cloud

`cmd/tlsclient`, `servers/webfs`, the `apikey` protocol in `factotum`,
the cloud backend, the router, caching and compaction. About 6,500
lines, most of it TLS and X.509. Needs `docs/FLEET.md` steps 0 and 2.

Boot line: a request through the stub `webfs` carries the key. By
hand: a live answer.

### Step 5: the fleet and the accelerators

`modelfs` imported, `/lib/models`, the `libgpu` backend, the NPU
backend, the `llama.cpp` backend. About 2,500 lines of this tree's
own. Needs `docs/FLEET.md` step 5 and `docs/HARDWARE.md` step 5 for the
GPU.

Boot line: a prompt answered through an imported `modelfs` on the
bench.

### Step 6: MCP

`servers/mcpfs`, `cmd/mcpserve`. About 1,600 lines. Needs step 2 and
`webfs` for a remote server.

Boot line: section 8's two checks.

### Deferred, with the reason written down

- **Images in.** A `look` is an image block in a request, and the local
  engine has no vision. The cloud path carries it from step 4, and a
  local vision model waits for one that fits the board.
- **Voice.** `/dev/audio` exists from `docs/DEVTOOLS.md` step 1, and a
  speech model is a backend like any other. It waits for a model that
  runs on the machine.
- **Training and fine tuning.** Not this tree's business, by the same
  argument as the NPU's compiler.
- **A second cloud.** `modelfs -c` takes a name, and the format is the
  Messages API's. A second provider is a translation in the backend
  the day someone wants it, and the ghost does not change.

## 10. Decisions taken here, and what would reverse them

- **A model is a file server, and the kernel never sees a token.** The
  reversal is none.
- **The wire format is the Messages API's JSON, local and cloud
  alike.** One format, so a local engine and a frontier model are the
  same directory. The reversal is a format the API drops, and then the
  backend translates and the directory does not change.
- **Seven tools, and the applications' verbs after them.** Because a
  file system needs few verbs and a harness needs to gate the ones
  that change things. The reversal is an action the seven cannot
  express and an application cannot serve, and there is not one.
- **The sandbox is the namespace, and `RFNOMNT` is the lock.** Not a
  policy in the ghost's prompt and not an allow list in its code. The
  reversal is a resource with no file, and this tree has none.
- **The requester is for four actions, named.** Not for every write.
  The reversal is a person who wants more asked, and it is a line in
  the class file.
- **The application contract is three files, and `libmui` serves it
  free.** The reversal is an application that is not files, and the
  answer is `look`.
- **The key lives in `factotum`.** No program holds it, and the tools
  cannot reach `factotum`. The reversal is none.
- **The default model is `claude-opus-5`, at adaptive thinking, and
  the route file says otherwise.** The reversal is a newer model, and
  it is a line.
- **The transcript is append-only.** Because the log must be a log and
  the frontier models refuse an edited history. The reversal is none.
- **The local engine is Odin first, and the port is the hatch.** Because
  four thousand lines a person can read beat a hundred thousand they
  cannot. The port waits behind the same files for the day the four
  thousand are behind.
- **The stub is the self-test's model.** A boot cannot depend on a
  network or on a gigabyte on a disk. The reversal is none.
- **Two bridges to MCP, and the ghost cannot tell.** The reversal is a
  protocol the ecosystem drops, and a bridge is a program that stops
  being built.
- **Off is one file.** `$home/lib/ghost/off` present, and `init` does
  not start the ghost. The menu item and the chord are absent, and no
  process parks on a fault. The notice says faulted and nothing more,
  no lamp lights, and the bar shows no spend. A person who wants none
  of it gets none of it, and the rest of the desktop does not know the
  difference. The reversal is none.
- **A crash is a parked process, not a core file.** Because the machine
  still has the process, its memory and its registers, and a debugger
  that reads them. A core file is what a system writes when it cannot
  keep the process. The reversal is a fault the kernel cannot survive,
  which is a panic and not a crash.

## 11. Sizes and order of dependence

    step 0  modelfs        modelfs 800, libinfer 4,000, stub 200, tests 200     the disk
    step 1  ghost          ghost 2,200, ask 300, ns files 100, memory 200, tests 200   step 0
    step 2  applications   libmui 800, plumber 800, trees 400, generator 400    step 1, WORKBENCH 3
    step 3  the window     apps/ghost 1,300, menu 100, libapp 100, tests 100    step 2, WORKBENCH 4
    step 4  the cloud      tlsclient 3,500, webfs 1,500, factotum 200,          step 1, FLEET 0 and 2
                           backend 600, router 200, tests 500
    step 5  fleet, accel   import 100, gpu backend 1,200, npu 600, port 600     step 4, FLEET 5, HARDWARE 5
    step 6  mcp            mcpfs 900, mcpserve 700                              step 2

Steps 0 and 1 stand on what the tree has today, plus one user. Step 4
is the one that waits on the network, and every check before it runs
with no network at all.

## See also

- `docs/FLEET.md` -- the users, `factotum`, `/net` and the import this
  runs on, and the fleet a model server joins.
- `docs/WORKBENCH.md` -- `libmui`, whose gadgets become a `dict`, and
  the desktop that grows a chord and a menu.
- `docs/DEVTOOLS.md` -- the debugger the ghost drives through files, the
  POSIX library the port needs, and `sys/libapp`.
- `docs/HARDWARE.md` -- the GPU and NPU as directories, which the
  backends sit on, and the refusal of a model format in the kernel.
- `docs/USER.md` -- `rfork` and the flags the sandbox is made of.
- `docs/NAMESPACE.md` -- the mount table that is the sandbox.
- `docs/DRAW.md` -- the window files `look` and the pixel hatch use.
- `docs/TESTING.md` -- why the stub, and why the control.
