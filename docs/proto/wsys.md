# The window protocol (`/wsys`)

Status: draft, written for M7 step 7d1b (docs/21 §2 items 1-3 and 8; 03 §4-5). `winsrv` serves it; `vxui` (7e2) is its first library. `lib/vx-wsys/wsysproto.h` is its C definition of the window channel's records.

## 1. The tree and attach

`winsrv` serves `/srv/wsys`; a namespace mounts it at `/wsys`. The aname chooses what the attach reaches, as rio's does (rio/xfid.c:168-243):

- **`new [-dx W] [-dy H]`**, rio's wctl words: a new window, W by H (640 by 480 if not given), and the attach's root is its directory. That is the app's `/wsys/self`: its own window and nothing of anyone else's (03 §5.7).
- **empty**: the whole tree, every window, which is a grant (03 §5.7: `wm`, the shell, the palette, assistive technology).

```
/wsys/
    info                  version=1 output=fb0 width= height= frames=
    outputs/              displayd's tree, mounted here
    windows/N/            a window, N from 1, never reused while winsrv runs
        ctl               move X Y · resize W H · title TEXT · raise · close
        info              id= title= x= y= width= height= config= presented= dropped=
        frame             its last FRAME and FEEDBACK, as text
        surface           opened (9Px's srv extension): the window's channel
```

A window lives while a fid holds a node of it or its channel is open; the last to go takes it. New windows are cascaded from the top left, inside the screen, and stacked on top.

`ctl`'s geometry is synchronous (03 §5.1): a write returns once it is applied. `resize` makes a new configure (§3), keeping the window's pixels where they still fit and the window's grey beyond; `close` ends the window's channel, and the window goes with its last fid.

## 2. The surface

Opening `surface` (`ORDWR`) with 9Px's srv extension (docs/proto/srv.md) gives the window's channel beside the `Ropen`, as opening a post in `/srv` gives its connector. One app holds it at a time: a second open is refused while the first is held. `CONFIGURE` and a `FRAME` with the app's first credit are on it at once.

## 3. Records

winsrv to the app, unasked (`txid` 0):

| Record | Fields |
|---|---|
| `CONFIGURE` (1) | `seq` (the config_seq), the logical size, the size in pixels to draw, the scale over 120, the visibility (`visible`, `partial`, `occluded`, `hidden`), flags (`FOCUSED`, `INTERACTIVE`) |
| `FRAME` (2) | `seq` (the frame clock's count), `target` (the vblank a present made now is meant for), `prev_presented` (when the app's last present reached the screen), `refresh` (ns), `credits` (presents given back) |
| `FEEDBACK` (3) | the present's `seq`, `actual` (the vblank that showed it; 0 if dropped), `dropped`, `zero_copy` (0: composited) |
| `KEY` (4) | a key as `inputd`'s record has it (the usage, the action, the keyboard's held set and modifiers), its unmodified rune, and `SYNTHETIC` for an `UP` winsrv made (§4a) |
| `POINTER` (5) | the pointer in the window's coordinates (outside it while a press latches it), the buttons held after it, relative motion and wheels as the device gave them, and `LATCHED` when a press's latch delivered it |

The app to winsrv:

| Record | Fields | Answer |
|---|---|---|
| `ATTACH` (16) | a buffer id (1 to 4) and a vx-buffer's descriptor, its memory and timeline as the message's two handles | a call: the reply's `flags` 0, or `INVALID` (an id in use, a format winsrv does not take, a descriptor `vx_buffer_check` refuses) or `RANGE` |
| `DETACH` (17) | a buffer id | a call; refused while a waiting present names it |
| `PRESENT` (18) | `seq` (the app's own, rising), the buffer id, its `acquire` and `release` points on the buffer's timeline, the `config_seq` it was drawn for, and up to 8 damage rectangles (none: all of it) | its `FEEDBACK` |

## 4. The frame protocol

Its model is Flatland's (21 §2 item 2; flatland.fidl:494-528):

- **Credits.** A present costs a credit. An app starts with one, and each `FRAME` gives back the presents composited since the last, so an app can never queue unbounded frames, and winsrv never blocks. A present with no credit fails fast: it is dropped, its `FEEDBACK` says so, and its release point is signalled at once.
- **Latching.** At each vblank, winsrv takes the newest present of each window whose acquire point the buffer's timeline has reached; one not yet drawn waits for the next vblank. A present that a newer one replaces before it is latched is dropped, and its credit given back.
- **Release at composite** (21 §2 item 3). A latched present's damage is copied into the window's own backing, its release point is signalled at once, and the screen is composited from the backings. So an app that double-buffers never waits on winsrv, and what other windows uncover is redrawn without asking the app.
- **Feedback.** `FEEDBACK` comes when the vblank that shows the composited present arrives, with that vblank's time; that time is the next `FRAME`'s `prev_presented`.
- **Configure.** A present drawn for an older `config_seq`, at another size, is clipped to the window, and what it does not cover keeps its old pixels, for at most a frame; it is never stretched (03 §4, F-208).
- **Idle.** A window that does not present gets no `FRAME`, and with no damage winsrv applies nothing.

## 4a. Input and focus

winsrv holds `inputd`'s records (docs/proto/input.md §3a), so the console gets no keys while it runs (21 §2 items 6-7):

- **One pointer.** Every pointer moves it: an absolute one scaled from its range to the screen, a relative one by its motion, clamped to the screen. winsrv draws it as a cursor over everything.
- **Click to focus.** A press, the first button down with none held, focuses and raises the window under the pointer, and **latches** the pointer stream to it until every button is up (Fuchsia's mouse_system, mouse_system.cc:80-121; rio's, rio.c:560-639). Without a press, pointer records go to the window under the pointer.
- **Keys** go to the focused window. A window gets a key's `UP` or repeat only after its `DOWN`; one losing focus gets an `UP` for each key it still holds, marked `SYNTHETIC`. A key held across a change of focus is the new window's from its next `DOWN`.
- **Focus** is in `CONFIGURE`'s `FOCUSED` flag: a change sends one to each window it touches.

## 5. Version 1 leaves out

Rings for the records (a channel carries them: the rate of a window's records is a frame's), scale other than 1, visibility other than `visible`, `latency 2|3`, VRR's `target_min`/`max`, `present async`, viewports; decorations and the theme, keymaps, compose, key repeat and the IME (7d2); pens and touch.
