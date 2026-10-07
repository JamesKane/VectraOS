# 17 — The application suite: a vision

_Vision, 2026-10-07. **Non-binding.** A suite of first-party applications comparable to Numbers, Pages, Keynote, iTunes (the library, not the store), Photos, Notes, Reminders and Stickies, a modern Deluxe Paint and a vector editor, designed for this system rather than ported to it. Nothing here is scheduled, and nothing changes a rule in 00. Each app becomes real through its own design note and milestone rows; §16 proposes an order. The names are working names._

## 1. The position

**The system should ship the applications people do their work in.** NeXTSTEP shipped Edit, Mail and its other apps with the system and so showed what the system was for; Apple's suites do the same today. A system with only a shell, an editor and a viewer is a platform waiting for someone else's apps. This suite is the reason a person would sit down at VectraOS.

**Designed for the system, not ported to it.** The suite does not imitate its models screen for screen. Each app takes what made its model good, and builds it on what VectraOS has that other systems lack:

- **Every app is a file server**, as `hx` is (08 §12): its documents' structure is files, so scripts, Lua, agents and other apps drive it as a person does (rules 2 and 10).
- **Documents are directories** of plain files and ndb, like NeXT's `.rtfd` bundles: readable without the app, versioned by `fsd`'s snapshots for free (11 §5).
- **The plumber connects them** (07 §7), and the user's rules, not an app, decide what opens what.
- **Local-first,** with the swarm as the sync and the server (02 §6): no account, no cloud, no subscription.
- **Data-oriented cores** (16): columns, ids and batches, so a million-row sheet or a 50,000-photo library stays fast.
- **AI is optional and the system's** (03 §8): apps ask `aid`, under the user's policy, and work fully without it.

What the suite will not have: a store, a licence check or anything paid (no payments in the platform); DRM; a sign-in; telemetry; a handheld companion app.

## 2. Principles every app follows

### 2.1 Documents are directories

A document is a directory with a suffix the plumber knows (`.sheet`, `.page`, `.stage`, `.draw`, …), served by `fsd` like any other:

```
budget.sheet/
    doc            ndb: format version, title, author, the document's labels
    tables/1/      one table: columns as files (§3.2), its formulas, its styles
    canvas         ndb: what sits where on each sheet (tables, charts, text, images)
    media/         images and other media, as their original files
    preview.png    a rendered first page, for the file manager and `hv`
```

- **Readable without the app.** `cat budget.sheet/tables/1/formulas` shows the formulas; `grep` finds text in every document a user has; a script can make a document by writing files.
- **History is the dump's.** `fsd` keeps dated snapshots (11 §5), so "show this document as it was last Tuesday" is opening `/n/snap/…/budget.sheet` read-only. The journal's "as it was" (15 §6.2) works on documents with no app support.
- **One file for exchange.** Sending a document out of the system (mail, a web form) packs the directory into one archive file with the same suffix and `.zip`, and unpacking it is a plumb rule. Inside the system it stays a directory.

### 2.2 Every app is a file server

Each app serves its open documents under `/mnt/APP`, with `ctl`, `events`, `.help` and `.schema` as every service has (rule 10):

```
/mnt/sheet/
    ctl                   open PATH · new · close N
    1/
        ctl               recalc · sort table=1 col=C desc · insert-rows table=1 at=40 n=10
        events            cell changes, selection, recalculation finished
        tables/1/cells    read or write ranges: A1:C40, as ndb rows
        selection         the user's current selection, as a range
```

An agent filling a budget writes a range through `cells` under `auditfs` (03 §8.5), and the user's undo covers it. The accessibility tree (03 §5.6) is still there for anything the file interface does not cover.

### 2.3 One undo model, and versions

- **Undo is a tree** with each change's source recorded (08 §4): the user, a script, an agent, a collaborator. A source's changes undo on their own.
- **Versions are snapshots.** A named version is an `fsd` label on the user's branch (11 §5): "Sent to the board" is a label, kept until deleted.

### 2.4 Local-first collaboration

- **Shared documents use the structure `hx` already uses:** operations carry the id of the insertion or change that made them, so concurrent edits merge without a server deciding (08 §10.2). Ink & Switch's Automerge and Keyhive are the reference points for the model and for access control.
- **The swarm carries it** (02 §6): two people on their own nodes edit one document over Noise channels (00 D16). No third-party sync service exists in the design.

