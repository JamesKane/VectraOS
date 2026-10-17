# kbdfs

The keyboard and the console (D83), ours after 9front's kbdfs(8), in
Swift (D4). Keyboard drivers push HID usages to its `kbin`; manifests
mount its tree before `/dev`:

| File | What it does |
|---|---|
| `kbd` | `k` and `K` messages with the keys held (unshifted), on each press and release; `c` with the character typed. While it is open, cons hears nothing. |
| `cons` | What was typed: lines cooked (^H a character, ^W a word, ^U the line, ^D the end of input), or runes as they come once raw. Writes go to the console. |
| `consctl` | `rawon`, `rawoff`; raw lasts while it is open. |
| `kbmap` | The keymap, `layer usage rune` lines, 11 characters a field. Layers are 9front's but the escaped ones (none, shift, altgr, ctl, shiftaltgr, mod4, altgrmod4); a US map is built in. |
| `kbin` | Usages from drivers: a usage of the keyboard page, then 1 pressed or 0 released. |
| `kbdin` | `k`, `K`, `c`, `r` and `R` messages, typed for someone else. |

Reads of `kbd` and `cons` wait until there are keys: they are Node
streams, the server holding the call (D84).

`lib/` (`Kbdfs`: `Keymap`, `Keyboard`) is the logic, tested hosted
(`KbdfsTests`); `Main.swift` serves it. launch-test types through QEMU's
monitor and reads both files on every arch.

Not yet, against 9front's: Alt's compose sequences, the `c` repeat at
the repeat rate (USB keyboards repeat in software), Kdel's interrupt
note (notes come in V3: it flushes the line), Ctl-Alt-Del's reboot
(`/dev/reboot`, V3), kbmap's OTRUNC reset, and per-writer key state on
`kbin` (every keyboard shares the modifiers held).
