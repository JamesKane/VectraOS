# Phase 7 — Native applications and the hypermedia web

_Blueprint v0, 2026-10-02. Provisional: a vision. Nothing here is needed before M11, which brings `tlsd` (00 D16). It fixes the intended shape and is rewritten against the code each piece produces (§12)._

## 1. The position

**The web is a graph of hypermedia documents.** A document is text with structure, links to other documents and forms that send data back. That model is Fielding's REST: the server sends hypermedia, and the links and forms in it are the whole interface. It needs no code on the client.

**The browser became an operating system inside the operating system.** JavaScript turned documents into programs, and each new web API copied a service the OS already has: a process model (workers), storage (IndexedDB, the origin-private file system), a package manager and offline installer (service workers), a GPU API (WebGPU), devices (WebUSB, WebSerial, WebBluetooth, WebHID), networking (WebSockets, WebRTC, WebTransport), a permission system, and now a second instruction set (WebAssembly). Each is a second mechanism beside the system's own, which rule 13 forbids, and together they are the largest program on most machines. The same code delivers tracking, fingerprinting and pages that need megabytes of script to show a paragraph.

**VectraOS separates the two jobs again:**

- **Documents are documents.** A small viewer shows hypermedia: a cut-down HTML and CSS profile (§4), and the small-web formats that already exist. It runs no code from the page.
- **Applications are native.** Chat, microblogging, social media, mail and feeds are small native programs, each speaking an open protocol that already exists (§6). Each is its own experience in its own namespace, not a tab in a browser.
- **The OS provides what browsers re-implement.** The namespace is the sandbox (rule 3), packages are signed by their publisher (06), `keyd` holds credentials, `tlsd` holds TLS, `/wsys` draws windows, and the plumber connects one app to the next (§7).

**Reuse, don't reinvent.** The protocols are IRC, XMPP, ActivityPub, Atom, IMAP and the rest of §6, spoken as they are, to the servers people already use. The HTML parser, CSS engine and layout come from an existing C engine (§5). Nothing here is a new network protocol, a new markup language (00 §7) or a new social network.

## 2. Goals

- **A document is never a program.** No page runs code, so no page can track, mine, fingerprint or keep the CPU awake. An idle document costs nothing (00 §8).
- **Every protocol is a file server.** Each one is spoken by one adapter that serves its data as files, so scripts, agents and several clients use the same data (rules 2 and 10). This is Plan 9's shape: `webfs`, `upas/fs`, the plumber.
- **Small, self-contained clients.** Each client is a `vxui` app (03 §6) with one job, packaged on its own (06 §3.3), confined to the files of its protocol. Removing one removes nothing else.
- **No credentials in apps.** Passwords, tokens, client certificates and session cookies live in `keyd`; `tlsd` attaches them inside the TLS session (03 §8.6). A compromised client holds nothing worth stealing.
- **Your swarm is your bouncer.** An adapter on an always-on node keeps its connections; every terminal mounts it (02 §6). Chat history, read state and drafts follow the user with no third-party sync service.
- **Honest degradation.** A page that needs script shows what the server sent, and says so. The system does not pretend to be a full browser.

Non-goals for v1: running JavaScript or WebAssembly from the network; a full web engine in the base system; web fonts; a new protocol for any service in §6; a single app that does everything.

## 3. Documents, applications and protocols

| What | Examples | Handled by |
|---|---|---|
| **A document** | An article, a manual, a blog, a wiki page, a search result page, a form | `hv`, the document viewer (§4, §5), through `webfs` |
| **A small-web document** | Gemtext, Gopher menus, plain text, Markdown files | `hv`, through `webfs` |
| **A file** | An image, a PDF, an archive, a video, a tarball | Fetched by `webfs` and plumbed to the app for that type (§7) |
| **A conversation or a feed** | Chat, microblogging, social media, mail, feeds, podcasts | An adapter file server and a native client (§6) |
| **A web application** | Banking, shopping, government forms, office suites, maps | The service's native client where an open protocol exists (§6). Otherwise outside the base system: what a user ports into their own user land is their business (rule 13) |