### 2.5 Import and export: honest, and confined

- **Converters are separate processes,** one per format, each confined to the one file it was handed and its output (07 §8): a hostile `.docx` can crash its converter and nothing else. Every converter's parser is fuzzed (04 §7).
- **Honest degradation,** as `hv` has it (07 §2): an import says what it could not keep.
- **Formats:** OpenDocument (ODS, ODT, ODP) and Office Open XML in and out; CSV and TSV; Markdown; PDF out (first-party writer); EPUB out from Pages; images and audio in their standard formats (§7, §8). Formulas follow **OpenFormula**, the ODF formula standard, so a sheet's meaning does not depend on one program.

### 2.6 How the apps are built

- **Full Swift for the apps** (ADR-0034 §1: object graphs with shared owners, protocol-shaped plug-points), shaped by 16's rules: columns, ids and batches in the cores, ARC per document, not per cell or per glyph.
- **Engines shared with the system in C23** where scripts, servers or `hx` use them too: the text model (`lib/vx-text`, 08 §4), the typesetter, the formula engine, the image pipeline. Host-testable and fuzzable like every library (04 §7).
- **`vxui` for every window** (03 §6), in the desktop's look (03 §9.1): bevelled chrome, sunken wells, BeOS-style document icons. No web views.

### 2.7 AI, when the user wants it

Through `aid` and `/ai/policy` only (03 §8.6), local by default, with labels that follow the data: suggesting a formula, summarising a long document, tagging photos, transcribing a voice note. Every feature works without a model installed, and nothing is sent off the machine unless the user's policy allows it, which the egress lamp shows (03 §9.2).

## 3. Sheet (after Numbers)

**What it keeps from Numbers:** a sheet is a free canvas holding several tables, charts, text and images, rather than one endless grid. Tables have header rows and columns, categories and summary rows.

### 3.1 What it adds

