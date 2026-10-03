# Phase 8 — `hx`, the editor

_Blueprint v0, 2026-10-02. Provisional: a vision. Its first pieces land at M7 (§16). It fixes the intended shape and is rewritten against the code each piece produces._

## 1. The position

**Acme had the right ideas.** Text is the interface: any text in any window can be run as a command or plumbed as a reference. The editor is a file server, `/mnt/acme`, so any program can open windows, read and change text and react to events, and Acme itself stays small. Mail, news, debuggers and shells were all external programs that drove those files.

**Acme also stopped in 1994.** It has no syntax awareness, no language intelligence, no multiple selections, poor handling of large files, no undo history beyond a list, and a mouse-only design that many people cannot or will not use.

**Zed shows what a modern editor can do.** It draws every frame on the GPU, opens large projects at once, understands code through tree-sitter and language servers, edits many places at once, shows search results and diagnostics as editable multibuffers, works on a remote machine as if it were local, and lets several people edit one buffer.

**`hx` is Acme's architecture with Zed's capabilities.** It keeps Acme's file server, executable text and plumbing, takes sam's structural regular expressions as its command language, and adds what Zed has: a GPU-drawn `vxui` interface, tree-sitter, language servers, multiple selections, multibuffers, Git, remote editing and collaboration.

**`hx` has no AI in it.** Zed carries an agent panel, model providers, API keys, edit prediction and a context protocol. On VectraOS all of that is the operating system's: `aid` runs models (03 §8.1), the routing policy decides where prompts go (03 §8.6), `keyd` holds the keys, the namespace confines agents (02 §7), `auditfs` records and undoes what they do (03 §8.5), and `vxui` text fields already offer inline assist (03 §8.4). What `hx` provides is what every agent, script and person needs alike: its file interface (§12), its accessibility tree, and proposed edits a person can review (§12.2). §13 maps each of Zed's AI features to the system piece that replaces it.

## 2. Goals

- **Never wait.** No keystroke waits on the disk, a language server, Git, the network or a parse. Every slow thing arrives later as an event on the one wait (rule 4, 03 §6).
- **Large is normal.** A 1 GiB log file opens as quickly as a 1 KiB one; a project the size of LLVM is searchable and navigable without an indexing pause.
- **Everything is a file.** Every buffer, selection, diagnostic and command is reachable through `/mnt/hx`, so scripts, agents and other programs drive `hx` exactly as a person does (rule 10, 03 §1).
- **Small core, everything else outside.** The core is text, display and the file server. Language support is data plus a language server; integrations are programs over the files. There are no in-process plug-ins.
- **Keyboard and mouse are equals.** Acme's mouse language, a non-modal keyboard map, and modal maps in the style of vim and Helix are all key bindings over the same commands.

Non-goals: an AI assistant inside the editor; a plug-in runtime (Wasm, JavaScript or a native plug-in ABI); a debugger inside the editor (`dbg` is the debugger, D15); a terminal emulator of its own; an integrated development environment that owns the build.

## 3. What is kept, what is taken, what is left out

| From | Kept or taken | Left out |
|---|---|---|
| **Acme** | The file server (§12); executable text: a middle click, or a key, runs the selected text as a command in the window's directory; a right click plumbs it (07 §7); the tag line as optional, editable command text; `win`-style shell windows (§11) | Mouse-only control; its own window tiling, where `wm` already tiles (§14, question 4); no syntax colouring as a principle |
| **sam** | Structural regular expressions and the command language: addresses, `x`, `y`, `g`, `v`, `s`, `a`, `i`, `c`, `d`, `|`, `<`, `>` (§5) | The separate terminal and host halves; `hx`'s remote editing uses mounts instead (§10) |
| **Zed** | A GPU-drawn interface at the display's refresh rate; anchors that survive edits; multibuffers; tree-sitter; language servers; the fuzzy file finder and project search; Git hunks, staging and blame; remote projects; shared buffers for collaboration; tasks; vim mode | The agent panel, model providers, edit prediction, the context-server protocol, the hosted collaboration service, Wasm extensions, a built-in terminal emulator, a debugger client (DAP) |
| **Helix, Kakoune** | Selection first: a command acts on the current selections, and selections are the result of a sam address or a structural search | — |
| **VS Code** | The piece tree for large files; the language server protocol as the one way to language intelligence | Everything else |