The test for which row something belongs in: if it still works with scripting turned off, it is a document. If it needs local state and code to be useful, it is an application, and it should be native.

## 4. The document profile

`hv` implements a **profile**: a named, versioned subset of HTML and CSS, published as `/lib/hv/profile` so authors can target it. Version 1 is fixed by ADR before the milestone, and like every protocol's first version it is permanent (rule 9).

### 4.1 HTML

- **Parsing follows the WHATWG HTML parsing algorithm** in full. Real pages are tag soup, and only the standard algorithm turns them into the tree every other browser sees. The profile limits what is *rendered*, never what is parsed.
- **Rendered:** the document and section elements (`html`, `head`, `title`, `body`, `header`, `footer`, `main`, `nav`, `article`, `section`, `aside`, `h1`–`h6`, `address`); grouping (`p`, `hr`, `pre`, `blockquote`, `ol`, `ul`, `li`, `dl`, `dt`, `dd`, `figure`, `figcaption`, `div`); all text-level elements, including `ruby`, `bdi` and `bdo`; `ins` and `del`; tables in full; `img` and `picture` with `srcset`; `details` and `summary`, which open and close without script.
- **Forms are hypermedia and stay:** `form` with GET and POST (URL-encoded and multipart), `input` of the text, search, email, url, password, number, checkbox, radio, file, hidden and submit types, `textarea`, `select`, `button`, `label`, `fieldset` and `legend`. A server-rendered application built on links and forms works in full.
- **Handed to another app:** `audio` and `video` show their poster and controls, and play by plumbing the media URL to the player (§7). `a download` and links to non-document types go the same way.
- **Shown as a link:** `iframe`, `object` and `embed`, with their `title` or URL. Following one opens it as a document of its own.
- **Ignored:** `script`, event-handler attributes, `canvas` (its fallback content is rendered), `template`. `noscript` is rendered, because to `hv` scripting is off.
- **Head:** `meta charset` and `meta viewport`, `link rel=stylesheet`, `rel=alternate` for feeds (offered to the feed client, §6.3), `rel=icon` and `rel=canonical`. Everything else is ignored.

### 4.2 CSS

- **In:** the cascade with author, user and user-agent origins; selectors level 3, plus `:is`, `:where` and the list form of `:not` (no `:has`); the box model; normal flow; floats; relative and absolute positioning; flexbox; custom properties; `calc()`; the units `px`, `em`, `rem`, `%`, `ch`, `vw` and `vh`; colours including `oklch`; media queries for width, `prefers-color-scheme`, `prefers-reduced-motion` and `print`.
- **Out:** transitions, animations and transforms (motion belongs to apps; a document holds still); `position: fixed` and `sticky`, which become `absolute` and `static` (overlays that follow the reader are a nuisance pattern); `@font-face` (§4.3); `@import` beyond one level.
- **Grid** is an open question (§14): it is how modern pages lay out, and it is also the largest piece of a layout engine.

### 4.3 What the viewer decides, not the page

- **Fonts are the system's.** `vxui` loads fonts only from `/lib/font` and `$home/lib/font`, because stb_truetype does not defend against hostile font files (03 §6). A page's `font-family` maps to installed families by generic class: serif, sans-serif, monospace.
- **The theme is the user stylesheet.** `hv` turns the design tokens (03 §5.4) into the user-agent stylesheet, so an unstyled page looks native and follows dark mode. **Reader mode** drops author styles altogether, a single key away.
- **Requests carry nothing the page did not need:** no `Referer` across sites, no third-party cookies ever, and a cache partitioned by the top-level site, so a cached image cannot track between sites.
- **Cookies are kept per site only when the user says so.** The default is a session that ends with the window. A kept cookie is a credential and lives in `keyd`, as 9front keeps them in `webcookies`; `hv` never sees its value.