- **Large is normal,** as in `hx` (08 §2): a table of ten million rows opens at once, because columns are mapped from `fsd` (`Tmap`, 01 §5), not parsed.
- **Formulas readable as text,** in OpenFormula's syntax, and editable as a whole through the file interface or in `hx`.
- **Live references to other documents:** a cell may read a range from another sheet document, or from any file that serves ndb rows (a server's `status`, a log), so a sheet can be a live dashboard over the system's own files.
- **Lua for user functions** (D12), confined to the document.

### 3.2 The engine

- **Columnar storage** (16 §5 rule 3): each column a typed array (numbers, text ids into an interned arena, dates, booleans, errors), with a sparse overlay for mixed types. A column is a file in the document, so `fsd` maps it.
- **Recalculation is a dependency graph** kept as arrays: cells and ranges as ids, edges in adjacency arrays, dirty marks propagated in topological order. Independent chains recalculate in parallel over chunks (16 rule 7), on the `throughput` intent; the UI never waits for a recalculation (rule 4).
- **Formula compilation:** each formula compiled once to a small bytecode over column spans, so a formula filled down a million rows is one compiled program run over a column, not a million interpretations.

## 4. Page (after Pages)

**What it keeps:** word processing and page layout in one app; styles first; a document is text that flows through pages, with objects placed in it or on the page.

- **The text model is `hx`'s,** `lib/vx-text` (08 §4): the piece tree, anchors and undo tree, so a 500-page manuscript is as fast as a letter, and comments, tracked changes and collaborators' cursors are anchors.
- **Typesetting worthy of print:** Knuth and Plass's total-fit line breaking (as TeX does it) by default, Liang's hyphenation patterns as data, kb_text_shape for shaping (03 §6), OpenType features, and real small caps, ligatures and figures. Layout runs on a `background` thread with a deadline; the page you are typing on is laid out first.
- **Styles are ndb,** a small cascade (paragraph, character, list, table), so a house style is a file you can copy.
- **Outputs:** PDF (with tagged structure, so it is accessible), EPUB, ODT, DOCX, Markdown, and the system manual's guide format (12) for documentation.
- **Writing tools without lock-in:** footnotes, cross-references, a bibliography from a plain BibTeX or CSL-JSON file, and equations in a TeX subset.

## 5. Stage (after Keynote)

**What it keeps:** presentations that look designed, with motion that explains. Keynote's Magic Move is the model: the same object on two slides moves, scales and fades from one to the other.

- **Magic Move from stable ids.** Every object on a slide has an id, as every `vxui` widget does (03 §6); a transition matches objects by id across two slides and interpolates their properties. No manual pairing.
- **Drawn on the GPU** with `vxui`'s Vulkan renderer (M8), at the display's refresh rate, with exact frame feedback (03 §4), so transitions are smooth on a 120 Hz panel and on a projector.
- **Presenter mode across outputs.** The slide on the projector, notes, the next slide and a clock on the laptop, placed on outputs by their stable names (03 §5.1), so the setup comes back next time.
- **A remote is another node.** A phone is not a target, but a laptop or tablet-sized PC in the swarm mounts the presentation's `/mnt/stage` and sends `next` (02 §6).
- **Slides as data:** a slide is ndb plus media; a script can generate a deck from a sheet's rows.

## 6. Jukebox (after iTunes, before Music)

**What it keeps from iTunes:** a library of the music the user owns, with tags done properly, playlists and smart playlists, gapless playback, and a visualiser. **What it leaves:** the store, streaming subscriptions, DRM, device sync and a social layer.

- **The library is the user's files.** Jukebox indexes audio files where they are, reads and writes their tags in the files themselves, and keeps only its index and play counts in its own data tree (ADR-0029 decision 6). Deleting Jukebox's data loses no music.
- **Smart playlists are queries** in ndb over the index (`genre=jazz year<1970 rating>=4`), and a playlist is a file of references, readable and writable by scripts.
- **Playback through `audiod`** (03 §7, M13): a stream per player, gapless by writing the next track's samples into the ring before the current one ends; ReplayGain; a crossfade if wanted. Decoders for FLAC, Opus, Vorbis and MP3 are vendored single-file C libraries, chosen by ADR; other codecs wait on their licences.
- **Your swarm is your music server:** the library on a home node, mounted by every terminal (02 §6), with no streaming service. Podcasts come from feeds (07 §6), and internet radio is a stream URL.
- **The visualiser** is a Vulkan program on the engine tier, fed the samples Jukebox plays: the demoscene's job, done properly at the display's refresh rate.
- **A file server:** `/mnt/jukebox` plays, queues and reports what is playing, so the bar (03 §9.2), a key binding or a script controls music the same way.

## 7. Photos

**What it keeps from Photos:** a library of everything the user has shot, browsed by time and place and people, with non-destructive edits and albums.

- **Originals are never touched.** Imports are copied once into the library as their original files, deduplicated by content hash. An edit is a recipe, an ndb file of operations (exposure, white balance, curves, crop, retouch), rendered on the GPU from the original; reverting is deleting the recipe.
- **Importing from cameras and cards** is the bench's work (03 §9.4): a card appears as a `dosfs` volume (M5's 8a and 8b), and "Import into Photos" is its menu choice.
- **Fast at size:** thumbnails and previews in a cache in Photos' data tree; the library's metadata (time, place, camera, labels) in columns (16), so a timeline of 50,000 photos scrolls at the display's rate.
- **People, things and text in photos** come from local models through `aid`, by the user's policy (03 §8.6), and stay labelled `private`. Places come from the photos' own GPS tags, shown on offline map tiles if the user installs some; nothing is looked up online by default.
- **RAW** formats through one vendored decoder, chosen by ADR with its licence checked against BSD-3-Clause; HEIF and AVIF the same way.
- **Edits reach other apps by plumbing:** "Edit in Paint" plumbs the rendered image (§11, §13), and the result comes back as a new version.

## 8. Notes

**What it keeps:** quick capture, folders, search, checklists, sketches and attachments, and notes that are always there.

- **A note is a Markdown file** in the user's home, in a folder the user chooses. Notes edits them in place, with a rendered view and `lib/vx-text` underneath; `hx` and any script edit the same files.
- **Links between notes** in wiki style, with backlinks computed by a small index, so Notes is also a personal knowledge base.
- **Attachments and sketches** sit in a folder beside the note, and a sketch opens in Paint (§11) by plumbing.
- **Working memory** (15): a note can hold a collection (15 §5), "keep" from the snarf history files a clip into today's note, and the journal (15 §6) finds a note by when it was written.
- **Voice notes** are transcribed by whisper on the NPU (03 §8.4) when the user turns it on.

## 9. Reminders

**What it keeps:** lists, due dates, repeats, priorities, and an alert that arrives on time.

