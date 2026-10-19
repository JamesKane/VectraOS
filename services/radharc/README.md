# Radharc

The compositor (D107), lifted from todhchai's `services/radharc` (its
M4c to M6m) and ported onto this system. radharc(4) is its page; the
protocol's are radharc-compositor(5), radharc-window(5),
radharc-windows(5) and radharc-handoff(5).

```
services/radharc/
  Main.swift            bin/radharc: the framebuffer, the latch thread, the
                        windows' servers, input routing, the tree
  radharc.manifest      service windows (the desktop's images only)
  lib/                  module Radharc, tier 0, tested hosted
    Scene.swift         windows, stacking, focus, window management,
                        the display list and the CPU renderer (lifted)
    Decorations.swift   the decorations' colours, from a resolved theme
    Protocol.swift      RadharcIPC: Compositor, Window, Windows, Handoff
    InputEvent.swift    a window's input event, 40 bytes (lifted)
    WindowInput.swift   a window's input ring: the one ring, a counter doorbell
    Devices.swift       /dev/kbd's and /dev/mouse's messages as events
  idl/                  the C header and the protocols' baselines (idlc)
  tests/                RadharcTests (scene, decorations, input)
  tests/native/         bin/desktop-test and its manifest (boot-desktop)
```

## What changed from todhchai's

- **The vblank is Radharc's own** (D27: no display timeline). The latch
  thread keeps t0 plus n periods and sleeps to each; a change adds to a
  work counter, which the thread waits on (D23: no event object).
- **Counters only add** (D25): a release counter is raised to a value by
  adding the difference.
- **A window's input is on the one ring** (D43), its doorbell a counter,
  in place of todhchai's own `TDIR` ring and an eventpair's kick.
- **View tokens are channel ends** (D107), whose peer Radharc keeps.
- **Input is kbdfs's `/dev/kbd` and the mouse's `/dev/mouse`** (D83), in
  place of the input service's focus ring: a key's usage comes back from
  the keymap, and the pointer is absolute in the screen's pixels.
- **The decorations are the theme's** (D107, D91): `window.body`,
  `window.tab` and `desktop`, where todhchai's Scene hardcoded Neon
  Tab's colours.
- **The protocol starts again at version 1**, without what this step
  doesn't serve: accessibility (out of scope), buffer collections and
  direct scanout (the display class), the privileged services, secure
  surfaces and approvals (with the trusted prompt, D111), and nesting.
- **Strings are compared as bytes**: tier 0 links no Unicode tables, so
  the window list's entries have an `==` of their own.

## The desktop's images

Every manifest in an image starts at boot, and Radharc takes `/dev/kbd`
from the console's shell, so it is only in the desktop's images:
`bootfs-desktop.img` (`vx boot --desktop`) and `bootfs-desktop-test.img`
(boot-desktop, which runs desktop-test to its end and checks the
screendump with `vx check-pixels`).