### 4.4 Small-web formats

`hv` also renders, natively and with no conversion step:

- **Gemtext** over the Gemini protocol: links one per line, headings, lists, quotes and preformatted blocks. Gemini's trust-on-first-use certificates and client certificates go through `tlsd` and `keyd` (§14, question 2).
- **Gopher** menus and text.
- **Plain text** and **Markdown** (CommonMark), the format most documentation is already written in.

## 5. The engine

| Candidate | What it is | Verdict |
|---|---|---|
| **NetSurf's libraries** | A browser engine in C, written for small machines: `libhubbub` (WHATWG HTML parser), `libcss` (CSS parser and selection engine), `libdom`, and a layout engine behind a frontend interface that already has GTK, framebuffer, RISC OS, Amiga, Atari and Windows frontends. JavaScript is an optional Duktape build that can be left out | **Recommended.** C, as D1 wants; small enough for the line-count ledger to carry; a `vxui` frontend is the port its design expects, not a compatibility layer |
| Dillo | A small browser in C and C++, on FLTK | Tied to FLTK, which would be a second toolkit beside `vxui` |
| litehtml | An HTML and CSS layout library with no JavaScript | C++ (D1), and a layout library only: networking, images and the frontend would still be ours |
| Ladybird, Servo, WebKit, Blink, Gecko | Full web engines | Each is the OS-in-the-OS this document refuses, at millions of lines. Servo is also Rust (D1) |
| A first-party engine | Parser, cascade and layout written for `vxui` | Reinvents the part that is already done well. Revisit only if NetSurf's layout cannot meet the profile |
| Plan 9's `mothra` and `abaco` | The Plan 9 browsers, over `webfs` | The model is right and is kept (§5.1). The engines predate HTML5 parsing and CSS |

The ADR that vendors the engine records its line count, its fuzzing (04 §7: HTML, CSS, images and every network format are hostile input) and what was left out.

### 5.1 How a page is fetched and shown

```
 hv (one process per window)                     webfs                      tlsd · keyd · netd
 namespace: /mnt/web, /wsys/self, /lib/font      namespace: /net, /srv/tlsd
 ┌────────────────────────────┐   9Px   ┌──────────────────────────────┐  TLS 1.3   ┌────────┐
 │ parse · cascade · layout   │◄───────►│ clone → N/{ctl,body,parsed/} │◄──────────►│ server │
 │ vxui draw · a11y tree      │         │ cookies by keyd · cache      │            └────────┘
 └──────────┬─────────────────┘         └──────────────────────────────┘
            │ plumb: links to other apps, media, downloads (§7)
            ▼
```

- **`webfs` keeps Plan 9's interface**: `/mnt/web/clone` gives a connection directory, `ctl` takes `url`, `request` and `useragent`, `parsed/` holds the URL's parts, and `body` reads the response. It speaks HTTP/1.1, Gemini and Gopher. It is the only program that speaks them, so any script can fetch with `cat`.
- **`hv` has no network.** Its namespace holds its own `webfs` connections, its window and the fonts. A hostile page that breaks the parser finds no `/net`, no `$home` and no keys. Saving a file uses the asynchronous file picker (03 §6), which the trusted path draws.
- **The page is an accessibility tree.** `hv` publishes the rendered document through `/wsys/windows/N/a11y` (03 §5.6), so screen readers and agents read the same text the user sees, with links as `press`-able nodes.

## 6. Protocols: what exists, and what each client speaks

Every row below is an existing, open, documented protocol with servers people already run. The rule for choosing: **prefer the protocol with the most independent implementations and the simplest wire format;** add the next only when users need its network.