## 4. The text model

- **A buffer is a piece tree.** The file's original bytes are mapped, not read: `fsd` serves them with `Tmap` (01 §5), so opening a file of any size costs one map and no copy. Inserted text goes into an append-only add buffer. A balanced tree of pieces, each pointing into one of the two, carries summaries in every node: bytes, runes and newlines. Finding a line, a byte offset or a rune offset is a walk down the tree, O(log n).
- **Each piece carries the id of the insertion that made it.** That is the structure of Zed's collaborative buffer, so the same tree serves large files and shared editing (§10.2).
- **Bytes, shown as UTF-8.** File contents are bytes and are never checked (00 §1). `hx` shows valid UTF-8 as text and each invalid byte as a visible escape, and it saves every byte it did not change exactly as it was. Cursors and selections move by rune, and by grapheme cluster where the shaper says so (ADR-0013).
- **Anchors.** A position that must survive edits, such as a diagnostic, a bookmark, a collaborator's cursor or a language server's location, is an anchor: an insertion id plus an offset into it. It resolves to a current offset in O(log n), however much text has changed around it.
- **Undo is a tree.** Every change is a node with its parent, so undoing and then typing loses nothing. Changes from outside, such as an agent, a script, a formatter or a collaborator, are separate groups with their source recorded, and can be undone on their own.
- **Saving** writes the whole file to a temporary name and renames it over the old one, so a crash never leaves half a file. If the file changed on disk meanwhile, which `notify` reports (02 §3.3), `hx` shows the difference and asks; it never overwrites silently.

The piece tree, anchors, undo tree and command language (§5) are one host-testable library, `lib/vx-text`, fuzzed like every parser (04 §7). `dbg`'s source view uses it too.

## 5. Commands: sam's language, as selections

Every edit that is not typing is a sam command, and the current selections are its dot:

```
,x/fprintf\(stderr, /c/vx_log(/       every fprintf(stderr, … in the file becomes vx_log(
x/^static int [a-z_]+\(/              select each static int function's opening line, as many selections
y/[ \t]+/                             select the words between the blanks of the current selection
g/TODO/ |fmt                          pipe each selection containing TODO through fmt
.,/^}/                                from here to the next line that is only a closing brace
```

- **Multiple selections are sam's dot with more than one range.** `x` makes them, typing edits all of them, and `Escape` returns to one. The keyboard shortcuts that add a cursor below, or select the next match, are commands that produce the same result.
- **Syntax-aware addresses.** Besides regular expressions, an address can name syntax-tree nodes through tree-sitter queries (§6): `x:function` selects each function, `.:parent` widens the selection to the enclosing node. This is Helix's tree-sitter selection, written in sam's grammar.
- **One command line,** opened with a key, takes sam commands, `hx` commands (`open`, `split`, `save`) and, through the plumber, anything else. The system's command palette (03 §8.4) calls the same commands through `/mnt/hx/ctl`.

## 6. Syntax: tree-sitter

- **tree-sitter's runtime,** a small C library, is vendored (D13). It is the package dependency 06 §3.4 already shows `hx` declaring.
- **A language is a package of data and one generated parser:** the grammar's generated C, compiled to a small shared object or linked into the language package, and its queries (`highlights.scm`, `indents.scm`, `textobjects.scm`, `folds.scm`, `outline.scm`) as text. Adding a language changes nothing in `hx`.
- **Parsing is incremental and never on the frame path.** Each edit is applied to the tree on a `background` thread with a deadline; the frame draws with the last finished tree and repaints the damaged range when the new one arrives.
- **What it drives:** highlighting through the theme's tokens (03 §5.4), indentation, folding, the outline, bracket matching, syntax-aware addresses (§5) and the structure of multibuffer excerpts.
- **Generated parsers are code from a publisher.** They run in `hx`'s process, so they come only from signed packages (06 §5), and the runtime and the grammars `hx` ships are fuzzed with the other parsers (04 §7).

## 7. Language intelligence: `lspfs`

The language server protocol is how editors get diagnostics, completion and navigation, and every language has a server. It is JSON-RPC over pipes, so it follows the rule of 07 §6: **JSON stays at the edge.**

