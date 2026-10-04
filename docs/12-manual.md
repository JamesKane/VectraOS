# Phase 12 — The manual

_Blueprint v0, 2026-10-03. The format (§4), the sections (§3) and the coverage rule (§7) are fixed by ADR-0028, accepted 2026-10-04; the rest is rewritten against the code it produces (§11, M6 step 6a)._

## 1. The position

**The system is documented by its manual, as Unix and Plan 9 are.** Every program, library function, system call, device, file server, protocol message and file format has a page. A page says what *is*: the behaviour of the code in the same release. The blueprint (docs 00–11) says why and what is intended; once a piece ships, its page is the authority on what it does, and the blueprint points to it.

**Plan 9's manual is the baseline.** It is kept whole: eight numbered sections, each opened by an `intro` page; one page per command or per group of related functions; the fixed headings NAME, SYNOPSIS, DESCRIPTION, EXAMPLES, FILES, SOURCE, SEE ALSO, DIAGNOSTICS and BUGS; references written `name(section)`; `man`, `lookman` and `sig`; and plumbing, so that `rc(1)` in any window opens the page. Its tone is kept too: short, exact, and honest in BUGS.

**AmigaGuide shows what Plan 9's manual lacked.** An AmigaGuide database was one file of *nodes* joined by links, read in a viewer with Contents, Index, Help, Retrace (back) and Browse (previous and next) buttons. A long page could be split into nodes a reader could jump between, and every reference was a button. Plan 9's pages are troff: they print beautifully, but a reference is only italic text, a long page such as `rc(1)` is one scroll, and nothing but `troff` can read the source.

**This manual is Plan 9's manual written in a modernised AmigaGuide.** The format, **guide** (§4), is plain UTF-8 text that reads well with `cat`, holds nodes and links as AmigaGuide did, and keeps its structure as data, so the build can check every page against the code it documents (§7). It drops what made AmigaGuide unsafe or dated: links that ran commands, fonts and colours chosen by the author, and macros.

## 2. Goals

- **Complete.** Everything a person, script or agent can call, read, write or configure has a page. The build fails when something new has none (§7).
- **True.** A page is checked against its code where a machine can check it: usage messages, C declarations, `ctl` verbs, files and manifest keys. The manual installed on a node always matches the release it runs, because both are one tree (06).
- **Plain text first.** The source is the page. `cat`, `grep`, `hx` and an agent read it with no renderer, and a terminal on a serial line shows it well (§6.1).
- **Hypertext when there is a screen.** `hv` shows a page with live links, a contents list, the index, back, and browsing node by node (§6.2).
- **One parser.** Every reader of the format uses `lib/vx-guide`: `man`, `hv`, `build`, the search index. Nothing else parses a page.
- **Small.** The grammar fits on one screen (§4.6); the parser is a few hundred lines, host-built and fuzzed (04 §7).

Non-goals: typesetting and print layout (a page prints as its terminal rendering); images (diagrams are preformatted text, as in this blueprint); author-chosen fonts, colours or layout; anything executable inside a page; translations in v1 (§12, question 3).

## 3. The sections

Plan 9's eight sections, with the same meanings except section 7, which Plan 9 barely used (five pages in 9front) and which here holds the concept pages Plan 9 kept as papers in `/sys/doc`.

| Section | Contents | Examples | Checked against (§7) |
|---|---|---|---|
| **1** | Commands a user runs, `gsh`/rc builtins included, and host tools (marked `host`) | `cat(1)`, `rc(1)`, `hx(1)`, `dbg(1)`, `build(1)` | The usage message, generated from the page |
| **2** | Library functions and system calls: `libvx`, `vxui`, the public `lib/vx-*` libraries, the syscalls, the Lua APIs (marked `lang=lua`) | `open(2)`, `port(2)`, `ring(2)`, `ndb(2)`, `wm(2)` | Declarations in the installed headers |
| **3** | Devices: one page per driver class and its tree under `/dev`, one per driver | `cons(3)`, `block(3)`, `accel(3)`, `drv-virtio-blk(3)` | `.schema`, driver manifests |
| **4** | File servers: what each serves, its files and `ctl` verbs | `fsd(4)`, `netd(4)`, `procfs(4)`, `plumber(4)`, `aid(4)` | `.schema`, service manifests |
| **5** | Protocols: one page per 9Px message, as Plan 9's section 5 has one per 9P message, plus the ring layout | `intro(5)`, `walk(5)`, `map(5)`, `notify(5)`, `ring(5)` | `abi/` and `vx-9p`'s message table |
| **6** | File formats and conventions | `ndb(6)`, `namespace(6)`, `plumbing(6)`, `guide(6)`, `svc(6)`, `utf(6)`, `vxfs(6)` | The parsers' key tables |
| **7** | Concepts: what a reader needs before the reference pages make sense | `namespace(7)`, `intents(7)`, `rings(7)`, `swarm(7)`, `notes(7)` | — |
| **8** | Administration: booting, services, installing, updating, storage | `svcd(8)`, `devmgr(8)`, `partd(8)`, `fs(8)`, `distd(8)` | As section 1, 3 or 4 |