| Service | First | Then | Not now, and why |
|---|---|---|---|
| **Chat, communities** | IRC with IRCv3 (SASL, `message-tags`, `chathistory`) | — | — |
| **Chat, person to person** | XMPP (RFC 6120, 6121) with OMEMO end-to-end encryption | MLS (RFC 9420) once its XMPP binding is standardised | Matrix: the largest federation protocol here, with state resolution and a client SDK to match; a later package, not the first. Signal, WhatsApp, Discord: closed protocols with no third-party clients allowed |
| **Microblogging, social** | ActivityPub (W3C), through the Mastodon client API most servers implement | AT Protocol; Nostr (NIP-01), whose identities are keys, as the swarm's are | Closed networks with no open API |
| **Following publications** | Atom (RFC 4287) and RSS 2.0, with enclosures for podcasts | JSON Feed | — |
| **Mail** | IMAP4rev2 (RFC 9051) and SMTP submission | JMAP (RFC 8620, 8621) | — |
| **Calendar and contacts** | CalDAV and CardDAV, iCalendar and vCard | — | — |
| **Video, music** | Files over HTTP; PeerTube and Funkwhale through ActivityPub | — | Streaming sites that need DRM or script |

**JSON and XML stay at the edge.** ActivityPub, the Mastodon API and JMAP speak JSON; XMPP and Atom speak XML. The adapter parses them, fuzzed like every network parser, and serves ndb (D14). No client and no script sees JSON, as no app sees TLS.

**An adapter is not a compatibility layer.** It is the system's one implementation of a protocol that lives outside the system, as `netd` is the one implementation of TCP. It wraps no second mechanism of our own (rule 13).

### 6.1 The shape: adapter plus client

Each service is two processes:

```
 client (vxui app)                           adapter (file server)                 the network
 namespace: /mnt/<svc>, /wsys/self,          namespace: /net or /srv/tlsd,
            /mnt/plumb                                  its state dir, keyd
 ┌───────────────────────┐   9Px files   ┌────────────────────────────────┐  IRC · XMPP ·
 │ one job, one window,  │◄─────────────►│ connections, sync, local store │◄─ ActivityPub ·
 │ reads and writes files│               │ serves messages as directories │   IMAP · Atom
 └───────────────────────┘               └────────────────────────────────┘
          ▲                                          ▲
          └── scripts, agents (02 §7) and other clients use the same files
```

- **The adapter** holds the connection, the local copy and the sync state. It runs on the terminal, or on an always-on node of the swarm and is mounted from there: that is what an IRC bouncer or a mail server's sync daemon does, with no new mechanism.
- **The client** draws. It never opens a socket and never holds a credential. Several clients may share one adapter, such as a full client and a notification band.
- **Plan 9 did this first:** `upas/fs` serves a mailbox as directories of messages, and Acme's Mail and `nedmail` are two clients of the same files. Inferno's `ircfs` serves IRC the same way.

### 6.2 One shape for messages

Mail, chat lines and posts are all messages, so every adapter serves them in one shape. The clients stay separate; the shape is shared so that scripts, search and agents handle all of them with the same code.

```
/mnt/irc/libera/
    ctl                 connect · join #vectra · part #vectra · nick jk
    status              ndb: server, nick, state=connected, lag=42ms
    chans/#vectra/
        topic
        users           one ndb record per member
        send            write a line to say it
        events          new messages, joins, topic changes, as ndb records
        msgs/
            1781/       info  body
            1782/       info  body

/mnt/fedi/social.example/
    ctl                 follow @ann@example.org · boost 1099 · fav 1099
    post                write a body, with ndb headers above a blank line, to publish
    timelines/{home,local,notifications}/
        1099/           info  body  media/  replies/

/mnt/feed/
    ctl                 add https://example.org/atom.xml · refresh
    feeds/12/           info  items/
    unread/             a union of every feed's unread items
```

