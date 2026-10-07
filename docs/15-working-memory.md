# 15 — Working memory: design notes

_Design notes, 2026-10-07. **Non-binding.** These notes work through Scott Jenson's idea of "working memory" for the desktop and how it would sit on the architecture 03, 07 and 11 describe. Three small changes to `/wsys` are proposed in 03 itself (§5.1, §5.7), because protocol v1 is cheaper to change before M7 than after. The rest is a sketch, scheduled nowhere. A part becomes binding through 03, an ADR or a milestone row._

## 1. The idea

Jenson's complaint is what he calls the **curse of direct manipulation**: the desktop is stateless. Cut, paste, open and close leave no trace. "If you copy a few too many things to the clipboard, oh sorry, it's gone." He proposes that the system, not each app, give the user a working memory, of three kinds:

- **Spatial.** A window manager for wide screens: work in the centre, where it is read; the edges kept for peripheral vision, where a window dragged there collapses to a small "stash" form (his music player becomes a play button). It is meant to be organic, not the rigid virtual desktops that suit only very organised users.
- **Associative.** The clipboard made persistent and visible, like Obsidian's Canvas: a drawer the user drags text, images and files into, which "acted like a folder", belongs to a piece of work, and is still there tomorrow.
- **Episodic.** A timeline of what the user worked on, after Lifestreams, for finding things by when they happened and what was beside them rather than by search. It is built from attention signals (what was looked at, and for how long), "telemetry data, not interesting information", with "simple math" rather than a model. Windows Recall, which keeps screenshots, is what it is not.

AI is optional on top: "If the AI can use it, great… That comes later." His preference is small local models, which matches 03 §8's routing policy.

