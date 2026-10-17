# Native applications

A plan for VectraOS's own applications (2026-10-17, proposed; D95). It
collects the applications NeoVectra and todhchai each planned, keeps
those both planned, says how they are built, and proposes the later
milestones they go in (V11 to V16, §9). The stack for creators who
stream, which neither project planned, has its own design in
`docs/studio.md` (D96).

The sources are NeoVectra's `docs/07-native-apps.md` (the web and
network clients) and `docs/17-applications.md` (the suite), and
todhchai's `docs/desktop.md`, `docs/browser.md`,
`docs/research/communications.md`, `docs/research/office-suite.md`,
`codecs/README.md` and `docs/sdk.md`. §10 says what is taken from each.

## 1. The axiom, and the two stances under it

**The web is hypermedia content, not an application delivery device.**
Applications are native. This is NeoVectra's D18 ("Documents are
documents; applications are native") and todhchai's script-free
browser, and everything below follows from it.

- **Why it holds:** the alternative is the 40-million-line problem. A
  browser that delivers applications needs a JavaScript engine, a JIT,
  WebAssembly, the whole DOM and Web API surface, and a sandbox around
  them. That is more code than the rest of the system together, and it
  would break principle 2 (the base system fits in one head) alone.
- **What the browser is:** a reader of documents. It renders HTML, CSS
  and the other document formats in §4, and runs nothing it fetches.
  Its interactivity is links and forms, as hypermedia's is.
- **A "web app" is a protocol behind a page.** Where an open protocol
  exists (mail, calendars, chat, social, feeds, video, git), VectraOS
  gets a native client for it. Where none exists (a bank, a vendor's
  office suite, a map service), there are two outcomes. The task runs
  on another machine's browser, shown here through remote windows
  (V16), or it isn't done here. VectraOS never grows a runtime for it.
- **No senseless layers** (principles 1 and 3). There is no web runtime
  to host applications in, no engine embedded in an application, and
  no compatibility layer. Each mechanism below replaces something, and
  says what.

Two stances sit under the axiom. Both projects had rules for
applications, and both carry forward. They answer different questions,
so they don't conflict.

- **Build our own** (todhchai principle 29, our D4 and principle 28).
  Every engine, codec, parser, protocol implementation and toolkit on
  the device is first-party Swift or C23, written clean-room from the
  specification. NeoVectra's vendored pieces (NetSurf's libraries, the
  single-file decoders, tree-sitter, Lua, llama.cpp) are not carried.
- **Speak existing protocols and standards** (NeoVectra 07 §1 and
  D18: "Reuse, don't reinvent"). Applications talk to the servers and
  files people already have: IMAP, CalDAV, IRC, XMPP, ActivityPub,
  Atom, HTML, ODF, FLAC, Opus, AV1, RTMP. VectraOS invents no new
  network protocol, markup language, document format or social network
  for an application. Where two standards do one job, pick the one
  with the most independent implementations and the simplest wire
  format, and add the next only when users need its network (NeoVectra
  07 §6).

Together: **our code, their wire.** The formats we do invent stay below
the applications, in system plumbing that already exists: the IPC wire
format, the ring, the trace, Taisce, `.vxm`, the manual's guide format,
and the app file (principle 24).

Two consequences settle choices the sources left open:

- **An application's own documents use a standard format.** The office
  applications save ODF, not a native format of ours (todhchai's
  office research left this open). Mail is RFC 5322 bytes, calendars
  iCalendar, contacts vCard, notes Markdown.
- **A standard that needs code from the network is refused**, not
  implemented: no JavaScript in the browser, no macros in documents, no
  DRM. This was already both projects' position.
- **A standard is implemented as a stated profile, within a line
  budget** (§3, rule 8). Speaking a standard doesn't oblige us to all
  of it. Each one gets a profile that says which parts we implement.
  A standard whose required core won't fit its budget is refused, not
  grown into.

## 2. What's in scope: what both projects planned

The applications are the ones both NeoVectra and todhchai planned. An
application only one of them planned is listed in §8 and waits for a
decision of its own.