`info` is one ndb record with the same keys everywhere it applies: `id`, `from`, `to`, `date`, `subject`, `inreplyto`, `url` and `read`. `body` is UTF-8 text (ADR-0013); rich bodies arrive as HTML and are rendered by `hv`'s engine, under the document profile, inside the client.

### 6.3 What this gives

- **Three ways to do everything** (03 §1): the client, a key binding, and a script or agent writing the same `ctl` verb. `echo 'join #vectra' >/mnt/irc/libera/ctl` is the whole IRC API.
- **System search** (03 §8.4) indexes `/mnt/*/msgs` and their kind with no per-app plug-in.
- **Agents** get a narrow namespace (02 §7): a summariser can be given `/mnt/feed/unread` read-only, and nothing else. Messages carry the `private` sensitivity label by default, so the routing policy keeps them local (03 §8.6).
- **Notifications** are a client of the adapters' `events` files, drawn by the shell. No app runs in the background to show one.

## 7. The plumber: how the experiences connect

A browser holds everything in one program so that a link can open anything. Plan 9 solved the same problem with the **plumber**: a small server that receives messages saying "here is some data, of this kind, from this app" and, by rules the user writes, routes each to the program that handles it, starting it if needed.

```
# $home/lib/plumbing — 9front's rule language, kept
type is text
data matches 'https?://[^ ]+\.(png|jpe?g|webp|gif)'
plumb to image
plumb start image $0

type is text
data matches 'https?://[^ ]+\.(mp4|webm|ogg|opus|mp3)'
plumb to media
plumb start media $0

type is text
data matches '(https?|gemini|gopher)://[^ ]+'
plumb to web
plumb start hv $0

type is text
data matches 'mailto:[^ ]+'
plumb to sendmail
plumb start mail -c $0

type is text
data matches 'ircs?://[^ ]+'
plumb to irc
plumb start irc $0
```

- A link in a chat message, a URL in the terminal, an image on a page and a file in the file manager all go through the same rules, so each app stays small and the user, not an app, decides what opens what.
- The plumber is the one place an app can reach another. A client's namespace has `/mnt/plumb` and no other app's files.
- It is Plan 9 baseline (00 §1): its port names and rule language are kept as 9front has them.

## 8. Security

- **Every network parser is fuzzed** (04 §7): HTML, CSS, the image decoders, gemtext, IRC lines, XMPP's XML, the JSON of ActivityPub and JMAP, MIME and Atom.
- **Every process that parses network data has no authority to misuse.** `hv` has no network and no `$home`; an adapter has its one service's network access and its state directory; a client has only its adapter's files. A compromised XMPP adapter can read the user's XMPP messages, which it held anyway, and nothing else.
- **Credentials never leave `keyd`.** `tlsd` attaches them inside the session (00 D16), as it does for AI providers.
- **No code from the network runs,** so there is no script engine to escape, no JIT and no W^X exception (01 §5) for any of this.
- **Link previews are fetched by no one** unless the user turns them on per adapter: a preview is a request the sender can watch for.

## 9. Writing for VectraOS

What a site or service needs to work well here, all of it already good practice:

- **Server-rendered HTML** with links and forms, inside the profile (§4), works in full. htmx-style progressive enhancement degrades to plain links and forms, which works.
- **Publish a feed** (`link rel=alternate`), and the feed client follows the site.
- **Offer an open protocol** for anything conversational, and a native client exists.
- **A native application** uses `vxui` (03 §6), packages through 06, and declares its namespace in its manifest. It is not a page.

## 10. Budgets

Added to 00 §8 when the milestone that makes each measurable lands:

| Budget | Target |
|---|---|
| `hv` cold start to the first paint of a cached 100 KiB page | < 100 ms on T1 |
| Layout of a 1 MiB HTML document, such as the HTML specification's single page | < 1 s on T1 |
| Resident memory of `hv` showing a typical article | < 32 MiB |
| An idle document, or an idle client with its adapter connected | 0 wake-ups per second; adapters' keepalives coalesced with other background work |
| A message arriving to its line on screen, adapter on the same node | < 1 frame after the adapter has it |

