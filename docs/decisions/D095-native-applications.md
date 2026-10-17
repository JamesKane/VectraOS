# D95. Native applications: what both NeoVectra and todhchai planned, our code speaking existing standards (2026-10-17, proposed)

The owner's direction (2026-10-17): collect NeoVectra's and todhchai's
native application ideas into a new set of later milestones. The scope
is the applications both projects planned. todhchai's stance (build our
own) and NeoVectra's (use existing protocols and standards) are both
kept. `docs/apps.md` is the design.

- **The axiom: the web is hypermedia content, not an application
  delivery device.** Applications are native (NeoVectra D18: "Documents
  are documents; applications are native").
  - **The browser reads documents.** It runs nothing it fetches, and
    its interactivity is links and forms.
  - **A web app gets a native client** over its open protocol. Without
    one, it runs on another machine's browser, shown through remote
    windows, or not here.
  - **No web runtime.** VectraOS never grows one: a JavaScript engine
    and the Web API surface would be the 40-million-line problem
    (principle 2).
- **Our code, their wire.** Every engine, codec, parser and protocol
  implementation on the device is first-party (D4, todhchai principle
  29). Every protocol and document format an application speaks is an
  existing standard (NeoVectra D18, 07 §1). VectraOS invents no network
  protocol, markup or document format for an application. Its own
  documents are ODF, RFC 5322, iCalendar, vCard and Markdown.
- **Profiles within line ceilings** (principle 2).
  - **A standard is implemented as a stated profile,** written in its
    component's manual page: a protocol's client side, not its
    federation or server machinery.
  - **Every engine, protocol service and application gets a line
    ceiling** in the milestone that adds it, checked by
    `vx loc --check`.
  - **What won't fit is refused.** A standard whose required core
    won't fit its ceiling is refused, not grown into.
- **The scope is what both planned:** the editor, debugger and trace
  viewer, the browser with no JavaScript, mail, contacts, calendar,
  feeds, chat, social, an office suite, music, photos, a player, calls
  and remote windows. These sit beside the applications already
  scheduled: Tracker, rio, the shell's tools, games (V9) and the Ghost
  (V10). Applications only one project planned (Paint, Draw, Notes,
  Reminders, Stickies, printing, a CD ripper) wait for decisions of
  their own. The exception is todhchai's Recorder, which Studio
  subsumes (D96).
- **One way to build an application.**
  - A protocol is a service that stores standard files with attributes
    in Taisce and serves a node. An application is a live query plus
    that node, holding no socket or key.
  - Applications reach each other through the plumber.
  - Formats come in through translators.
  - Media moves through processes joined by rings, seen in the patch
    bay, not a second graph.
  - Extensions are plug-in processes (D92).

  Each of these replaces something every application would otherwise
  repeat. None wraps another layer.
- **Proposed milestones,** after V10:
  - V11, reading and writing: browser, editor, debugger;
  - V12, communications;
  - V13, documents;
  - V14, media;
  - V15, Studio (D96);
  - V16, calls and remote windows.

  Studio may move up to follow V14 directly. That is the owner's call.

Not chosen:

- A web runtime of any size: JavaScript, Wasm from the network, the
  Web APIs, or a browser engine embedded in an application.
- todhchai's htmx-style extensions to the browser. They turn pages
  into application interfaces.
- Third-party language servers on the device. The editor reaches them
  on the developer's host over cpu (D4).
- NeoVectra's vendored engines and decoders (NetSurf's libraries,
  single-file codecs, tree-sitter), under D4.
- Lua for user functions (D92).
- A native document format of our own (todhchai's office research left
  it open). It would be a new format where a standard exists.
- The union of both projects' lists. That would be applications
  planned by one side without the other's design or agreement.
