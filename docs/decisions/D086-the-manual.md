# D86. The system is documented by its manual: Plan 9's sections, NeoVectra's guide format, headers as directives (2026-10-17, proposed)

VectraOS has no manual. What a program, call, service or format does is
in its code, in its decision and in `docs/`, which say why and what was
intended, and are read on the dev machine. Nothing on a running node
tells its user what `ls -m` does or what `/svc/launcher/ctl` takes, and a
node at a bench or on a desk may have no network. The owner's direction
(2026-10-16): the system is documented without needing the internet, as
Plan 9's is, after NeoVectra's design (its `docs/12-manual.md` and
ADR-0028, built in its M6 with 238 pages).

- **A page says what is.** Every program, library call, syscall,
  protocol, service tree, device directory and file format has a page,
  true of the code in the same tree. `docs/` keeps the why; once a piece
  ships, its page is the authority on what it does, and its design note
  points there. A change to behaviour changes its page in the same
  commit.
- **Plan 9's manual, kept whole:** eight sections, each opened by an
  `intro` page; one page per command or group of related calls; the
  headings NAME, SYNOPSIS, DESCRIPTION, EXAMPLES, FILES, SOURCE, SEE
  ALSO, DIAGNOSTICS and BUGS, in that order; references written
  `name(N)`; `man`, `lookman` and `sig`; and its voice: present tense,
  short, exact, honest in BUGS. Section 7 holds concepts (namespaces,
  rings, handles, the launcher), Plan 9's `/sys/doc` papers' place.

  | Section | Holds | Checked against |
  |---|---|---|
  | 1 | Commands, rc's builtins, and host tools (`vx`, `td`, `idlc`, marked `host`) | The program's usage message |
  | 2 | Sys, libc, the syscalls | Public Swift declarations; installed C headers |
  | 3 | Device directories and drivers (D82): `/dev/kbd`, `/net/etherN`, `drv-virtio-input` | The tree the driver serves |
  | 4 | Services' trees: `launcher(4)`, `kbdfs(4)`, `bootfs(4)`, `pty(4)` | The tree the service serves |
  | 5 | Protocols: each IDL protocol (generated), 9P2000's messages (V3, D78), the ring | idlc's model; the codec's message table |
  | 6 | Formats: `manifest(6)`, `driver(6)`, `guide(6)`, `wire(6)`, `trace(6)`, `bootfs(6)` | Each parser's directive table |
  | 7 | Concepts | — |
  | 8 | Administration: the launcher, devmgr, booting, `vx boot --cpu` | As 1, 3 or 4 |

- **The format is NeoVectra's guide** (its 12 §4), plain UTF-8 that reads
  well with `cat`, in its body unchanged: a line's kind decided by how it
  begins (`# ` and `## ` headings, `- ` items, `: ` definitions with
  indented continuations, `|` tables, fences with a kind, `@node=` nodes),
  no nesting, and four inline forms (`` `literal` ``, `<param>`,
  `name(N)`, `{label|target}`). Long pages split into AmigaGuide's nodes,
  which `man rc quoting` prints alone; `man rc` prints them all. Links
  never run anything. The format is versioned (`@guide=N`), and what the
  parser doesn't know it refuses with file and line.
