# The `input` class protocol

Status: draft, written for M7 step 7c1 (docs/21 §2 item 6). `drv-virtio-input` is its first driver and `inputd` its one client; winsrv (7d) reads `inputd`'s streams. `lib/vx-driver/inputproto.h` is its C definition.

An input driver reports one device, a keyboard or a pointer, as records: what changed, when, and the state after it. It keeps no policy: no keymap, no repeat, no acceleration, no focus. Those are `inputd`'s and `winsrv`'s (03 §5).

## 1. A session

A driver serves `inputd` on its post (`/srv/input0`, `/srv/input1`, … in the order `devmgr` finds the devices). `inputd` sends `CONNECT` (`0x706e_6963`, "cinp"); the reply is a `vx_msg_header` with one handle, the session's channel. A driver serves one session; a second `CONNECT` while one is open is refused (`flags` a negative status, no handle). `inputd` sends `CONNECT` on every post a driver may serve without waiting: a post with no driver never answers.

On the session the driver sends, unasked:
- **`DEVICE` (1)** once, first: `vx_input_device`, the protocol version (1), the kind (`KEYBOARD` 1, `POINTER` 2), a pointer's axes (`ABSOLUTE` 1, `RELATIVE` 2, `WHEEL` 4), an absolute pointer's range (`x_max`, `y_max`: x and y run from 0 to them), and the device's name;
- **`EVENTS` (2)** each time it wakes with input: a count and that many records of its kind, at most 64. Records are batched per wake but never merged: a report the device made is one record (01 §5's rule, `getCoalescedEvents`'s).

`inputd` sends nothing in version 1. A driver whose session ends keeps the device and waits for the next `CONNECT`.

## 2. Records

Every record has `time`, on the one clock (`vx_clock`'s nanoseconds, 01 §4.4): when the device reported it, or when the driver saw the report if the device gives no time (virtio-input gives none).

**A key**, `vx_input_key` (72 bytes): the key's HID usage (page << 16 | id: the keyboard page is 7, mouse buttons the button page, 9, from 1), the action (`UP` 0, `DOWN` 1, `REPEAT` 2: a device's own repeat; the repeat a user sees is `winsrv`'s), and the **held set** after it: up to 12 usages and the modifiers they make (`SHIFT`, `CTRL`, `ALT`, `META`, `ALTGR`, and `CAPS`, caps lock's toggle). The held set travels with every key, as 9front's kbdfs sends it (kbdfs.c:670-700), so a chord or a focus change needs no history.

**A pointer**, `vx_input_pointer` (40 bytes): one report: the absolute position (in the device's range; 0 for a relative device), the relative motion, the wheels' turn, and the buttons held after it, bit n-1 for button n.

## 3a. `inputd`'s client

`inputd`'s one client, winsrv (M7 step 7d1c), sends `CONNECT` on `/srv/input`, the post `inputd`'s files are served on, and is given a session, as `displayd` gives winsrv one (docs/proto/display.md §1a). On it every device's `DEVICE` (each known one at once, and each new one as it comes) and `EVENTS` arrive as the drivers sent them, each message's header `flags` the device's post number, and `GONE` (3, a header alone) when a device's driver has gone. While a client holds the input, `inputd` types nothing into the console. A second client is refused (`BAD_STATE`).

## 3. `/dev/input`

`inputd` serves the devices as text on `/srv/input`, unioned into `/dev` (inputd(8)): `input/N/info` and `input/N/events` for the device on post N, and `input/keyboard` and `input/pointer`, every keyboard's and every pointer's records in one stream. A record is a line; a key's carries its unmodified rune too (03 §5), from the US layout until 7d2's keymaps.

## 4. Version 1 leaves out

LEDs (caps lock's light), pens (proximity, tool identity: F-212), touch, gamepads (`/dev/input/gamepads`, F-214, M9), and devices' own timestamps. Each comes as a later version with the driver that first needs it.