- **`lspfs`** is an adapter file server. It starts a language server, such as `clangd` from the LLVM port (M12), speaks LSP to it, and serves what it learns as files and ndb. One `lspfs` serves one server for one project.
- **Positions are UTF-8.** `lspfs` negotiates `positionEncoding: utf-8` (LSP 3.17) and converts from UTF-16 only for servers that cannot.

```
/mnt/lsp/clangd/
    ctl             open /src/vectra/kernel/kernel.c · change … · shutdown
    status          server=clangd version=22.1.8 state=ready capabilities=hover,definition,…
    diagnostics     one ndb record per diagnostic: file= line= col= severity= code= msg=
    events          diagnostics changed, progress, server messages
    query/
        clone       open → "7"; write "definition file=… line= col=" and read the result as ndb
```

- **`hx` is one client among several.** A script lists the errors with `cat /mnt/lsp/clangd/diagnostics`; an agent finds references through `query/`; `hx` draws squiggles, hover cards, completion menus, inlay hints, rename previews and code actions from the same files.
- **The server runs where the code is.** On a remote project (§10.1) `lspfs` and the language server run on the machine that holds the sources, and only the results cross the network.
- **Formatting** is a language-server request or a command named in the project's tasks (§9), such as `clang-format`. Its result is a proposed edit (§12.2) that `hx` applies as one undo group.

## 8. Projects, search and multibuffers

- **A project is a directory.** Opening it starts a file index, kept current by `notify` (02 §3.3) rather than by rescanning. `.gitignore` and the project's `hx.ndb` say what to leave out.
- **The file finder** matches paths fuzzily against the index on every keystroke.
- **Project search** takes a regular expression or a sam address, runs across the index on `throughput` threads, and streams results as they are found.
- **A multibuffer** is one editable view made of excerpts from many files, each with its context lines and a header naming the file. Search results, diagnostics, references, a rename's changes, Git's changed hunks and an agent's proposed edits (§12.2) are all multibuffers. Editing an excerpt edits the file underneath, through its own buffer and its own undo history.

## 9. Tasks, builds and Git

- **Tasks** are ndb records in the project's `hx.ndb`: `task name=build run="./build all"`, `task name=test run="./build test" errors=clang`. A task runs in a shell window (§11). With an `errors` format, its output's `file:line:col` references become a diagnostics multibuffer. Without one, every such reference can still be plumbed with a click, as in Acme.
- **Git** runs as the Git port (M12), the system's one implementation, never as a second library beside it. `hx` reads the index's version of each open file once, through `git cat-file --batch`, and diffs against it itself on every edit, so changed hunks show in the gutter at once.
- **From the editor:** stage and unstage a hunk, revert it, blame a line, show a commit, switch a branch, and write a commit message in an ordinary buffer. Anything more is the `git` command, in a shell window.

## 10. Remote editing and collaboration

### 10.1 Remote projects

Zed needs a headless server and its own protocol to edit on another machine. Here a remote project is a mount (02 §6):

```sh
import tower /src/vectra /n/tower/vectra      # the sources stay on tower
hx /n/tower/vectra                            # edit them here
```

- File reads and writes go over 9Px, with read leases, so a file once opened is served from the local cache (02 §3.3).
- `lspfs`, the file index and project search run on `tower` through `cpu` (02 §6.5), next to the sources, as 02 §6.6's rule says: move the computation to the data.
- Tasks run on `tower` the same way, and their output comes back to a local shell window.

### 10.2 Shared buffers

- **A buffer can be shared** through `/mnt/hx`. Another person mounts the sharer's buffer with a token (02 §3.4) and opens it in their own `hx`, which keeps a full replica.
- **Edits are operations on insertion ids** (§4), applied in any order with the same result, as in Zed's buffers. No central server is needed, so two people on the same LAN, or across the swarm, edit together with no service in between.
- **Presence is files:** each participant's selections are anchors under `/mnt/hx/N/peers/`, drawn in their colour.
- **Following** a participant moves the view with their cursor across files.
- Voice and screen sharing are outside the editor.

## 11. Shell windows and the terminal

