# D111. The trusted prompt: Radharc draws it, answered only by physical input; factotum, Radharc's gated services and the file chooser ask through it (2026-10-18, decided; details proposed; the prompt and factotum's questions built 2026-10-19; extends D75, D82, D91, D107)

D107 puts the trusted prompt before Radharc's step, ahead of the
privileged services and their approvals. Today nothing can ask the
user anything. factotum has AuthSession's `needKey` and `needConfirm`
steps and a key's `confirm=` attribute, but it is headless, and each
question is answered no as it comes (factotum(4)). The surveys found
two donors:

- **todhchai** gates its privileged services in Radharc. An app opens
  `/svc/radharc/<service>`, and Radharc serves the channel or closes
  it according to a recorded grant. With no grant recorded, it holds
  the channel and sends an `ApprovalRequest` to the approver. The
  approver is the keyring, a client that draws its own panel and marks
  it `setSecure`.
- **NeoVectra's** window server draws the prompt itself
  (`/wsys/prompt`): a panel over every window, a black strip and a
  seal, answered only by physical input, with a click in its first
  half second ignored. Each open of the file is one question, in the
  shape of 9front factotum's `confirm` file.

## Decided

- **Radharc draws the trusted prompt.** The owner chose this
  (2026-10-18) over factotum drawing its own secure surface. The
  trusted path is then the compositor's alone and depends on no
  client: no client can draw it, overlap it or press it.

## Proposed

- **How it looks.** The prompt is drawn in the `trusted` material,
  which no theme can name, use or imitate (theming.md §6, D91). The
  rest of the screen dims around it, and a capture shows it as black.
  It names, from what Radharc knows rather than from what the asker
  says:
  - the app that is asking, by the launcher's service name for the
    process at the channel's other end;
  - what it asks for;
  - the answers it may be given.
- **Only physical input answers it.** Radharc reads `/dev/kbd` and
  `/dev/mouse` itself. Its `inject` service and any client's events
  never reach the prompt. A click in the prompt's first half second is
  ignored, as NeoVectra's is, so a click aimed at what was there
  before doesn't answer it. While the prompt is up, every other window
  gets no input. Escape is deny.
- **Questions are one at a time, queued.** An asker's question stays
  queued until it is answered, or until the asker closes the channel,
  which withdraws it.
- **The answers are ghost.md's four:** *once*, *this session*,
  *always*, *deny*. A question may offer fewer; factotum's `confirm`
  offers *once* and *deny*. *This session* lasts until the asking app
  exits or Radharc restarts. *Always* is recorded:
  - a gated service's grant as a Taisce attribute, `Grants:APP.SERVICE`
    after todhchai's `Grants`, on step 1's Settings shim;
  - a key's answer in the key's own `confirm=` attribute, kept by
    factotum.

  Settings lists recorded grants and can revoke them (step 4). Revoking
  a grant closes the channels it opened.
- **Askers.**
  - **Radharc's gated services** (`capture`, `inject`, `observe`,
    `shortcuts`, `secure`) work as todhchai's `gated` does: Radharc
    holds the channel while the question is open, then serves it or
    closes it. A handle can't be forged, so there are no tokens, and
    the capability is the channel the app opened.
  - **Other services ask through `/svc/windows/prompt`,** a Node file
    in Radharc's tree, in the shape of NeoVectra's file and 9front's
    `confirm`. Opening it and writing one question asks it, a read
    waits for the answer, and closing it withdraws the question. Only
    a manifest with `grant windows prompt` may open it: factotum now,
    the Ghost's approvals (V10) later. The question is an ndb(6) entry
    and names the app it asks for: `ask=confirm app=... proto=...
    user=... dom=...`. Radharc shows that name as the asker's
    and its own name for the granted service beside it.
  - **factotum's `needKey`** asks with `ask=key` and the key's
    template. Its secret fields (the `!`-prefixed ones) are typed into
    the prompt, where they are drawn as bullets and capture sees
    nothing. Their values go back only on the channel that asked, and
    Radharc keeps no copy.