- **The header is directives, as the manifests are,** not NeoVectra's ndb.
  This tree has one text format for records: Plan 9's namespace-file
  style, one directive a line, words split at spaces and tabs, `#`
  comments, an error stopping with file and line (the launcher's
  manifests, drivers' `driver.manifest`). A page's header is the same,
  ended by the first blank line:

  ```
  page ls 1
  summary list contents of directory
  names ls lc
  src shell/commands/lib/Commands.swift
  keys directory listing
  ```

  `page NAME SECTION` comes first; `summary` takes the rest of its line;
  `names`, `src` and `keys` take words and may repeat; `host` and
  `lang swift|c|rc` are flags. An unknown directive is an error.
- **One directive reader.** The launcher and devmgr each carry a copy of
  the same line and word splitter (`Manifest.swift`'s `lines` and
  `words`, `Index.swift`'s); the manual would be a third. They become one,
  taking a table of the directives a format accepts, so section 6's pages
  are checked against those tables.
- **Tables are TSV,** as `IMPORTS.tsv`, `docs/hardware/support.tsv` and
  `bench/history` are. The index is `lib/man/index`, one row a name:
  `name page section node summary`. `vx` writes it, and links resolve
  through it, so `lc(1)` finds `ls(1)`.
- **One parser,** `system/guide` (Swift, tier 0 and host), which `vx`,
  `man`, `lookman`, `sig`, idlc and a later viewer all use; nothing else
  reads a page. It meets tier 0's rules (no Set or Dictionary, no key
  paths, bytes compared as bytes).
- **Budgets:** the parser and renderer under 1,500 lines (`vx loc`, from
  the change that lands them); `man rc` from bootfs to its last byte on
  the console under 5 ms (a boot `budget` line); the check pass over the
  whole manual under 200 ms on the dev machine. The two timings are
  judged with V3's exit, with the bench.
- **Pages live in `man/<section>/<page>`,** and bootfs carries them at
  `lib/man/` with the index (D71); a manifest mounts `/lib/man
  bootfs/lib/man` as it mounts `/bin`. The manual on a node is always the
  one for the code it runs, because both come from one tree. `vx man
  TITLE` reads it on the dev machine before an image boots.
- **The manual is checked against the code,** by `vx man --check`, which
  `vx ci` runs:
  - Every program in bootfs's `bin/`, and every `vx` command, has a page
    in section 1 or 8. Programs' usage messages are generated from the
    page's `usage` fence, so the two can't differ.
  - Every public declaration of Sys, every syscall and every libc header
    declaration is named by a section 2 page, its SYNOPSIS fence
    (`swift` or `c`) matching the declaration. The Swift side is read
    with swift-syntax, already the host's for idlc (D4).
  - Section 5's IDL pages are generated by idlc from the protocol's
    model, as its Markdown pages (`services/pty/idl/*.md`) are now; the
    Markdown is replaced, not kept beside (principle 1). Their prose
    comes from the protocol's doc comments.
  - A suite (D20) walks each service's and driver's exported tree on the
    booted image and compares its names with the page's FILES
    definitions: every file documented, none invented.
  - Every link resolves; every page parses; fences fit 80 columns; no
    trailing spaces, and headings in Plan 9's order.
- **The backlog is a list that only shrinks.** `man/missing` holds, one
  TSV row each, what has no page when the check lands: all of V0 to V2.
  The check fails on anything undocumented not on it, and on anything on
  it that now has a page. A link may name a page the list promises.
- **Every step after writes its pages,** and its commit takes what it
  touched off the list. A milestone's exit includes its own pages.
- **NeoVectra's pages are a source, not an import.** Its concept pages
  (section 7), intros, `guide(6)` and `man(1)` are rewritten for this
  tree (`docs/provenance.md`); its pages for code that lost (vxui, Lua,
  vx-fs, sbase, musl, 9Px) are not carried. No file is lifted
  byte-identical, so `IMPORTS.tsv` gains no row.

Not chosen:
- **ndb headers,** NeoVectra's: there, ndb was every configuration
  file's format. Here it would be a second record format beside the
  manifests' directives.
- **Markdown,** which `docs/` and idlc's pages use: its grammar is large
  and its dialects disagree, it has no page header and no notion of a
  page reference, and a device-side reader would be a large parser.
  `docs/` stays Markdown, read on the dev machine.
- **troff or mdoc** (Plan 9, BSD): a typesetter and macro language to
  port for paragraphs and lists, unreadable raw, and references that are
  only fonts, which nothing can check or follow.
- **Pages generated wholly from code,** DocC's way: they cover APIs, not
  commands, trees, formats or concepts. Where the code is the contract,
  section 5's protocols, they are generated.
- **NeoVectra's `hv`:** its viewer belongs to its UI, which Radharc
  replaces. A viewer with AmigaGuide's Contents, Index, Retrace and
  Browse comes with the desktop (V5), and the plumber's rule for
  `name(N)` (D85) with it.
- **`.help` per service and `.schema` checks** (NeoVectra's 12 §6.4):
  this tree has neither. A service's FILES are checked against its live
  tree instead.

Amended with V2 step 9a (2026-10-17): the body's two directives are
directives too, `@node ID TITLE` and `@guide 1`, read by the same reader
as the header, not NeoVectra's `@node=ID title="…"` and `@guide=1`, which
were ndb.