| Application | NeoVectra | todhchai | Here |
|---|---|---|---|
| File manager | the bench (03 §9) | Tracker | Tracker, V5 (already planned) |
| Terminal | `term` | Terminal | rio and `vt`, V5 (already planned) |
| Plumber | plumber | Router | plumber, V2 (done, D85) |
| Settings, system monitor | Settings, Activity | Preferences, Inspector | V5's shell (already planned) |
| Text editor | `hx` (Acme with LSP) | Edit | the editor, V11 |
| Debugger and trace viewer | `dbg` | debugger, timeline | V11 |
| Web and document browser, no JavaScript | `hv` and `webfs` | Browser | the browser, V11 |
| Mail | `mail` | Mail | V12 |
| Contacts | CardDAV | People | V12 |
| Calendar | CalDAV | CalDAV | V12 |
| Feeds and podcasts | `/mnt/feed` | feed reader | V12 |
| Chat | IRC, XMPP | Matrix, XMPP, Delta Chat | V12 |
| Social | ActivityPub, AT, Nostr | Nostr, ActivityPub, AT | V12 |
| Word processor, spreadsheet, slides | Page, Sheet, Stage | office research | V13 |
| Music | Jukebox | Player | V14 |
| Photos | Photos | photos kept and searched | V14 |
| Video and audio player | `media` (plumb target) | `video` handed off by the browser | V14 |
| Screen recorder | — | Recorder (`capture`'s reference) | V15, in Studio |
| Voice and video calls | deferred (SIP, Jingle, WebRTC) | deferred (WebRTC, Opus) | V16 |
| Remote windows | `/wsys` surface stream, AV1 or H.265 | remote desktop, codecs later | V16 |
| Games | engine tier | Game Kit | V9 (already planned) |
| AI | `aid` | the embedder service | V10, the Ghost (already planned) |

The Recorder is the one row only one project planned that is kept: it
is the first thing the streaming stack does, so it comes with V15.

## 3. How an application is built

Each rule below uses an existing mechanism, so no application brings a
new one (principle 1).

1. **A protocol is a service; an application is a view.** This split
   replaces each client's own store, socket handling and key handling,
   which every application would otherwise repeat. Each network
   protocol is one service process per account (todhchai's protocol
   classes, NeoVectra's adapter file servers). It speaks the standard
   wire, keeps what it fetches in Taisce as standard-format files with
   typed attributes (principle 18), and serves its controls as a node
   (`/svc/mail/ACCOUNT/{ctl,status,send}`). The application is a live
   Taisce query plus that node. It never opens a socket and never holds
   a credential (NeoVectra 07 §7): factotum holds the keys (D75), and
   `/net` (D79) is in the service's namespace, not the application's.
2. **Applications reach each other through the plumber** (D85).
   `mailto:`, `ircs://`, `file:line`, a `.odt` and an `rtmp://` URL are
   plumb rules, not links between programs.
3. **Formats come in through translators.** A translator is a confined
   process that turns one format into another (todhchai's translators,
   NeoVectra's converters). It replaces linking a parser into every
   application that reads the format, and keeps a parser's bugs out of
   the application's address space. Installing one teaches every
   application and the indexer that format. Each is fuzzed and, on the host, checked
   against a reference implementation, as D89 does for crypto (§7).
4. **Bulk media moves on rings.** A media pipeline is processes joined
   by rings (principle 6), negotiated through their nodes, and seen in
   the ring patch bay (D24). This is todhchai's Media Kit node graph
   without a second graph mechanism: its per-node latency accounting
   becomes each stage's trace events (principle 14). Buffers are the
   one buffer currency (principle 8), so a decoder hands frames to the
   display, and a capture hands them to an encoder, without a copy.
5. **Extensions are plug-in processes** (D92). No application embeds a
   scripting language. A spreadsheet's user functions, an editor's
   language support and a studio's filters are plug-ins or rc.
6. **Built on the public kits.** First-party applications use only the
   SDK a third party gets (todhchai principle 25), and every SDK surface
   comes from one of these applications as its reference program
   (principle 22).
7. **Each application has its page and its budgets.** Its manual page
   lands with it (D86), and its startup, idle cost and hot-path latency
   are budgets with running checks (principle 13). An idle application
   costs nothing (todhchai principle 9).
8. **Every engine, protocol service and application has a line
   ceiling.** This is principle 2 applied to the applications.
   - **Where the ceiling is set:** in the milestone that adds the
     component, as its first step, in `docs/performance.md`'s Size
     table. `vx loc --check` checks it, as it does the manual's parser
     (≤ 1,500 lines, D86).
   - **The profile comes with it.** The standard's profile (rule 2 in
     §1) is written in the component's manual page.
   - **When code outgrows its ceiling,** the profile shrinks or the
     code is cut. The ceiling is never raised in the change that
     would fail it (principle 15).
9. **No accounts, telemetry, store or DRM.** Local first (principle 27):
   a protocol service talks to the servers the user configured and
   nothing else.

## 4. Reading and writing (V11)

- **The browser.** todhchai's engine, written in Swift from the WHATWG
  specifications: the complete HTML parser, URL and Encoding standards,
  a stated CSS profile (NeoVectra's: Selectors 3, flexbox, media
  queries, `oklch`; grid open), images through translators, and no
  JavaScript, Wasm from the network or web fonts. Its interactivity is
  links and forms, and nothing more (§1). It also reads
  CommonMark, Gemini's gemtext, Gopher and plain text (NeoVectra). Its
  fetching is `webfs`: HTTP/1.1 over TLS 1.3, Gemini and Gopher served
  as files, after Plan 9's webfs, on V10's TLS client. `<video>` and
  `<audio>` plumb to the player.
- **The editor.** One editor, with Acme's architecture: it is a file
  server (each window's body, tag, address and events are files),
  edits with sam's structural regular expressions (NeoVectra's
  `vx-text`, rewritten, provenance.md), and runs rc commands from its
  text. Language intelligence comes through LSP, the standard. The
  language servers are third-party (clangd, sourcekit-lsp), so they run
  on the developer's host and the editor reaches them over cpu (D75,
  D4), as `vxc` runs there. A language server on the device would be
  first-party and a plug-in process (D92). No such server is planned.
  Git's object and pack formats and
  its smart HTTP protocol are implemented, not ported. It replaces
  todhchai's Edit as the plumber's `edit` port.
- **The debugger and the trace viewer.** The debugger works through the
  process's `/proc` files and V3's debugging calls, reads DWARF 5, and
  shares the editor's windows for source. The trace viewer draws the
  one trace format's timeline, with its GPU track.

## 5. Communications (V12)

Each protocol is a service under §3's rule 1, in this order:

1. **Feeds:** Atom (RFC 4287) and RSS 2.0 with enclosures, which also
   makes podcasts. The smallest protocol, and the first proof of the
   service-and-view pattern.
2. **Mail:** IMAP4rev2 (RFC 9051) and SMTP submission, MIME, each
   message a file of its raw RFC 5322 bytes with its headers as
   attributes, the inbox a live query. HTML mail is shown by the
   browser's engine. Then OpenPGP with Autocrypt; JMAP later.
3. **Contacts and calendar:** CardDAV and CalDAV, vCard and iCalendar
   files with attributes. A person's file holds their handles on every
   network (todhchai's People).
4. **Chat:** IRC with IRCv3 (SASL, `message-tags`, `chathistory`)
   first, then XMPP with OMEMO. MLS (RFC 9420) when a network uses it.
   Matrix waits for a decision: both projects named it, and they
   disagreed on whether it comes early.
5. **Social:** ActivityPub, through the Mastodon client API, first,
   then AT Protocol and Nostr. Both projects named all three, and they
   disagreed on the order. ActivityPub goes first because both the
   self-hosted video network (PeerTube) and creators' servers
   (Owncast, `docs/studio.md`) speak it.

Each service implements the client side of a stated profile (§1). It
covers what a user's client needs, not the protocol's server-side or
federation machinery. For example, AT Protocol's client API, not a
relay or a personal data server.

All of them need TLS 1.3, HTTP/1.1, JSON at the edge (the service
parses it; nothing past the service sees it), and for some CBOR. These
are first-party and lifted or written once, beside V3's crypto.

## 6. Documents (V13)

- **Write, Sheet and Show** (working names): a word processor, a
  spreadsheet and slides. Their own format is ODF (ODT, ODS, ODP), with
  OpenFormula for formulas. OOXML (`.docx`, `.xlsx`, `.pptx`), CSV,
  Markdown and EPUB come through translators. Output is tagged PDF.
  There are no macros; a spreadsheet's user functions are plug-ins or
  rc (D92). NeoVectra's Lua is not carried.
- **Shared engines:** one typesetter (OpenType shaping through the text
  stack, line breaking, hyphenation, a TeX-style equation subset), one
  formula engine, and one PDF writer. The browser's print path uses the
  same PDF writer.

## 7. Media (V14)

- **Codecs, as translators.** Images: PNG, JPEG, GIF, WebP, AVIF.
  Audio: WAV, FLAC, Opus, Vorbis, MP3. Video, decoding: AV1 and VP9,
  royalty-free and in software first, then H.264 and HEVC through each
  board's hardware decoder (the Sky1's Mali-V decodes all four). The
  containers are Matroska and WebM (RFC 9559), MP4 (ISO BMFF) and Ogg.
  todhchai's decoders (PNG, JPEG, WAV, FLAC, DEFLATE) are lifted.
  Encoders arrive with V15.
- **Oracles.** Each codec is checked differentially on the host against
  a reference implementation used only by the tests, after D89. Where
  the specification has normative reference code (Opus's RFC 6716, the
  AV1 reference decoder), that code is the oracle.
- **Player:** audio and video, A/V synchronised by timeline fences,
  frames from the decoder straight to a display plane. Internet radio is
  a stream URL; podcasts come from V12's feeds.
- **Music:** a library of tagged files queried in Tracker and in Music
  (todhchai's `Audio:*` attributes), with ReplayGain and gapless play.
  No subscriptions and no DRM.
- **Photos:** a library of image files with EXIF read into attributes,
  albums as queries, non-destructive edits stored as attributes, and
  camera and card import (NeoVectra's bench).

## 8. Planned by only one project, not scheduled

These wait for a decision of their own. Each would use the kits above
and add no mechanism.

- NeoVectra only: Paint (after Deluxe Paint, IFF ILBM), Draw (SVG, and
  the system's icons), Notes, Reminders, Stickies, printing over IPP
  Everywhere and scanning over eSCL.
- todhchai only: a CD ripper (from storyboard frame 13).
- Neither: a PDF viewer as an application, maps, a camera
  application. V15's camera sources are the first camera code.

## 9. Milestones

These go after V10, in this order. Each one adds the kits its
applications need, from those applications (principle 22).

| Milestone | Applications | Kits it adds |
|---|---|---|
| V11 Reading and writing | browser, editor, debugger and trace viewer | the HTML and CSS engine, `webfs`, translators (images), LSP, Git |
| V12 Communications | feeds, mail, contacts, calendar, chat, social | the protocol-service pattern, HTTP, JSON at the edge, OpenPGP |
| V13 Documents | Write, Sheet, Show | the typesetter, the formula engine, PDF, ODF |
| V14 Media | player, music, photos | the media pipeline over rings, decoders, containers, hardware decode |
| V15 Studio | Studio, Recorder (`docs/studio.md`) | capture, encoders, mixer, RTMP, SRT, WHIP, HLS |
| V16 Calls and remote windows | voice and video calls, remote windows | WebRTC's media path only (ICE, DTLS-SRTP, RTP; no data channels or SCTP), on V15's encoders |

Each milestone's first step sets the line ceilings of the components it
adds (§3, rule 8).

Why this order:

- V11 comes first because everything after it uses its parts. Mail
  shows HTML, Show draws text, and the trace viewer measures the rest.
- V12 needs only V11's engine and V10's TLS.
- V13 needs V11's text work and no media.
- V14 needs V8's accelerators and a board's video unit.
- V15 needs V14's pipeline and decoders.
- V16 reuses V15's encoders and RTP path.

**Moving Studio earlier.** If Studio should come sooner, it can follow
V14 directly, ahead of V12 and V13, because it depends on neither.
That reorder is the owner's call.

## 10. What we take, and how it changes

| From | Taken | Changed or not carried |
|---|---|---|
| NeoVectra 07 | the stance on protocols, the protocol table and its selection rule, `webfs`, the adapter that never holds a key, plumb rules | NetSurf's libraries (D4); the adapter's own file tree becomes Taisce files plus a node |
| NeoVectra 17 | the suite's principles, Sheet, Page and Stage as applications, Jukebox, Photos, the formats lists | Lua user functions (D92); vendored decoders (D4); `vxui` (todhchai's UI Kit won, provenance.md) |
| NeoVectra 08 | `hx`'s architecture (Acme, LSP, Git, structural regexps) | tree-sitter (third-party, D4); language servers on the host only |
| NeoVectra 00 D18 | "Documents are documents; applications are native", the axiom (§1) | — |
| todhchai desktop.md, sdk.md | apps on the public SDK, reference programs, translators, Storage Kit schemas, `capture` | the Media Kit's own graph becomes rings and the patch bay |
| todhchai browser.md | its engine, no JavaScript, the stages | its htmx-style extensions are not carried: they turn pages into application interfaces, which §1 refuses, and they are a convention, not a standard |
| todhchai communications.md | protocol classes, one sync service per protocol, apps as live queries | the order (§5) |
| todhchai office-suite.md | its research | a native format of our own: ODF is the native format (§1) |
| todhchai codecs | the decoders, translators, oracles | oracles follow D89 (host-only, reference code first) |

## 11. Open questions

1. Matrix: in V12, or later as NeoVectra had it?
2. The CSS profile's edge: grid, and how much of CSS 2.1's table layout.
3. The debugger's debug info: DWARF 5 read directly (one format, a
   standard), or todhchai's own fast format converted on the host?
   DWARF 5 is proposed here.
4. Syntax highlighting without tree-sitter: LSP's semantic tokens
   alone, or a first-party incremental parser per language?
5. H.264, HEVC and AAC in software: whether to write them at all, given
   their patents, or use only hardware for them (also `docs/studio.md`
   §9).
6. Which oracle for each codec, and whether a GPL reference is
   acceptable as a host-only test target.
7. The first line ceilings, set as each milestone begins (§3, rule 8).
   The browser's engine (parser, CSS profile, layout, painting) is the
   one to watch most closely.