## 11. What ships where

- **The base system:** `webfs`, the plumber, and `hv`. A system that can show its own documentation, and the documentation of anything it downloads, needs no more.
- **App packages (06 §3.3):** every adapter and client in §6, signed by its publisher. The first-party ones are packages too, so the base stays one that a person can read (rule 13).
- **Not shipped, not offered:** a JavaScript engine, a WebAssembly runtime, a full web engine, an Electron-class runtime. A user may port one into their own user land; the platform does not build on it.

## 12. Where the pieces land

| Milestone | Pieces |
|---|---|
| **M7 Pixels** | The plumber and its rules, with the terminal and the file manager as its first clients |
| **M11 AI** | `tlsd`, which `webfs` and every adapter need |
| **M15 Hypermedia and native clients** | The engine ADR (§5) and the profile ADR (§4); `webfs` with HTTP, Gemini and Gopher; `hv` with the `vxui` frontend, reader mode, the accessibility tree, and Markdown and gemtext; the message shape (§6.2) as a host-testable library, `lib/vx-msg`; the feed adapter and client, then IRC, then mail. Each later protocol is a package with its own ADR for any import |

## 13. Heritage

| Taken from | What | Changed |
|---|---|---|
| Plan 9 `webfs`, `webcookies` | The web as a file server; cookies held apart from the browser | Cookies live in `keyd`; TLS is `tlsd`'s; Gemini and Gopher beside HTTP |
| Plan 9 `mothra`, `abaco` | A browser that runs no script, over `webfs` | A modern HTML5 parser and a CSS profile |
| Plan 9 `upas/fs`, Acme Mail; Inferno `ircfs` | A protocol as a file server, clients over the files | One message shape across services (§6.2) |
| Plan 9 `plumber` | Routing data between small programs by user rules | Unchanged, and the only way one client reaches another |
| Fielding's REST | Hypermedia as the engine of application state | Taken literally: a document's links and forms are its whole interface |
| NetSurf | A small C engine with frontends | A `vxui` frontend; no Duktape |
| Gemini, Gopher, the small web | Documents that are only documents | Rendered beside HTML, not instead of it |
| IRC bouncers, mail sync daemons | Connections kept on an always-on machine | The swarm mount is the bouncer, for every protocol |

## 14. Open questions

1. **CSS grid.** Modern layouts use it, and pages without it degrade badly; it is also the largest piece of layout. Measure how many pages from a sample the profile renders acceptably with and without it, and whether NetSurf's layout can take it, before the profile ADR.
2. **Gemini's trust model.** Trust on first use and client certificates differ from web PKI, which `tlsd` checks. Either `tlsd` gains a TOFU mode with pins kept by `keyd`, or Gemini needs a second TLS user, which D16 rules out.
3. **Image and media decoders.** PNG, JPEG, WebP, AVIF and GIF for `hv`, and audio and video codecs for the media player. Each is a hostile-input parser to vendor, fuzz and count. Which formats v1 refuses is decided with the engine ADR.
4. **End-to-end encryption.** OMEMO uses the Signal protocol's double ratchet, whose C library is no longer maintained; MLS is the standard successor, but its XMPP binding is still a draft. A vendored, audited implementation of one of them is needed before person-to-person chat ships.
5. **Voice and video calls.** The open stacks are SIP with RTP, and XMPP's Jingle; WebRTC is the web's. All are large. Out of v1 unless a smaller path appears.
6. **Web applications people cannot avoid.** Banks and governments that offer only a script-driven site. One answer is a full browser on another machine of the user's, shown through the remote windows of 03 §9; another is to leave it to user land. Neither belongs in the base system.
7. **Discovery.** Finding feeds, chat rooms and accounts without a central directory is the same problem as finding publishers (06 §16, question 7), and is left with it.
