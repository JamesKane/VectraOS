# D175. Agents beside the user: Radharc's `observe`, `inject` and `capture` are designed for an agent that works while the user works, by the window and by meaning first, never by taking the user's pointer or focus (2026-11-21, proposed; extends D90, D111, D116)

A record of an exploration, kept so the design isn't lost before
`observe`, `inject` and `capture` are built. D116 left them under "Not
yet", to take `shortcuts`' path when something needs them. Nothing here
is scheduled.

## The prompt for it

A complaint about Wayland for computer-use agents (CUAs) went round in
November 2026. Its points: each compositor offers a different set of
capture and injection features; some can click without stealing focus
(GNOME) and others can't (niri), so an agent takes the user's focus and
can't work beside them; vendors write code for each compositor; and
X11's open model (background input, more than one cursor) suits agents
better.

What holds and what doesn't:

- **The fragmentation is real.** Core Wayland has neither injection nor
  capture. They live in xdg-desktop-portal (RemoteDesktop, ScreenCast),
  libei, and protocols that only some compositors support, and focus
  behaviour differs from one compositor to the next.
- **Security didn't cause it.** Removing ambient authority means the
  authority must be granted through an API. It doesn't mean there must
  be many APIs. Linux has many because it has many compositors and no
  owner.
- **X11 is not the model.** XSendEvent's events are marked synthetic,
  and many toolkits drop them. XTEST drives the user's own core pointer.
  MPX's second cursors exist, but toolkits barely support them. Any
  client can read every key and every pixel, which is the last thing to
  put beside an agent that text can steer.
- **Windows and macOS are not the model either.** `SendInput` and
  `CGEventPost` move the real cursor, and macOS gates them behind TCC's
  Accessibility and Screen Recording permissions. Agents there mostly
  take over the machine. Where they work well, they work through UI
  Automation and AX, the accessibility trees, not through pixels.

The lesson: screenshots and synthetic clicks are a workaround for apps
that don't say what they mean. An agent should first be given meaning,
and pixels and events only as the fallback.

## Where VectraOS already stands

- **There is one compositor,** Radharc (principle 1), so its gated
  services are the one interface on every machine. The fragmentation
  can't arise.
- **The Ghost doesn't see pixels** (`docs/ghost.md` §8.1). Its tools
  are the namespace's verbs from `.schema` and `.help`, and its
  recordings name objects, not pixels (§7).
- **Nothing injected answers the trusted prompt** (D111): `inject` and
  every client's events never reach it, so an agent can't approve its
  own grants.
- **The clipboard is focus-gated** (radharc(4)): a client in the
  background is refused, so an agent beside the user can't read it.

## Gaps this would close

1. `capture`, `inject` and `observe` are named in D111 but not designed
   (D116, "Not yet"). Built naively, as synthetic `/dev/mouse` events
   delivered to the focused window, `inject` would repeat the niri
   problem.
2. Kit builds an accessibility tree every frame (uicore(2), AccessTree)
   but doesn't give it to Radharc, which has no readers (kit(2), BUGS).
   The roadmap puts accessibility beyond the High contrast theme out of
   scope.
3. Radharc has one pointer and one focus: keys go to the focused window
   (radharc(4)), and no second actor is described.
4. The Ghost refuses pixels for itself, but D111's `capture` can be
   granted to any app. A third-party CUA would be such an app. Which
   services such an agent may hold is undecided.

## Proposed

- **One actor model.** An agent's events, whoever runs it (the Ghost or
  a third-party app), go to a window it names, never to "whatever has
  focus". They don't move the user's pointer, change focus, raise the
  window or show another workspace. The user's own input always wins: a
  window the user is typing in or dragging over holds the agent's
  events until the user stops (how long is open).

- **`observe` comes first: meaning, by the window.** A grant names one
  or more windows, or "the windows of app X". The holder reads each
  window's AccessTree as Kit packs it (role, label, value, states and a
  stable node id), streamed on the one ring as it changes, and acts on
  nodes by id: `press`, `set` (a value or text), `select`, `scroll`,
  `focus` (inside the window only, not Radharc's focus). The window's
  client carries out the action as if its own widget had been used, so
  no coordinate or pixel is involved. Kit's programs get this with no
  work of their own, which is the reason to build the tree export (gap
  2) before `inject`. Screen readers are the same reader, so this also
  starts accessibility proper.

- **`inject` is the fallback: events, by the window.** For a window with
  no tree (tier 1 programs, the foreign personality of
  `docs/foreign.md`, a canvas), the holder sends pointer and key events
  in that window's coordinates. Radharc delivers them only to that
  window, and flags them as injected to the client, as D111 already
  requires toward the prompt. Radharc draws the agent's own cursor in a
  material themes can't imitate, labelled with the agent's name, and
  never touches the user's. There is one agent cursor per grant, so
  several agents can be seen apart. Kit's text fields take an injected
  key the same way as a typed one; whether a client may refuse injected
  events (as games refuse XSendEvent) is open.

- **`capture` by the window, the screen a stronger grant.** A window's
  frames are handed to the holder as Radharc already holds them, by
  ownership of one VMO per frame and never a copy of the pixels (the
  unified-memory rule). The trusted prompt and secure surfaces show as
  black, as D111 says. The whole screen is a separate grant, asked for
  by name, which the prompt words more strongly.

- **Grants are D111's.** Each service is asked for through the trusted
  prompt, per app and per window set, with D111's four answers, and is
  recorded as `Grants:APP.SERVICE` when the answer is *always*. Radharc's
  bar shows a lamp while any `observe`, `inject` or `capture` channel is
  open, naming its holder, and Settings revokes it, which closes the
  channel. `ctl` and `status` lines report each holder, its windows and
  its event counts.

- **The Ghost stays without pixels.** Its sessions may be given
  `observe` on named windows through their namespace template, since a
  tree is meaning, which §8.1's rule allows. `capture` and `inject` stay
  outside its templates. A third-party CUA may ask for all three, but
  the prompt offers `observe` first and says when an app wants pixels or
  events instead.

- **Recording joins up.** ghost.md §7's recording of `wctl` verbs gains
  `observe`'s actions, so a recorded GUI task becomes a script of node
  ids and verbs, not of coordinates.

## Open

- How long the user's input holds an agent's events, and whether the
  agent is told it was held.
- How stable a node id is across a window's frames and layouts, and
  what Kit promises about it.
- Whether a client may refuse injected events, and how a foreign game
  that never asks is protected from them.
- The agent cursor's look, and whether a client is told an agent cursor
  is over it (for hover).
- Whether the whole-screen grant exists at all, or only "every window,
  each named".
- What an `observe` holder sees of a window on a workspace not shown,
  and of a locked screen (proposed: nothing while locked).
- Each service's budgets (an action's latency, a capture's frame cost)
  come with the step that builds it, with their checks.

## Not chosen

- **X11's model:** any client injects and reads anything. That is
  ambient authority, and an agent is the client that most needs to be
  confined (principle 26).
- **Synthetic events at `/dev/mouse` or `/dev/kbd`:** they would take
  the user's pointer and focus, and couldn't be told apart from the
  user's own input, which the trusted prompt depends on.
- **Pixels first, with OCR or vision to find widgets:** it is slower,
  breaks when a theme changes, and gives a model more than it needs,
  where Kit already knows what every widget is.
- **A second protocol for agents beside Radharc's gated services:**
  `shortcuts` showed the path, and these take it (principle 1).