A page documents a group of names that belong together, as `open(2)` covers `vx_open`, `vx_create` and `vx_close`. Every name in the group is indexed (§5), so `vx_create(2)` and `open(2)` are the same link.

## 4. The format: guide

A page is one UTF-8 file. It has a header, then a body of lines. Each body line's kind is decided by how it begins, as in gemtext, so a reader never needs more than the current line and whether it is inside a fence.

### 4.1 A page

````
page=cat sect=1 summary="concatenate files"
    names=cat
    src=cmd/cat.c

# SYNOPSIS

```usage
cat [-u] [file ...]
```

# DESCRIPTION

`cat` reads each <file> in order and writes it to standard output. With no
<file>, or with a <file> of `-`, it reads standard input. Data is copied as
bytes and never checked: see {text and bytes|utf(6)#bytes}.

: `-u`
  Write each read as it arrives, without collecting full blocks.

# EXAMPLES

```rc
% cat /proc/1/status
```

# SEE ALSO

tail(1), read(2)

# DIAGNOSTICS

The exit string is the first error met, such as `cat: /x: file does not exist`.
````

`man cat` prints NAME from the header (`cat — concatenate files`), the sections in order, and SOURCE from `src=`. The author never writes NAME or SOURCE.

### 4.2 The header

The header is ndb records (D14), ended by the first blank line. One record, its first tuple `page=`:

| Key | Meaning |
|---|---|
| `page` | The page's name: lower case, `[a-z0-9][a-z0-9._+-]*`. Also its file name, `/lib/man/<sect>/<page>` |
| `sect` | `1`–`8` |
| `summary` | One line for NAME and the index; no full stop, as Plan 9's |
| `names` | Every name the page documents. Defaults to `page`. Each is an index entry and a link target (§5) |
| `src` | Repository paths for SOURCE: the files a reader opens to see the code |
| `lang` | `c` (the default in section 2), `lua` or `rc` |
| `level` | Section 2: the ABI level that introduced the page's names (09 §4.8) |
| `host` | Flag: a tool that runs on the development host, not on VectraOS |
| `keys` | Extra index words for `lookman` |

A key the parser does not know is an error, so a typo never passes silently (02 §4.1).

### 4.3 Nodes

A page is one node unless it says otherwise. A line starting with `@` holds one ndb record, and `@node=` starts a new node:

```
@node=quoting title="Quoting" keys=quote,escape
```

- Text before the first `@node` is the **main node**, which every page has. It holds SYNOPSIS and DESCRIPTION.
- A node's `node=` is its id, unique in the page, `[a-z0-9-]+`; `title` is what Contents shows.
- **Reading order is file order.** `man rc` prints every node, so a page split into nodes still prints, greps and pipes as one text. `man rc quoting` prints one.
- **Use nodes for long pages:** `rc(1)`, `hx(1)`, `dbg(1)` and a large server such as `aid(4)`. A short page has none.
- `@node` is the only directive in v1. A new directive is a new format version (§4.7).

### 4.4 Blocks

| A line that starts with | Is |
|---|---|
| (blank) | The end of a paragraph, list item or definition |
| `# ` | A section heading. Plan 9's headings, in capitals and in Plan 9's order; any other heading is the author's own, in capitals too |
| `## ` | A subsection heading, in sentence case |
| `- ` | A list item |
| `: ` | A definition term: a flag, a file, a `ctl` verb, a key. The indented lines after it are its description (Plan 9's `.TP`) |
| two spaces | A continuation of the list item or definition above (as ndb's indented lines continue a record) |
| `\|` | A table row. The first row of a run is the header |
| three backticks | A fence: lines up to the next fence are shown exactly as written. The word after the opening fence is its kind (§4.5) |
| `@` | A directive (§4.3) |
| anything else | Paragraph text. Lines are joined and refilled to the reader's width |

There is no nesting: a list item holds no list, a definition holds no fence. A page that wants more structure wants a node.

### 4.5 Fences

| Kind | Holds | Checked |
|---|---|---|
| `usage` | A command's synopsis, Plan 9's notation: the command and its flags literal, every other word a parameter, `[ ]` optional, `...` repeated | It *is* the usage message: `build` generates the program's `usage` constant from it (§7) |
| `c` | C declarations, in SYNOPSIS of section 2; or example code | In SYNOPSIS, each declaration must match the installed header, after formatting |
| `rc` | A transcript or script. Lines starting `% ` are typed; the others are output | Parsed by `lib/vx-rc` (§12, question 2) |
| `ndb` | ndb records | Parsed by `vx-ndb` |
| `lua` | Lua | — |
| `text`, or none | Anything: diagrams, tables of bytes | — |

### 4.6 Text inside a line

Only four things are special in paragraph text, list items, definitions and table cells:

| Written | Is | Shown in a terminal | Shown by `hv` |
|---|---|---|---|
| `` `cat -u` `` | Literal: what is typed, file names, code, verbs (Plan 9's `B` and `L` fonts). A span opened by *n* backticks closes at the next *n* | As written, without the backticks | Monospace |
| `<file>` | A parameter: `<` then a letter, then letters, digits, `.`, `_` or `-`, then `>` (Plan 9's `I` font) | `<file>` unchanged | Italic, without the brackets |
| `rc(1)` | A link to a page: any indexed name followed by a section number in parentheses | As written | A link |
| `{label\|target}` or `{target}` | A link with its own words, or to a node, or out of the manual | `label (target)` | A link showing `label` |

Link targets are `name(N)`, `name(N)#node`, `#node` for a node of this page, or a URL with a scheme `hv` understands (`https:`, `gemini:`, `gopher:`). Nothing else is special, so nothing else needs escaping: a literal `{`, a `<word>` that is not a parameter, or a `name(2)` that is not a link goes inside backticks. There is no emphasis markup; Plan 9's pages manage without, and a parameter is what they used italics for.

### 4.7 Versions

The format is versioned as a protocol is (rule 9). Version 1 is the grammar above, published as `guide(6)`. A page may start with `@guide=2` once a version 2 exists; with no such line it is version 1, permanently. The parser rejects what it does not know rather than guessing, so an old `man` meets a newer page with a clear error, never a wrong rendering.

## 5. Where pages live, and the index

- **In the repository**, pages are `man/<sect>/<page>`, mirroring the installed tree, as Plan 9's `/sys/man` does. A change to behaviour changes its page in the same commit; the coverage check (§7) makes the commit fail otherwise.
- **Installed**, the release tree holds `/lib/man/<sect>/<page>`. A package (06 §3.3) carries its own `lib/man/`, and its namespace template binds it after the base, as `/bin` is a union: `bind -a /dist/pkg/<p>/lib/man /lib/man`. A user's own pages in `$home/lib/man` are bound the same way. There is no `MANPATH`: the namespace is the search path.
- **The index** is `/lib/man/index/`, a directory with one ndb file per tree (`base`, one per package, `home`), so the union of the trees is the union of their indexes. `build` writes `base`; `distd` writes a package's at install. One record per name:

```
name=vx_create page=open sect=2 summary="open, create or close a file"
name=quoting page=rc sect=1 node=quoting title="Quoting"
```

- **Links resolve through the index.** `vx_create(2)` finds `open(2)`. The build fails on a link in the base manual that resolves to nothing; `man` shows a dangling link in a package's page as text, and says so.
- **Old manuals are free.** The release tree is content-addressed and the dump keeps dated trees (11 §9), so the manual of last month's system is `/n/dump/…/lib/man`, matching last month's binaries.

## 6. Reading

### 6.1 `man`, `lookman` and `sig`

```usage
man [-tw] [section ...] title [node]
lookman key ...
sig name ...
```

- **`man`** prints the page `title`, or one node of it, in the first section that has one, refilled to the width of `/dev/cons` (80 columns when it has none), indented as Plan 9's are. Links print as written, so `rc(1)` in the output is still something the plumber recognises. `-t` prints the contents: the nodes and headings. `-w` prints the path instead.
- **There is no pager,** as in Plan 9: the terminal scrolls, and `hv` pages.
- **`lookman`** prints the pages whose names, summaries or `keys` hold every `key`, one line each, from the index.
- **`sig`** prints the C declarations of the named functions from section 2's SYNOPSIS fences, for pasting into code, as Plan 9's does.
- **`./build man <title>`** runs the same code on the development host, so the manual can be read before an image boots.

### 6.2 `hv`: the manual as hypertext

`hv` renders guide natively, as it renders gemtext and Markdown (07 §4.4), with AmigaGuide's controls:

| AmigaGuide | Here |
|---|---|
| Contents | The page's nodes and headings, beside the text |
| Index | `/lib/man/index`, searchable, across every installed page |
| Help | `man(1)` |
| Retrace | Back and forward, as for any document |
| Browse < > | The previous and next node; past a page's last node, the next page of its section, so a section reads like a book |
| Buttons | Links. They open pages, nodes or URLs, and never run anything |

- **Plumbing opens it.** A rule in the default `plumbing` sends any text matching `name(N)` to `hv` with `/lib/man/N/name`, so `rc(1)` in a terminal, in `hx`, in a chat message or in another page opens the page, as Plan 9 opens a page from Acme.
- **Examples are text the reader may take.** An `rc` fence offers to plumb its typed lines to a terminal, where the reader runs them, or not. AmigaGuide's `system` and `rx` links, which ran commands from the page, have no counterpart.
- **The page is an accessibility tree** (07 §5.1), so a screen reader and an agent read the same nodes and links.
- **`hv`'s namespace** gains `/lib/man`, read-only. Nothing else changes in its confinement (07 §8).

### 6.3 Agents and scripts

The manual is files, so it needs no tool of its own. An agent's namespace template may bind `/lib/man` read-only (02 §7); the header and the fences give it a page's names, synopsis and declarations as data, without scraping prose. `.schema` remains the machine-readable contract for a service (02 §4.2); the page is the explanation.

### 6.4 `.help`

Rule 10 has every service directory serve `.help`. It is **generated from the service's page**, by `build` into the server's binary: the summary, then each FILES and CTL definition's first sentence, then a line `see fsd(4)`. `.schema` stays generated from the server's `ctl` table (09 §5.11). So the text a person reads in `.help` and in the manual cannot drift apart, and `.schema` and the page are checked against each other (§7).

## 7. Complete and true: the coverage check

`./build check` gains a manual pass, run with the others (04 §3.2). It parses every page with `lib/vx-guide` and then checks:

| What | Must have | Compared with |
|---|---|---|
| Every program in the image's `/bin` and `/boot/bin`, and every host tool | A section 1 or 8 page | The page's `usage` fence *becomes* the program's usage message: `build` generates a `usage` constant per program, so the two cannot differ |
| Every function, macro and type declared in an installed header | A section 2 page naming it | Its declaration in the SYNOPSIS fence, normalised by the house formatter (04 §1.1) |
| Every syscall in `abi/vx/abi.h` | A section 2 page naming it | The same |
| Every server and driver | A section 3, 4 or 8 page | Each FILES and CTL term against `.schema`: every verb and file documented, none invented |
| Every 9Px message and ring field | A section 5 page | `vx-9p`'s message table; `abi/`'s layout |
| Every manifest and configuration key | A definition in the format's section 6 page | The parser's key table (`vx-ndb` key lists) |
| Every link in the base manual | A target | The index |
| Every page | To parse, and to fit 80 columns in its fences | — |

**The backlog is a ledger that only shrinks.** M1–M5 shipped with no pages. `man/missing` lists what is undocumented today, one ndb record each (`kind=syscall name=port_wait`). The check fails on anything undocumented that is not on the list, and on anything on the list that now has a page, so the list can only get shorter, as the line-count ledger can only be argued with (04 §3.2). The milestone that closes the list is the one that says "fully documented" (§11).

**What is not checked** is the prose: whether DESCRIPTION is right. That is review's job, and a page is reviewed with the code it describes, in the same commit.

## 8. Writing a page

- **Plan 9's voice.** Present tense, third person, about the program not the reader: "`cat` reads each `<file>`". Say what it does, what it does not, and its limits; put known defects in BUGS rather than leaving them for the reader to find.
- **SYNOPSIS is exact,** DESCRIPTION complete, EXAMPLES real: copied from a session, not invented.
- **One page per thing a reader looks up.** Group functions a caller uses together (`open(2)`), split commands a user thinks of separately.
- **Link the first mention** of another page in a paragraph, not every one.
- **Short lines in fences.** A fence is shown as written, so it must fit 80 columns; paragraphs may be any length, one sentence per line keeps diffs readable.
- **House-checked:** `./build check` refuses trailing spaces, tabs outside fences, and headings out of Plan 9's order, as the formatter refuses bad C (04 §1.1).

## 9. Budgets

| Budget | Target |
|---|---|
| `man` on a page from cache to the last byte on the console | < 5 ms for `rc(1)` |
| Parse the whole base manual (`build`'s check pass) | < 200 ms on the workstation, inside the build-time budget (04 §3.2) |
| `lookman` over every installed page's index | < 10 ms |
| `lib/vx-guide`, parser and text renderer | < 1,500 lines, counted by the ledger |
| The base manual's size in the image | Reported by `./build loc`; plain text compresses well and needs no budget of its own yet |

## 10. What the format is not

| Rejected | Why |
|---|---|
| **troff with `-man`** (Plan 9) | A typesetter, a macro language and a second program to port for what is mostly paragraphs and lists. References are only fonts, so nothing can follow or check them, and the source is hard to read raw. The conventions are kept; the language is not (ADR-0028) |
| **mdoc** (BSD) | Semantic and checkable, which is right, but still roff: the source is macros, and it needs `mandoc` |
| **Markdown** | Its grammar is large and ambiguous (emphasis, nesting, HTML blocks), and the dialects disagree. It has no nodes, no header data and no notion of a page reference. `hv` still renders it for documents from outside (07 §4.4), which are not the manual |
| **AmigaGuide unchanged** | `@{"label" link node}` markup is noisy to read raw; its `system` and `rx` links ran commands; authors chose fonts and colours; no structure a build could check |
| **Texinfo and `info`** | Nodes and menus, the nearest relative, but a large language whose tools are Perl, and an `info` reader nobody enjoys |
| **HTML** | A document format the system shows from outside (07), not one to write a manual in: verbose to read raw, and checking it means a DOM |

guide is a new format, which 00 §7 asks to avoid for GUI markup. It is not one: it describes no interface, and it replaces troff in the manual, where Plan 9 had a format of its own too. Its grammar is §4.6's tables and nothing more.

## 11. Where the pieces land

| When | Pieces |
|---|---|
| **ADR-0028** | The format (§4), the sections (§3) and the coverage rule (§7), proposed with this document |
| **M6 Runtime, first step** (proposed) | `lib/vx-guide` (host and target, fuzzed); `man`, `lookman`, `sig` and `./build man`; the index; the coverage pass with `man/missing` holding all of M1–M5; generated usage constants; `guide(6)`, `man(1)` and the eight `intro` pages first |
| **Every step after** | New code arrives with its pages; the step's commit removes from `man/missing` whatever it touched |
| **M7 Pixels** (proposed) | A first `hv` for local documents only, guide and plain text, with no `webfs` and no web engine; the plumbing rule for `name(N)`; `.help` generated from pages |
| **M15 Hypermedia** | `hv` gains the web (07 §12); the manual needs nothing more |
| **The milestone that empties `man/missing`** | "Fully documented" becomes an exit criterion that stays: from then on, the check has no list |

## 12. Heritage

| Taken from | What | Changed |
|---|---|---|
| Unix, Plan 9 manual | Numbered sections with `intro` pages; fixed headings; `name(N)` references; terse present-tense pages; BUGS | Section 7 holds concepts; the source is guide, not troff; references are links |
| Plan 9 `man`, `lookman`, `sig` | Reading, finding and quoting declarations | Rendering and the index come from one library; `man` takes a node |
| Plan 9 plumbing | `rc(1)` in any text opens the page | Opens `hv` |
| AmigaGuide | A page as nodes and links; Contents, Index, Help, Retrace, Browse | Readable raw; links never run commands; no author fonts or colours; checked by the build |
| gemtext | A line's kind decided by its first characters; no nesting | Definitions, tables and fence kinds |
| mdoc | Semantic markup a tool can check | Checked against code, not only for form |
| Go doc, Rust doctests | Documentation tested by the build | Synopses and declarations checked, usage generated; examples later (§13, question 2) |

## 13. Open questions

1. **When to start.** §11 proposes the first step of M6. It could instead be a step at the end of M5, so that M5's own servers (`fsd`, `partd`) are documented as they are finished, not added to the backlog.
2. **Running the examples.** `rc` fences could run in the QEMU test matrix with their output compared, as doctests are, which would keep EXAMPLES true. It needs examples written to be reproducible (no pids, no times) and costs test time; decide once the backlog is small.
3. **Translations.** UTF-8 makes any language writable. A translated page could live at `/lib/man/<lang>/<sect>/<page>`, bound over the English one by the session's template. Whether the project ever maintains translations is a question for later.
4. **Lua and rc APIs.** §3 puts them in section 2 with `lang=`. If there come to be many, they could take sections of their own (`2lua`), as other systems have done.
5. **Kernel internals.** Plan 9 documented its kernel's internal interfaces in section 9 in some editions. Here the kernel is small and its interfaces are its syscalls, so nothing is planned; driver writers use `lib/vx-driver`, which is section 2.
6. **`hv` at M7.** §11's local-only `hv` moves part of 07 §12 forward. Without it, the manual has no hypertext viewer until M15, and the terminal rendering serves alone.