- **A shell window** is Acme's `win`: a buffer whose end is connected to `gsh` through `ptyd`. Output is ordinary text, so it can be searched, edited, executed and plumbed. Commands that do not draw on a screen, which with `gsh` and the system's commands is most of them, work best here.
- **Programs that need a terminal** run in the system terminal, which `hx` can dock beside the buffer. It is the same terminal and the same emulator library, not a second one inside the editor (rule 13).

## 12. The file interface: `/mnt/hx`

`hx` serves Acme's tree, with the same names where Acme had them:

```
/mnt/hx/
    index           one record per window: id, file, dirty, tag
    new/            open → a new window's directory
    ctl             open FILE · project DIR · cmd "sam command" · plumb …
    log             window opened, closed, saved
    N/
        body        the whole text
        addr        write a sam address; data and xdata then read and write that range
        data, xdata
        ctl         clean · dirty · show · dot=addr · name FILE · get · put · undo · redo
        tag         the tag line
        event       Acme's events: keys typed, text executed or looked up, by whom
        sel         the current selections, one record per range, as ndb
        syntax      the tree-sitter tree at a byte range, as ndb nodes
        diag        this file's diagnostics, from lspfs
        propose/    proposed edits (§12.2)
        peers/      collaborators' selections (§10.2)
```

### 12.1 Who sees it

As with `/wsys` (03 §5.7), a global `/mnt/hx` would let any program read every open buffer. So a program sees only what it is given:

- An app or script started from `hx`, such as a task or a command run by clicking it, gets its window's own directory, as Acme's `$winid` gave.
- An agent gets one window or one project's windows, by its namespace template (02 §7), and nothing else.
- The whole tree is held by `hx` and by programs the user starts with the grant, as the palette holds `/wsys`.

### 12.2 Proposed edits

A program that wants to change a buffer the user is looking at can write to it directly, through `addr` and `data`, or **propose** the change instead:

```
echo 'from=clang-format' > /mnt/hx/7/propose/new       # → "3"
cat edits.diff            > /mnt/hx/7/propose/3/diff   # or ndb records: addr= text=
```

`hx` shows each proposal as a diff in place, or as a multibuffer when it spans files, with its source. The user accepts or rejects it whole or a hunk at a time, and an accepted proposal is one undo group. Formatters, code actions, refactoring tools, a collaborator's suggestion and an agent all use it. It is not an AI feature: it is how the editor takes changes it did not make itself.

## 13. Zed's AI features, and what replaces each

| Zed | VectraOS | Where |
|---|---|---|
| Agent panel: a chat that reads and edits the project | An agent started with a namespace template: `/mnt/hx` for the project's windows, the project through `auditfs`, its own `aid` session. Its edits arrive as proposals (§12.2); its file writes are logged and undoable | 02 §7, 03 §8.5 |
| Model providers and API keys | `/ai/providers`, with keys in `keyd`, attached by `tlsd` | 03 §8.6 |
| Edit prediction, inline completion | Inline assist in `vxui` text areas, which `hx`'s buffer implements, routed by the policy's `task=completion` rule | 03 §8.4 |
| Inline transform of a selection | The same inline assist, on the selection | 03 §8.4 |
| Context servers (MCP) | Mounts: an agent's context is what its namespace holds, and its tools are files | 02 §7 |
| Rules files, project context | Context pools in `/ai/ctx`, filled from the project by the user's choice | 03 §8.1 |
| Reviewing an agent's changes | `auditfs`'s action log, and proposals in `hx` | 03 §8.5, §12.2 |
| "Explain this code" | The assistant reads the window's accessibility tree, which includes the selection and the syntax node around it | 03 §8.4 |

`hx` links no model runtime, holds no key, opens no network connection and contains no prompt. If `aid` is not installed, nothing in `hx` is missing; only the system's assist is.

## 14. The interface