- **The file chooser is a powerbox.** An app asks its window to
  `choose` (an open or a save, with its types), and Radharc shows the
  chooser on the trusted path. The chooser is Tracker's listing as a
  program that Radharc starts under the user's namespace, embedded by
  a view token in the prompt's frame. What the app gets back is a
  channel to the chosen file, open for reading or writing as it asked.
  It never gets a path or the namespace it came from (todhchai
  architecture §17: "the file chooser hands over a handle"). The
  question and the chooser's frame are designed here; the chooser is
  built with Tracker (step 4), and `choose` comes with the SDK (step 3).
- **With no Radharc, there is no prompt.** factotum keeps refusing what
  would ask, as factotum(4) says today. The Ghost's console prompt is
  its own design (ghost.md).
- **The lock screen** is drawn on the same path, in the same material,
  with the same input rule (step 4, after its own design).

## Built (2026-10-19)

The prompt, `/svc/windows/prompt` and factotum's questions, as
proposed, with these settled in the building:

- **The look.** A panel of its own colours, after NeoVectra's: a black
  strip with its heading, the gunmetal seal, bevelled buttons, deny
  leftmost and once rightmost. The rest of the screen is dimmed to a
  quarter of its light (in light, D110). Its text is the console's 8
  by 16 font, as the titles' is, until the kit's text reaches Radharc.
  No theme part or role feeds it, so there is nothing for a theme to
  name: the theme check needs no new rule.
- **Capture.** No capture service exists yet; `pixel`, which any
  client can read the screen through, reads the panel as black.
- **Arming covers keys too.** Escape, and return in a key's question,
  wait the same half second as a click: a key typed into the window
  that was focused mustn't answer either. Typed text needs no arming.
- **Typed text is kbdfs's `c` messages,** shifted as typed, rather
  than the key events, which carry only the unshifted character.
- **The entry.** `ask=`, `app=` and `answers=` (a comma list from
  once, session and always; once if none); `name?` and `!name?` are a
  key's fields; the rest is shown as written, at most 256 bytes and no
  secret value. The reply is the answer's word, then a key's fields:
  `once user=jk !password=hi`.
- **factotum reaches it with `use windows optional`,** a new word for
  the launcher (manifest(6)): factotum is in every image and Radharc
  only in the desktop's, and factotum mustn't fail to start where
  Radharc doesn't. Elsewhere it refuses as before.
- **A question factotum asked stays up after its session goes,** until
  answered. factotum's thread waits in the prompt's read, and closing
  a channel under a call in flight doesn't end the call, so factotum
  can't withdraw it. In factotum(4)'s BUGS.

Not yet: the gated services and their recorded grants (Radharc refuses
every `grant windows` but `prompt`), the file chooser (step 4) and the
lock screen (step 4).

In step 3 (2026-10-19), `choose` came with the SDK as an API only, the
owner's choice: the Window protocol's `choose(mode:types:name:)`
(version 6) and the SDK's `Loop.choose`, which Radharc refuses as
`unavailable` until Tracker's listing is embedded in the prompt's frame.
How the chosen file's channel comes back is settled then.

In step 4 (2026-10-21), the Settings store and `Grants` (`system/settings`,
`settings(2)`, D113) landed: `Grants:APP.SERVICE` bool attributes on
`/data/Settings/Grants`, with `Grants.recorded`, `Grants.record`,
`Grants.list` and `Grants.revoke` (and `rc`'s `attr -d`), waking watchers
on `/data/Settings` when a grant is recorded or revoked.

## Left out

- A secure attention key. Nothing in QEMU or on the first board needs
  one while only Radharc reads the keyboard; it is reconsidered with
  the lock screen.
- Approvals as tokens with an expiry (NeoVectra's): a handle that
  revoking closes already does it.
