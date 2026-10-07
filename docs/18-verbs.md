# 18 — Verbs: scripting for people and agents

_Design notes, 2026-10-07. **Non-binding** except where an amendment is named: 02 §4.2 (`.schema`'s `returns`, object types and the `select` verb), 03 §8.1 (an agent's tools come from `.schema`) and 03 §10 question 7 (answered by recording, §5). The rest is scheduled nowhere until its milestone rows exist (§9)._

## 1. The position

**AppleScript was right about the shape.** Every Mac app could expose a dictionary of its objects and commands; Apple Events carried those commands between apps and machines; any program could drive any other through them, and the user could record what they did and keep it. The Amiga had the same idea first and more simply: every serious application opened an **ARexx port**, and one language scripted them all. Automator, then Shortcuts, put a visual composer on top, and App Intents now feed Siri and Apple Intelligence the same kind of dictionary. MCP (the Model Context Protocol) is the agentic era rediscovering it: a list of typed tools a model may call.

**VectraOS already has most of it, without the name.** Every service and app is a file server with one convention (02 §4), its verbs typed in `.schema` (02 §4.2); a key, a drag, a script and an agent all become the same `ctl` verb (03 §5.5); the namespace, the approval classes, `auditfs` and the undo trees make it safe to let an agent use them (02 §7, 03 §8.5). These notes call the whole layer **verbs**, collect what exists, and design the four pieces that are missing:

1. agents' tools generated from `.schema`, by rule (§4);
2. a dictionary rich enough to script against: return values, object types and queries (§3);
3. recording (§5);
4. saved workflows with triggers, and the runner for them (§6);

and the MCP adapters that let outside agents and outside tool servers meet the system at its edge (§7).

## 2. What already exists

| AppleScript-era piece | VectraOS | Where |
|---|---|---|
| A scriptable surface in every app | Every service is a file server with `ctl`, `info`, `status`, `events`, `clone`, `.help` and `.schema` | 02 §4, rule 10 |
| The app as the target | `/mnt/hx`, and the suite's `/mnt/sheet`, `/mnt/page`, `/mnt/draw` and the rest | 08 §12, 17 §2.2 |
| The dictionary (`sdef`) | `.schema`: typed keys and verbs, each verb's effect class; the manual's page explains each one, and `.help` is generated from it | 02 §4.2, 12 §6.4, §7 |
| Object specifiers | Paths: `/mnt/sheet/1/tables/1/cells` | 17 §2.2 |
| One action, every front end | The same verb from a key, the mouse, a script, the palette or an agent | 03 §5.5 |
| GUI scripting | The accessibility tree as files | 03 §5.6 |
| Messages between apps | The plumber | 07 §7 |
| The language | rc and Lua, and any program that writes files | D12 |
| Natural language in | The palette's previewed plan of verbs | 03 §8.4 |
| Permissions | Namespaces, approvals on the trusted path, broad grants | 02 §7, 03 §8.5, ADR-0029 |
| Undoing automation | `auditfs` snapshots, undo trees that record each change's source | 03 §8.5, 17 §2.3 |
| Remote events | Mounting another node's tree | 02 §6 |

What AppleScript never had is the lower half of the table: a script or an agent here can only name what its namespace holds, every destructive verb can require a person's approval on a path no program can fake, and an agent's whole session rolls back in one click.

## 3. The dictionary

`.schema` is generated from each server's `ctl` table (09 §5.11) and checked against the server's manual page (12 §7), which is where the explanation lives. Three additions make it a dictionary a script or a model can work from. They are amendments to 02 §4.2.

### 3.1 What a verb returns

A `ctl` write returns only success or an error string (02 §4). A verb that produces something names where its result appears:

```
file=ctl verb=sort   args="table:uint col:string order:enum(asc|desc)" effect=reversible
file=ctl verb=export args="format:enum(pdf|odt|docx) path:path" effect=reversible returns=path
file=ctl verb=select args="where:query" effect=read-only returns=file:selection
```

`returns=file:NAME` means the result is read from that file afterwards; `returns=path` means the verb's argument names where it wrote; `returns=clone` means a new instance directory, as `clone` gives, for work that takes time.

### 3.2 Object types

AppleScript's dictionaries said what contains what ("a document has tables, a table has rows"). `.schema` gains `object` records saying which directories are objects and what each contains:

```
object=document dir=N              contains=table,chart
object=table    dir=N/tables/N     contains=row,column  keys=name,rows,cols
object=row      dir=N/tables/N/rows/N
```

A script, the palette or a model can then walk from the app's root to anything in it without reading prose.

### 3.3 Queries: the `select` verb

AppleScript's most useful form was `every row whose …`. Any object directory with many children may offer a standard `select` verb taking a **query**, the same small language everywhere:

