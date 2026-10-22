# D122. Step 7: the manual as hypertext is guide, a Kit app with AmigaGuide's buttons whose links only move it, opened by the plumber's `name(N)` rule; hot reload loads fresh copies of a code image into a host template over a state block at a fixed address (2026-10-22, the guide and plugin.replace built; hot reload proposed; for the owner's review; extends D85, D86, D92, D107)

V5's step 7 (D107): a guide viewer with AmigaGuide's Contents, Index,
Retrace and Browse, its links never running anything, and the plumber's
rule for `name(N)` (D85, D86). Then hot reload: `system/ld`'s fresh copies
with TLS, the SDK's host template, its state block and `@HotState`
(D92, docs/plugins.md). V5's exit has the reference app hot reloading
from the dev machine within `reload.module_10k`, and a layout policy
replaced live with no frame missed (`plugin.replace`). No donor has code
for either: todhchai's hot reload is only in its docs. The owner set the
goal of finishing V5 and left the choices here to the recommendations,
so this note is for their review.

## Decided: the guide

- **guide is a Kit app** (guide(4)) that reads the manual once from
  `/lib/man`:
  - The Contents lists the sections and their pages, with summaries.
  - The Index is every page's names and keys, in order.
  - A page is man(1)'s rendering, so the text is the same in a
    terminal and in the window. Every `name(N)` in it is a link.
- **A link only moves the viewer.** A link, a Contents entry or an Index
  word goes to a page of the manual. Nothing a page names is run, and a
  page holds no other kind of link.
- **Retrace** is a history of places. **Browse** is the page before or
  after in its section.
- **The plumber's rule:** text that is `name(N)` goes to the `man` port,
  so a page named in rc, a document or a window opens in guide. With
  nobody reading the port it is refused: the plumber doesn't start guide.
  guide is an app, and a 13 MB tier 1 program started for a word plumbed
  by mistake costs more than the refusal.
- **guide's window fits the screen:** 760x640, less if the screen is
  smaller (arm64's QEMU screen is 800x600).
- Its `status` and `ctl` let rc and tests drive it as its buttons do.

## Proposed: hot reload

As docs/plugins.md §2 has it, with these choices:

- **`system/ld` loads a fresh copy:** each load copies the image's
  segments into new memory at a new address, binds against what's
  loaded, and never unmaps an old image. TLS in a loaded image gets a
  block of its own beside the program's.
- **The host template** (an SDK file a program copies):
  - It maps the state block, a VMO, at a fixed address in a VMAR
    reservation.
  - It watches the image's file. At a frame's end, it loads the new
    image and calls its `update(state, events)`.
  - It refuses an image whose `@HotState` layout hash differs from the
    block's, unless the image exports `migrate`.
- **`@HotState`** is a macro in the IPC macros' plugin. It checks the
  type is `BitwiseCopyable` and emits its size and layout hash.
- **Remote:** `vx reload` builds the image on the dev machine and
  writes it through the cpu session's `/mnt/term`, renaming it into
  place. It reports `reload.module_10k`: save to the new code running.
## Decided: plugin.replace

- Radharc already took a layout registered under a name it has as that
  layout's replacement (D116). Now it also tells the old one to retire:
  radharc-layout(5) v11 adds `retire()`. master-stack exits with success
  on it, so `restart on-failure` doesn't start it again.
- Radharc's status counts the layouts `replaced` and the latches begun
  after their vblank (`missed N frames`).
- boot-workspaces starts `master-stack-next`, a second manifest running
  the same program beside the first. The test sees the replacement and
  the old one exit, then makes a call to the new one. It reports
  `plugin.replace`, the frames missed meanwhile, limit 0. It reads 0 on
  both arches.

## Found on the way: a short string corrupted on arm64

The plumber faulted on arm64, and not on amd64, routing `rc(1)` to
`man`. In `Rules.apply`, a nested function capturing the message as a
`var` returned the message's data. The String that reached the regex had
its discriminator byte at 0x85 rather than 0xE5: bits 61 and 62 were
cleared. So a small (inline) string was read as a large one, at a wild
address. Longer data, such as URLs, are large strings, and that bit
pattern doesn't hurt them, which is why only a short message showed it.
Dumping the String's words in between made it pass, so it depends on
how the code is optimized. A static `field(m, object)` read into a local
avoids it. The cause in the compiler isn't found; it is in CLAUDE.md's
pitfalls.