- **A `vxui` app** (03 §6): one wait, immediate mode, frames only when something changed, and the glyph atlas the terminal uses, so a screen of text after a keystroke costs a few textured quads.
- **One window per project,** split inside into columns and rows as Acme and Zed both do, because splits share selections, the command line and the project. Any view can be torn out into a toplevel of its own, which `wm` then places.
- **Key maps are data:** ndb records, as `wm`'s bindings are (03 §5.3). `hx` ships three: a non-modal map close to Zed's defaults, a vim map, and a Helix map, plus Acme's mouse chords, which work in all three. A modal map is a set of bindings with a `mode`, as in `wm`; there is no second key-handling path.
- **Accessibility:** the buffer publishes its visible lines, selections, diagnostics and the syntax node at the cursor through `/wsys/windows/N/a11y` (03 §5.6).
- **The theme** comes from `/wsys/theme` tokens; syntax highlight names map to tokens, so a system theme change recolours code too.

## 15. Budgets

Added to 00 §8 when the milestone that makes each measurable lands:

| Budget | Target |
|---|---|
| Keypress to glyph in a buffer | Drawn within 1 ms of the key event, on screen within 2 frames, as the terminal (00 §8) |
| `hx` cold start to an editable file on screen | < 50 ms, the app cold-start budget |
| Open a 1 GiB file to its first screen | < 100 ms; line count completed in the background |
| A keystroke's incremental re-parse in a 10,000-line C file | < 1 ms, off the frame path |
| A `,x/re/c/…/` over 1 million lines | < 1 s |
| Fuzzy file finder over 200,000 paths, per keystroke | < 8 ms |
| Project search for a literal over the LLVM source tree, warm cache | < 1 s to the last result |
| Resident memory with the VectraOS tree open and five files visible, without language servers | < 64 MiB |
| Idle, with a project open and nothing changing | 0 wake-ups per second |

## 16. Where the pieces land

| Milestone | Pieces |
|---|---|
| **M7 Pixels** | `lib/vx-text`: the piece tree, anchors, the undo tree and sam's command language, host-tested and fuzzed; `dbg`'s source view on it |
| **M8 GPU** | `hx` v0: editing, multiple selections, the command line, shell windows, plumbing (07 §7), `/mnt/hx` with Acme's files, key maps; tree-sitter vendored, with C, Lua, ndb and Markdown grammars |
| **M12 Self-hosting** | `lspfs` and `clangd`; Git; tasks; project search and the file finder; multibuffers; proposals; remote projects. The exit test: VectraOS is developed in `hx` on VectraOS |
| **After M12** | Shared buffers (§10.2); grammars and language servers for other languages, each a package |

## 17. Heritage

| Taken from | What | Changed |
|---|---|---|
| Acme | The editor as a file server; executable text; plumbing; `win` | Keyboard maps beside the mouse; syntax awareness; per-program views of the tree (§12.1) |
| sam | Structural regular expressions and the command language | Dot is many selections; addresses can name syntax nodes |
| Zed | GPU drawing at refresh rate, anchors, multibuffers, insertion-id buffers for collaboration, remote projects | Remote projects are mounts; collaboration needs no hosted service; no AI inside |
| Kakoune, Helix | Selection-first editing; tree-sitter selection | Written as sam addresses |
| VS Code | The piece tree; the language server protocol | The tree over a mapped file; LSP behind a file server |
| tree-sitter | Incremental parsing and queries | Unchanged |
| vim | The modal key map | A key map like any other, over the same commands |

## 18. Open questions

1. **Piece tree or rope.** A piece tree over the mapped file opens large files instantly; a rope (Zed's) is simpler to make persistent for snapshots taken by background threads. Benchmark both inside `lib/vx-text` on the §15 budgets before M8.
2. **Generated parsers in-process.** Grammar packages are native code inside `hx`. The alternative is a parse server process per language, which confines a bad grammar but puts a round trip on every edit. Measure the round trip over a local ring before deciding.
3. **Git as a library or a file server.** 9front's `git/fs` serves a repository as files, which fits the system better than parsing `git` command output; but it is a second implementation beside the Git port. Start with the port's commands.
4. **Splits inside `hx` or windows under `wm`.** If each view were a toplevel, `wm` would tile them and nothing would be duplicated, but views would lose the shared command line and selections. Revisit once `wm` has tab groups.
5. **How much of vim.** A map that covers motions, operators, text objects, registers and macros is large; `:` commands map onto sam's language only in part. The map is data, so it can grow; the question is what v1 promises.
6. **The name.** `hx` is also Helix's command. It matters only to someone who ports Helix into their own user land, and a namespace binds either one at `/bin/hx`.
