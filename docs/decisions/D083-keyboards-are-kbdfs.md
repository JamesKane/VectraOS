# D83. Keyboards are 9front's kbdfs, keyed by HID usages: drivers push them to kbin, kbdfs gives runes and the console (2026-10-17, decided; amends D82)

D82's table has the input class serving `/dev/kbd`, `/dev/mouse` and
`/dev/mousectl` itself, which would put a keymap in every keyboard
driver. 9front keeps keymaps out of drivers: USB's `nusb/kb` translates
the keyboard's HID usages to PC scancodes (its `sctab`) and writes them
to `kbin`, and `kbdfs(8)`, in user space, is the one place they become
runes; it serves the console too. The owner's direction (2026-10-17):
do it the 9front way, but keyed by HID usages, not PS/2's scancodes. PS/2
connectors have been gone from most hardware for a decade, every
keyboard on our machines is USB, and 9front's set-1 numbering is
`#b/scancode`'s legacy, a translation in every modern driver.

- **Keyboard drivers push HID usages to kbdfs's `kbin`**, as `nusb/kb`
  pushes scancodes: each record two bytes, a usage of the keyboard page
  (0x07: 0x04 `a` to 0xE7 right GUI) and 1 for a press or 0 for a
  release. A USB keyboard passes its usages through; virtio-input
  translates evdev's codes with one table. A driver host reaches `kbin`
  through its namespace: devmgr's manifest grants kbdfs's `kbin`, and
  devmgr gives each keyboard's host a mount of it at `/dev/kbin`, as the
  launcher gives `/bin`.
- **kbdfs serves the keyboard and the console**, after `kbdfs(8)`, mounted
  before `/dev`: `kbd` (`k` and `K` with the keys held, unshifted, on
  each press and release; `c` with the character typed, repeated at the
  repeat rate), `cons` and `consctl` (erase, kill and `^W` processing,
  reads up to a newline, `rawon` and `rawoff`; opening `kbd` turns cons's
  input processing off, as rio's opening it does), `kbmap`, `kbin` and
  `kbdin` (`k`, `K`, `c`, `r` and `R` messages injected). Its `cons` is
  the console's input (V2 item 8): the line editing the pty's discipline
  did moves here.
- **`kbmap` is keyed by usage.** `layer usage rune` lines, as 9front's
  with the usage where the scancode was; its layers are 9front's but for
  the escaped ones, which HID has no prefix for: none, shift, altgr, ctl,
  shiftaltgr, mod4, altgrmod4. kbdfs builds in a US map (9front's ascii
  defaults, by usage), and OTRUNC resets to it. 9front's map files don't
  carry over, and none are on the device (D4).
- **Mice give their records to a mouse service**, as 9front's drivers
  write `mousein` for its `devmouse`, which serves `/dev/mouse` and
  `/dev/mousectl`. It comes with the desktop (V5): nothing in V2 reads a
  mouse.
- **The one ring stays the bulk path** (D82): a `kbd` reader may attach its
  ring through Node's `attach` (D67), the records the same either way.
- **Written, not lifted** (D4): kbdfs is ours, in Swift, from the man
  page and checked against 9front's source, as rc is (D70).

The typed input class (`InputDeviceIPC`, its evdev slots and `open`,
V2 7d) goes; `drivers/input/lib` keeps the evdev-to-usage table. Amends
D82's input row; its net, block and audio rows stand.

Not chosen: PS/2 set-1 scancodes as 9front's (a dead protocol's numbering
at the centre, translated into by every modern driver); the keymap in
the input class's library, each driver serving `/dev/kbd` (a keymap in
every driver, and the console's line editing with no home); drivers
serving a `scancode` file for kbdfs to read, as `kbd(3)` does for PS/2
(the PS/2 path, backwards for keyboards that are all USB).
