# mouse

The pointer (D83), ours after 9front's devmouse (mouse(3)), in Swift
(D4). Pointer drivers write records to its `mousein`, as 9front's
`nusb/kb` does; manifests mount its tree at `/dev` after kbdfs's:

| File | What it does |
|---|---|
| `mouse` | `m` messages of 49 bytes, `x y buttons msec` each 11 wide and a blank, when the pointer has changed since the channel's last read, every change of the buttons queued (16 at most). A write `m x y` moves the pointer. |
| `mousein` | Records from drivers, a line each: `m dx dy b` relative, `A x y b` absolute, `a x y b` scaled from 0 to 2^31 across the screen, with an optional msec. Each channel's buttons are its own. A read gives the state without waiting. |
| `mousectl` | `buttonmap [xyz]`, `swap`, `scrollswap`, `accelerated [n]`, `linear`, `reset`. |

The screen the pointer stays inside is the boot framebuffer's, from the
boot data. Reads of `mouse` wait until there is a change: it is a Node
stream, the server holding the call (D84).

`lib/` (`Mouse`) is the logic, tested hosted (`MouseTests`); `Main.swift`
serves it. virtio-input writes its pointer's reports, gathered by
`drivers/input/lib`'s `PointerReport`; launch-test moves QEMU's mouse
through the monitor and reads `/dev/mouse` on every arch.

Against devmouse: each channel open at `mouse` reads its own messages
(devmouse refuses a second open); the wheel's buttons (8 and 16, up and
down; 32 and 64, left and right) are momentary, pressed and released for
each record that has them; a write to `mousein` may hold several
records; a writer that closes lets go of its buttons at once. Not yet:
`cursor` (the compositor draws the pointer, V5), the `r` resize message,
the screen's blanking (`blank`, `blanktime`, `twitch`), and Shift with
the right button as the middle.