- **A reminder is a record:** ndb in a list file in the user's home, and iCalendar `VTODO` through a CalDAV adapter (07 §6.1's adapter pattern) for people who keep their tasks on a server.
- **Alerts on absolute deadlines.** A small service, `remindd`, sleeps until the next due time with a leeway the user sets (rules 4 and 5), and shows a slip from the bar when it wakes (03 §9.2). With nothing due, it costs no wake-ups.
- **Plumbing makes reminders from anything:** a selected sentence in mail, a line in `hx`, a note's checklist item, by a plumb rule to `remind`.
- **A calendar** is the natural sibling, on the same adapter and the same records, and is out of this list's scope.

## 10. Stickies

**What it keeps:** small coloured notes on the desktop, always visible, for the thing you must not forget today.

- **Stickies live on the bench** (03 §9.4), Workbench-style: small windows that stay on the desktop surface, each a text file in the user's home, coloured from the theme's tokens.
- **The stashed form** (15 §3.3): a sticky dragged to a side band collapses to its first line.
- **Promotion, not duplication:** "Keep in Notes" moves a sticky's text into a note; "Remind me" makes it a reminder. A sticky is the shortest-lived form of the same text.

## 11. Paint (a modern Deluxe Paint)

**What it keeps from Deluxe Paint:** the brush as the centre of everything (any selection becomes a brush, transformed, stretched, bent and stamped), an indexed palette with ranges, colour cycling, stencils, symmetry, perspective, and animation with anim brushes. It is the Amiga's own tool, and it suits this desktop's heritage (03 §9.1).

**What it adds, from Pro Motion and Aseprite:** layers, onion skinning, a timeline, tilesets and tile maps for game art, true-colour alongside indexed modes, and exact export for game engines.

- **The engine tier** (03 §6): a CPU pixel buffer at M7, exactly what 03's "pixels with no GPU API" path is for, then Vulkan at M8 for filters and large canvases. Pen input with pressure, tilt and proximity (03 §5.1), every event with its timestamp, so strokes are exact at any device rate.
- **Indexed colour is real:** pixels are palette indices, so colour cycling and palette swaps cost nothing, as on the Amiga.
- **Formats:** IFF ILBM and ANIM in and out, so old Amiga art opens; PNG, GIF and APNG; sprite sheets with their atlas data; Aseprite's format in, by its published specification.
- **Heritage, not code.** The Computer History Museum publishes Deluxe Paint I's 1985 source, but for non-commercial study only. It is read for its ideas, never copied into the tree.
- **A file server too:** `/mnt/paint` takes brush and palette operations, so a script can generate tiles or batch-convert palettes.

## 12. Draw (a vector editor)

**What it keeps from Illustrator, Affinity Designer and Inkscape:** precise paths, shapes, strokes and fills, gradients, symbols, artboards, text on paths, and output that prints and scales. **What it takes from newer tools:** Figma's vector networks, where a point may join any number of segments rather than one chain, so a shape that branches is one object; and Graphite's non-destructive graph, where booleans, offsets, repeats and effects stay editable as operations instead of being baked into the path.