Sources: [LWN's report of the Akademy 2026 talk](https://lwn.net/Articles/1095425/); [the InfoQ interview](https://www.infoq.com/podcasts/evolving-desktop-agentic-ux/); [the talk](https://media.ccc.de/v/kde2026-7-are_we_really_going_to_use_the_same_desktop_ux_forever); [The New Stack on the Ubuntu Summit talk](https://thenewstack.io/ux-pioneer-scott-jenson-on-unsticking-computer-desktop-design/).

## 2. What the architecture already has

Most of the substrate exists on paper, and some of it in code:

| Needed | Already there |
|---|---|
| One timeline to put events on | The system's one clock (01 §4.4); input and frame events are already stamped with it (03 §4, §5.1) |
| Who looked at what, and for how long | `winsrv` sees every focus change and visibility state in the configure record (03 §4) |
| How data moved between apps | The plumber: every message carries its source, working directory, type and attributes (07 §7; 9front `sys/include/plumb.h:3`) |
| The content as it was at a moment | `fsd`'s snapshots and the dump view, `/n/snap/YYYY/MMDD/BRANCH/…` (11 §5) |
| Who may see an aggregate of a user's activity | ADR-0029's broad grants, and `aid`'s labels that follow the data (03 §8.6) |
| Restoring a layout after a reboot | Outputs with stable names from their EDID (03 §5.1); `wm`'s rules as ndb (03 §5.3) |

What is missing is small and specific:

1. **A clipboard.** 03 never designed one.
2. **A window naming the document it shows.** Without it, the system knows windows and files but not that this window is that file.
3. **A compact form for a window.** The stash needs the app's cooperation, so it is a state the protocol carries.

The first two are proposed in 03 §5.1 and §5.7, and the third in 03 §4 and §5.1. Everything else in these notes is policy, an app or a server on top.

## 3. The base: snarf, `doc` and the stashed form

### 3.1 Snarf

Plan 9's clipboard is a file. rio serves `/dev/snarf`: a write appends (`sys/src/cmd/rio/xfid.c:547`), the file's qid version changes with each new snarf (`rio/fsys.c:687`), and a program that wants the text reads it. Fuchsia's answer to who may read it is focus: its clipboard watches the focus chain through a privileged protocol (`sdk/fidl/fuchsia.ui.focus/focus_chain.fidl:64`), so only the focused view reads or writes.

The proposal joins the two (03 §5.1, §5.7):

- **`/wsys/self/snarf`** is rio's file in each app's own tree: a write replaces the current snarf, a read returns it, and the qid version moves on each change.
- **Typed.** A snarf carries a type, as a plumb message does (`text`, `image/png`, a file reference), and may carry several representations of the same thing. A reader names the type it wants.
- **Only with focus and the user's hand.** A read succeeds only from the app whose window has focus, within the input event that asked for it (a paste key or a menu choice); a write only from the focused app. An app in the background cannot watch the clipboard, which X11 and older Android allowed.
- **History is the shell's.** `winsrv` keeps the last N snarfs. The history is in the whole `/wsys` tree, which only `wm`, the shell, the palette and assistive technology hold (03 §5.7), so no app reads another app's earlier copies.
- **Sensitive fields.** A copy from a field marked secret (03 §5.6) becomes the current snarf but is never kept in the history, and is cleared after a short time.

### 3.2 `doc`

A window names its document with a `doc` verb on `/wsys/self`, a path or a URI, changed whenever the window shows something else. macOS has the same fact as a window's represented file. It costs an app one line, `vxui` sets it for windows that open a file, and it is what lets the journal (§6) and collections (§5) speak of documents instead of windows.

It is not trusted for authority: it is what the app says it shows, used for memory and display, never for granting access.

### 3.3 The stashed form

The configure record (03 §4) gains a **form**, `full` or `stashed`. A stashed window gets a small size and draws its compact form: a player's transport controls, a chat's unread count, a build's lamp. `vxui` gives every app a default (its icon and title) so no app has to implement one. Visibility (`visible`, `partial`, `occluded`, `hidden`) is unchanged and separate: a stashed window is usually `visible`.

## 4. Spatial memory: a layout policy

Nothing below `/wsys` is needed beyond §3.3.

- **A `focus` layout** beside 03 §5.2's: work windows tiled in the centre band of a wide output, and stashed windows in the side bands, where they stay in peripheral vision. Dragging a window into a side band stashes it; dragging it back restores it. Policy with logic, so Lua, as 03 §5.3 has it.
- **Places are remembered.** `wm` keeps each workspace's arrangement, keyed by the output's stable name and each window's app and `doc`, as ndb in its own data tree (ADR-0029 decision 6). A window that reopens on the same document returns to its place.
- **No virtual desktops required.** Workspaces stay for those who want them; the `focus` layout is for those who do not.

## 5. Associative memory: collections are folders

- **A collection is a directory** in the user's home: its items as files, and a `layout` ndb file holding each item's position on the canvas and its provenance (the source app, the URL or path, the time, its sensitivity label). It persists because it is files, and its history is `fsd`'s snapshots.
- **Filling it is ordinary.** Drag and drop is server-side (03 §5.1), so dropping onto a collection's window is `winsrv` handing the collection app the data, which it writes as a file. The plumber can route to it as well: a `collect` port, so "send to collection" works from anything that plumbs, and the message's attributes become the provenance.
- **The snarf history feeds it.** The shell's history view (§3.1) offers "keep" on any entry, which files it into the current collection. The ephemeral clipboard and the persistent one are then the same data at two ages.
- **Tied to work.** A collection lives beside the project it belongs to, or a document names its collection in an `xattr` (11 §7, fsd's `xattr` extension). Opening the document can offer its collection.
- **AI is a narrow tool.** "You have a bunch of hotels; let me sort them" is an `aid` session given that one directory (03 §8.5), which is not a broad grant. Nothing in the collection depends on it.
- **The app** is a `vxui` canvas, drawn in the desktop's look (03 §9.1): items as BeOS-style icons and cards on a sunken well.

## 6. Episodic memory: the journal

### 6.1 What is recorded, and by whom

A server, `journal`, serves `/mnt/journal` and keeps per-day ndb records in the user's own data tree. It learns from the processes that already see everything relevant, so apps need no new interface:

- **`winsrv`:** focus gained and lost, the window's app and `doc`, its form and visibility, and dwell (time with focus and visible), on the one clock.
- **The plumber:** each message's source, destination, type and working directory.
- **`fsd`:** which files were written, and their qid versions.

**Only metadata, never content:** time, app, document, dwell and version. No pixels, no `a11y` text, no keystrokes, no snarf contents. A record looks like:

```
focus  t=2026-10-07T14:32:05 app=org.vx.hx doc=/home/jk/src/vectra/docs/15-working-memory.md dwell=1840s
write  t=2026-10-07T15:02:44 path=/home/jk/src/vectra/docs/15-working-memory.md qid.version=118
plumb  t=2026-10-07T15:04:10 src=org.vx.hv dst=web type=text wdir=/home/jk/src/vectra
```

### 6.2 The dump holds the content

This is the part the architecture makes unusual. The journal stores pointers, and `fsd` already stores the content: a `write` record's path, version and time find the file as it was in the dump (`/n/snap/2026/1007/home/…`, 11 §5). The timeline can open any document as it stood at that moment without the journal having copied a byte of it.

So retention is one policy, not two. When a dated snapshot expires under `/cfg`'s retention (11 §5), the content behind those journal entries goes with it, and the timeline shows the entry without its "as it was" view. Recall's problem, a second store of everything the user saw, does not arise.

### 6.3 Retrieval by adjacency

A timeline app shows each day by hour: the documents worked on (from `doc` and `write`), the collections touched, what was plumbed where. The user finds a thing by what was beside it in time. From an entry:

- **open** re-plumbs the document with its working directory;
- **as it was** opens the dump's copy, read-only;
- **restore the arrangement** asks `wm` to put the windows of that moment back in their places (§4).

The ranking is arithmetic, as Jenson does it: dwell, recency and co-occurrence in a time window. A model is optional (§7).

## 7. Privacy

The rules already written cover most of it:

- **The journal is an aggregate, so it is a broad grant,** in the same class as the dump (ADR-0029 decision 1). That list needs one more line, "the journal", by an amendment when the journal is built. Only the shell and the timeline app hold it. Agents never do, and a user who wants an agent to see part of it makes a narrower view ("today's files in project X").
- **Labels follow it.** A journal entry takes its document's sensitivity from `/ai/policy`'s `classify` rules (03 §8.6). Entries for `secret` paths are kept coarsely ("a file in finance") or not at all, by a rule the user can see. A `route source=journal only=local` rule keeps it off providers.
- **Visible and stoppable.** A lamp on the bar while recording, in the family of the egress lamp (03 §9.2), and a pause on it. Pausing stops `journal` taking records; `winsrv` and the plumber keep no copy of their own.
- **At rest.** The journal is in the user's data tree on `fsd`, under the same protection as the rest of the home. Encryption of the volume with a sealed node key is M12's (04 §6); the journal needs nothing extra.
- **Local only by default.** It does not replicate across the swarm (02 §6) unless the user says so.

## 8. Where the pieces would land

| Piece | When | Why there |
|---|---|---|
| Snarf, `doc`, the stashed form | M7, as part of `/wsys` v1 (03 §4, §5.1, §5.7) | Protocol fields cost almost nothing before the first apps, and a migration after |
| The `focus` layout, remembered places | M7 or after | `wm` policy, nothing below it |
| Collections | After M7 | An app and a plumb port |
| `journal` and the timeline | After M7 | Needs `winsrv`, the plumber and `fsd` together; ADR-0029 amended with it |
| AI sorting and journal search | M11 | Optional, through `aid` and its policy |

## 9. Heritage

| From | Taken | Changed |
|---|---|---|
| Plan 9 rio's `/dev/snarf` (`rio/fsys.c:26`, `xfid.c:547`) | The clipboard as a file, versioned by its qid | Per-app under `/wsys/self`, typed, focus-gated, with a history only the shell holds |
| Plan 9's plumber (`plumb.h:3`) | Messages carrying source, working directory and attributes | Read by `journal`; a `collect` port |
| Fuchsia's focus chain (`focus_chain.fidl:64`) | Clipboard access follows focus | Enforced by `winsrv` itself, with the input event that asked |
| gefs's dump, as `fsd`'s (11 §5) | Dated read-only trees | The journal's "as it was" view |
| Lifestreams (Freeman and Gelernter) | A time-ordered stream as the way back to documents | Built from metadata over the dump |
| Obsidian Canvas | A free-form board of collected items | Items are files, the board an ndb file |
| macOS's represented file | A window naming its document | `doc` on `/wsys/self` |

## 10. Open questions

1. **Dwell's grain.** Per focus change, or bucketed (per minute) so the record says less about the user's rhythm?
2. **`hv`'s history.** Does browsing feed the journal through `doc`, or stay in `hv`'s own data tree, with the journal recording only "browsed for 40 minutes"?
3. **The snarf history's length and lifetime.** A count, a time, or both; and whether it survives a reboot (Jenson's point is that it should, which makes it a file on `fsd`).
4. **Cross-device.** Should a user's journal ever follow them across their own nodes in the swarm, or stay per machine?
5. **Collections and the dump.** Should "as it was" also work for a collection, showing the board on a past day? It would, for free, if the board is files; the question is whether the UI offers it.