```
select where="C>100 status=open name~^Q[1-4]"
```

- A query is a space-separated list of `key OP value` terms, all of which must hold; `OP` is `=`, `!=`, `<`, `<=`, `>`, `>=`, or `~` for a regular expression (Plan 9's syntax).
- Keys are the object's keys from `.schema`, typed there, so `C>100` compares numbers and `due<2026-11-01` compares times.
- The result is ndb, one record per match, in the file `returns=` names; later verbs can take the selection as their target.
- The same language serves Jukebox's smart playlists (17 §6) and the journal's filters (15 §6), and is one parser in `lib/vx-ndb`, fuzzed with the others.

## 4. An agent's tools are its namespace's verbs

This is an amendment to 03 §8.1, and it is the AppleScript-for-agents rule in one line: **an agent's tools are exactly the verbs of the services its namespace holds, generated from their `.schema`.**

- **One source of truth.** `aid` builds each tool definition from a `.schema` record (the name, the typed arguments, the effect class, what it returns) and the verb's first sentence from `.help`, which `build` generates from the manual page (12 §6.4). The dictionary a person reads, the page in the manual and the tool a model calls cannot drift apart, because the manual's coverage check already ties them together (12 §7).
- **No registry.** `/ai/tools` holds only tools that are not files (a calculator, a web search through an adapter). Everything else comes from what is mounted: an agent given `/mnt/sheet/1` has the sheet's verbs and nothing else.
- **Tool names are paths,** `sheet/1/tables/1.select`, so a model sees which object it is acting on, and `auditfs` records the same name.
- **Effects drive approval** as they already do (03 §8.5): `read-only` runs, `reversible` runs under the snapshot, `destructive` asks on the trusted path. A server not on the trusted list is `destructive` in every verb.
- **Shipping an app makes it agent-usable,** with no extra work: a server that has a manual page and a `.schema`, which every server must (12 §7), is a set of tools.

## 5. Recording

Every action a person takes in a window already becomes a verb (03 §5.5). Recording keeps that stream.

- **Each app's verb stream** is an `events`-style file, `verbs`, beside its `ctl`: one ndb record per verb executed, with its target path and arguments, whoever caused it. `winsrv` serves the window manager's own verbs the same way.
- **The shell records:** "record" in the bar starts reading the `verbs` files of the apps the user works in, and "stop" writes an rc script of what happened, in order, with each verb against its object's path. Because verbs name objects, not pixels, a recorded script survives a moved window or a resized table, which AppleScript's recordings and GUI macros did not.
- **Teaching, the same stream:** 03 §10's question 7 ("verb echo") is answered by showing the stream as slips, off by default, so a person learns the verb behind each key.
- **Privacy:** recording is started only by the user, through the bar, and a lamp shows it. A field marked secret (03 §5.6) records its verb but never its value. A recorded script is a file in the user's home, nothing more.

## 6. Workflows

Automator and Shortcuts gave scripts a shape: named, with inputs, started by something, shareable. Here a workflow is a directory, and a small service runs them.

### 6.1 A workflow is files

```
invoice-to-pdf.flow/
    flow           ndb: name, inputs and their types, triggers, the namespace it needs
    run            the script: rc, or Lua (D12)
    icon           optional, from Draw (17 §12)
```

```
# flow
name="Invoices to PDF" input=doc:path
trigger=notify path=/home/jk/invoices/inbox create      # a file arrives (02 §3.3 notify, M6 6e1d)
trigger=plumb  port=flow data~\.page$                   # sent by plumbing
trigger=time   at=09:00 leeway=10m weekdays             # an absolute deadline with leeway (rules 4, 5)
trigger=event  file=/mnt/print/printers/office/status match="state=idle"
needs=/home/jk/invoices rw  needs=/mnt/page  needs=/mnt/print
```

### 6.2 `flowd`

- **Runs workflows on their triggers.** It sleeps until the earliest time trigger, and otherwise waits on the `notify`, plumb and `events` sources it was granted, so with nothing due it costs no wake-ups.
- **Each run gets the namespace its `flow` file declares,** built as an agent's is (02 §7): the named trees, through `auditfs`, and nothing else. The grants are given once, when the user installs the workflow through the grant settings on the trusted path (ADR-0029 decision 2), and kept by `svcd` with the other standing approvals, revocable there. A workflow never holds a broad grant.
- **An agent may write a workflow,** but installing one is a person's act on the trusted path: an agent cannot give itself a standing job.
- **Every run is audited and undoable,** as an agent session is (03 §8.5), and its result or failure is a slip from the bar.

### 6.3 The editor

A `vxui` app shows a workflow as a column of steps, each a verb picked from the dictionary of what the workflow's namespace holds (§3), with its arguments as fields and its effect class as a lamp. It edits the `run` script and the `flow` file; the files stay the truth, so `hx` and a script edit the same workflow. Recording (§5) opens here as a new workflow.

## 7. MCP at the edge

MCP is JSON-RPC, and JSON stays at the edge (08 §7). Two adapters in 07 §6.1's pattern meet it there:

- **`mcpfs`, outside tools in.** It starts or dials one MCP server and serves its tools as files: each tool a `ctl` verb, its JSON Schema translated into a `.schema` record, its effect class taken from the tool's annotations and otherwise `destructive`; its resources as files. Confined like any adapter: the server's own process gets only what it needs, and `mcpfs` gets its one connection.
- **`mcpd`, the system out.** It offers an outside MCP client, such as a coding agent's command-line program, the verbs of one namespace, generated from `.schema` exactly as §4 does for `aid`. The client then works through `auditfs`, under approval classes and the user's labels. 03 §8.5 says agents the system did not start get none of `aid`'s audit, labels or undo; through `mcpd` they get all three.

## 8. Security

Nothing here adds authority; it uses what exists:

- A script, a workflow, a recorded macro or an agent can name only what its namespace holds (rule 3).
- `destructive` verbs ask on the trusted path, which only physical input answers (03 §5.7).
- Standing approvals are visible and revocable in the grant settings; broad grants are never given to automation (ADR-0029).
- Every mutating verb from automation passes through `auditfs` and can be undone with its session.
- The query language and `mcpfs`'s JSON are parsers of untrusted input, fuzzed (04 §7).

## 9. Where the pieces land

| Piece | Needs | Earliest |
|---|---|---|
| `returns`, object types, `select` in `.schema` | `build`'s `.schema` generation (09 §5.11), the manual check (12 §7) | Now; additive, with servers adding them as they are touched |
| The query language in `lib/vx-ndb` | Nothing new | With the first `select` |
| `verbs` streams and recording | `winsrv`, the shell, the plumber | M7 |
| `flowd` and workflows | `notify` (M6 6e1d), the plumber (M7), the grant settings | After M7 |
| The workflow editor | `vxui` | After M7 |
| Tools from `.schema` | `aid` | M11 |
| `mcpfs`, `mcpd` | `aid`'s policy; JSON at the edge | M11 |

## 10. Heritage

| From | Taken | Changed |
|---|---|---|
| ARexx | Every application opens a port; one language scripts them all | The port is a file server, and any language that writes files is the language |
| AppleScript, Apple Events, `sdef` | Dictionaries, object specifiers, `whose` queries, recording | `.schema` with object types and `select`; paths as specifiers; recording verbs, not events |
| Automator, Shortcuts | Named workflows with inputs, triggers and a composer | Files run by `flowd`, under declared and approved namespaces |
| App Intents | A dictionary for the assistant | Tools generated from `.schema`, the same dictionary people use |
| Plan 9 | `ctl` files, the plumber, Acme's executable text | Unchanged, and the base of all of it |
| MCP | Typed tools for models | Spoken only at the edge, by `mcpfs` and `mcpd` |

## 11. Open questions

1. **Where `object` records come from.** `.schema` is generated from a server's `ctl` table (09 §5.11); object types need a table too, or a section of the manual page the generator reads. Which?
2. **Query scope.** Is AND-only enough, or does `select` need OR and grouping? Smart playlists and journal filters are the test cases.
3. **Lua or rc for recorded scripts.** rc reads naturally as a list of verbs; Lua is better for anything with logic. Record as rc and convert on request?
4. **Workflow sharing.** A workflow is files and can ship in a package (06 §3). Does a shared workflow's `needs=` show apart in the install list, as broad grants do (ADR-0029 decision 2)?
5. **`mcpd` and the POSIX personality.** Third-party coding agents are POSIX programs (03 §8.5). `mcpd` is native; does it serve them over a local socket in the POSIX namespace, or only over a 9Px mount their port can reach?

## 12. Sources

- [AppleScript](https://en.wikipedia.org/wiki/AppleScript); [Apple Events](https://en.wikipedia.org/wiki/Apple_event); [ARexx](https://en.wikipedia.org/wiki/ARexx); [Shortcuts](https://en.wikipedia.org/wiki/Shortcuts_(software)); [App Intents](https://developer.apple.com/documentation/appintents); [Model Context Protocol](https://modelcontextprotocol.io/).
- In this tree: 02 §4, §7; 03 §5.5–§5.7, §8; 07 §6–§7; 08 §7, §12–§13; 09 §5.11; 12 §6.4, §7; 15; 17 §2.2; ADR-0029.