- **The drawing is data, laid out for the cache** (16): a vector network is a vertex array and a segment array (each segment two vertex ids and its curve's control points), regions are cycles over segment ids, and shapes, transforms and styles are columns keyed by object id. A drawing of 100,000 paths is a few dense arrays, not 100,000 objects.
- **Non-destructive by default.** A boolean, an offset, a repeat or a blend is a node in the drawing's operation graph, kept as ndb beside the geometry. Its inputs stay editable, and its result is recomputed when they change. Baking a result into plain paths is an explicit command.
- **One path renderer, shared with the desktop.** `vxui`'s Vulkan 2D renderer (M8) draws paths for every app; Draw uses the same one, so what Draw shows is what Stage and Page show. The approach follows Raph Levien's Vello: tiling, parallel prefix sums and coverage computed in compute shaders, with almost nothing per path on the CPU. Vello itself is Rust and is studied, not vendored (D1); the renderer is first-party C and GLSL. Geometry is kept in double precision and drawn in single.
- **Text is the typesetter's** (§4): kb_text_shape, variable fonts, text on a path, and outlines from glyphs as an operation, not a one-way conversion.
- **The system's icons are made here.** Icons are vector files, one per object in `/lib/icon`, drawn to 03 §9.1's BeOS rules: three-quarter view from above, a heavy outline, faces lit from the theme's `light.angle`, one highlight edge and a cast shadow. Draw has an icon mode that sets up that view and light, previews the icon in both themes and at every size the desktop uses, and checks the rules. The icon format itself is decided with this mode, at the latest when M7 needs its first icons.
- **Formats:** SVG in and out, in a stated profile as `hv`'s HTML is (07 §4), parsed in a confined converter (§2.5); PDF out; the icon format; PNG export of slices at chosen scales for apps.
- **Pen and precision:** pressure-sensitive strokes become variable-width paths; snapping to points, guides, the pixel grid and angles; constraints between objects (aligned, equal spacing) as data the file server exposes.
- **A file server:** `/mnt/draw` reads and writes shapes, styles and the operation graph, so a script can generate a chart, a diagram or a set of icons, and an agent edits a drawing through the same verbs and undo as a person.

## 13. How the apps connect

The plumber (07 §7) is the only way one app reaches another, and the user's rules decide:

| From | Plumbed | To |
|---|---|---|
| A chart in Sheet | `type=image` reference to the chart, live | Page, Stage (the chart redraws when the sheet changes) |
| A photo | `type=image` | Paint, Page, Stage, Notes |
| A selected sentence anywhere | `type=text`, port `remind` | Reminders |
| A song in Jukebox | `type=audio` reference | Stage (a slide's soundtrack) |
| A sketch in Notes | `type=image` | Paint |
| A sticky | `type=text`, port `notes` | Notes |
| A drawing in Draw | `type=image` reference, live, kept as vectors | Page, Stage (shapes keep their ids, so Magic Move can move them) |
| A Draw selection | `type=image`, rasterised at a chosen scale | Paint |

**Live references, not embedding.** OLE and OpenDoc embedded one program's data inside another's document, and both foundered on it. Here a document holds a reference (a path, and the range or object) and a cached rendering; the source app keeps the data. If the source is gone, the cached rendering remains and says so.

## 14. Security

- **Each app runs in its own namespace** (rule 3), with the user's documents it was given, its own data tree (`#appdata`, ADR-0029 decision 6), `/mnt/plumb` and its own window tree. No app sees another app's data except what the user plumbs to it.
- **Converters and decoders are confined and fuzzed** (§2.5): the image, audio, RAW, SVG, ODF and OOXML parsers each run in a process with one file in and one out.
- **Lua in a document** (Sheet's user functions) runs confined to that document, with no files and no network.
- **The suite holds no credentials.** CalDAV and any other service go through adapters, `keyd` and `tlsd` (07 §2).

## 15. Budgets

Added to 00 §8 when each app reaches a milestone:

| Budget | Target on T1 |
|---|---|
| Open a 10-million-row table to first paint | < 300 ms |
| Recalculate a 100,000-formula sheet after one edit | < 50 ms |
| Lay out a 500-page document from cold | < 2 s, the visible page first in < 100 ms |
| Scroll a 50,000-photo timeline | at the display's refresh rate, no dropped frame |
| A Paint stroke, pen to pixel | < 1 frame + 2 ms (03 §4's direct path) |
| Pan and zoom a 100,000-path drawing | at the display's refresh rate |
| Gapless playback | 0 samples of silence between tracks |
| Any app idle with a document open | 0 wake-ups per second |

## 16. Where the pieces land

Each app needs the system beneath it, and the order follows that:

| App | Needs | Earliest |
|---|---|---|
| Stickies, Notes | `vxui` v0, the plumber, `lib/vx-text` | M7 (Pixels) |
| Paint, on the CPU | `vxui`'s pixel buffer, pen input | M7 |
| Reminders | `remindd`, slips; CalDAV waits for M11's `tlsd` | M7, CalDAV at M11 |
| Paint on the GPU, Photos, Stage, Draw | Vulkan through `vxui` (M8); Draw also the shared path renderer | M8; Draw's icon mode earlier if M7's icons need it |
| Page, Sheet | The typesetter, the formula engine, converters | After M8, as their own steps |
| Jukebox | `audiod` (M13) | M13 |
| Collaboration in any app | The swarm (M10) | M10 onwards |
| AI features | `aid` (M11) | M11 |

A milestone of its own, after M15, would gather the suite: an exit test of a document made in each app, plumbed into another, edited by a script through its file server, and opened as it was a week earlier from the dump.

## 17. Heritage

| From | Taken | Changed |
|---|---|---|
| NeXTSTEP | Apps shipped with the system; documents as bundles (`.rtfd`) | Bundles served by `fsd`, versioned by snapshots |
| Acme and `hx` (08) | The app as a file server; the undo tree with sources | Applied to tables, slides, photos and pictures |
| Numbers | Sheets as canvases of several tables | Columnar storage, OpenFormula, live references to files |
| Pages, TeX | Styles first; Knuth–Plass line breaking; Liang hyphenation | A piece tree underneath, shared with `hx` |
| Keynote | Magic Move | Objects matched by stable ids, as `vxui`'s widgets are |
| iTunes | A library of owned music, smart playlists, a visualiser | The swarm as the server; tags in the files; no store |
| Photos, Lightroom | Non-destructive edits on untouched originals | Recipes as ndb files, rendered on the GPU |
| Deluxe Paint, Pro Motion, Aseprite | Brushes, palettes, colour cycling, animation, tiles | Real indexed colour on a modern pen and display |
| Illustrator, Affinity Designer, Inkscape | Paths, symbols, artboards, print-ready output | One renderer shared with the desktop |
| Figma's vector networks | A point joined to any number of segments | Vertex and segment arrays, regions as cycles over ids |
| Graphite | A non-destructive graph of operations | Kept as ndb beside the geometry, readable through `/mnt/draw` |
| Vello (Raph Levien, Linebender) | Path rendering in GPU compute: tiling and prefix sums | First-party C and GLSL in `vxui`'s renderer; Vello studied, not vendored |
| OLE and OpenDoc | The wish for compound documents | Live references and cached renderings instead of embedding |
| Ink & Switch | Local-first software, CRDT documents, Keyhive's access control | Over the swarm and Noise, with `hx`'s operation ids |

## 18. Open questions

1. **Swift or C for each engine?** §2.6 puts shared engines in C and apps in Swift. The formula engine and typesetter could be Swift with a C interface (`@c`, ADR-0034 §2) instead; the deciding question is whether a server or script needs them without Swift's runtime.
2. **The archive format for exchange** (§2.1): `.zip` because the world reads it, or `tar` because the system already has a reader (bootfs)?
3. **How much OOXML.** Full fidelity with Office is a decade's work for any team; which subset is the target, and is it measured against a corpus?
4. **Codecs and licences.** AAC, HEIF and RAW decoders each carry patent or licence questions against BSD-3-Clause; each needs an ADR before it is vendored.
5. **Printing.** There is no print system in the design. PDF out covers most needs; an IPP adapter (07's pattern) would cover printers. Is that in scope?
6. **A calendar and contacts.** Reminders' CalDAV adapter makes a calendar cheap, and mail (07) wants contacts. Do they join the suite?
7. **Names.** These are working names. Do the shipped apps get plain nouns, as here, or names in the desktop's NeXT and Amiga voice?

## 19. Sources

- Deluxe Paint's source: [Computer History Museum, the release](https://computerhistory.org/press-releases/dpaint-release/) and [the early source](https://computerhistory.org/blog/electronic-arts-deluxepaint-early-source-code/) (non-commercial licence); [Deluxe Paint](https://en.wikipedia.org/wiki/Deluxe_Paint); [Deluxe Paint Animation](https://en.wikipedia.org/wiki/Deluxe_Paint_Animation); [GrafX2](https://en.wikipedia.org/wiki/GrafX2).
- Modern pixel tools: [Pro Motion NG](https://www.cosmigo.com/promotion/docs/onlinehelp/whatIsProMotion.htm); [Aseprite and Pro Motion compared](https://www.slant.co/versus/5470/5474/~aseprite_vs_cosmigo-pro-motion-ng).
- Vector editing and rendering: [Figma's vector networks](https://www.figma.com/blog/introducing-vector-networks/) and [their engineering](https://alexharri.com/blog/vector-networks); [Graphite](https://graphite.art/); [Vello](https://github.com/linebender/vello).
- Local-first: [Local-first software](https://www.inkandswitch.com/local-first-software/); [Automerge 3](https://www.inkandswitch.com/newsletter/dispatch-012/); [Keyhive](https://www.inkandswitch.com/project/keyhive/); [Patchwork](https://www.inkandswitch.com/patchwork/notebook/tasks-01/).
- In this tree: 03 §4–§9; 07 §2, §6–§8; 08 §4, §10, §12; 11 §5; 15; 16; ADR-0029; ADR-0034.
