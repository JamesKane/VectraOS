# The display engine protocol

Status: draft, written for M7 step 7b2 (ADR-0026 item 2; docs/21 §2 item 4). `simplefb` (7b3) and virtio-gpu (7b4) are its back ends and `displayd` its one client; `lib/vx-driver/engine.c` is the back ends' shared half (the session, the vblank timer). `lib/vx-driver/displayproto.h` is its C definition, and `lib/vx-buffer/buffer.h` the buffers it carries.

A back end knows its hardware and nothing else (ADR-0026 item 1): it scans out images, tells `displayd` what it has and when a frame is on screen, and keeps no client state. Policy, EDID parsing, modes and the vblank Counters are `displayd`'s. Its shape is Fuchsia's display engine's: there are no CRTC, encoder or connector objects in it.

## 1. A session

A back end serves `displayd` on its post. `displayd` sends `CONNECT` (`0x7073_6964`, "disp") with `channel_call`; the reply is a `vx_msg_header` with one handle, the session's channel. A back end serves one session; a second `CONNECT` while one is open is refused (`flags` a negative status, no handle). The session ends when either end closes it; a back end whose session ends puts the firmware's picture back (ADR-0026 item 3).

On the session:
- **requests** go by `channel_call`, each answered by one reply with its `txid`: a `vx_display_msg` whose `h.flags` is 0 or a negative status, and whose `arg` words are the request's answer;
- **`APPLY`** is one `channel_write` with no reply: a flip is one message;
- **events** come unasked, with `txid` 0.

## 1a. `displayd`'s client

`displayd` serves its one client, winsrv, the same protocol (M7 step 7d1a), as Fuchsia's coordinator gives its client the engine's shape (`fuchsia.hardware.display/coordinator.fidl`: `ImportImage`, `CheckConfig`, `CommitConfig` with a stamp, `OnVsync` with the stamp shown). The client sends `CONNECT` on `/srv/outputs`, the post `displayd`'s files are served on, and is answered with a session and `ADDED`. `displayd` passes its requests through with its own guards:
- its stamps are mapped to `displayd`'s own, and `VBLANK` comes back in the client's numbering: every vblank, with stamp 0 before it has applied anything, so its frame clock ticks from the start;
- an `APPLY` that differs from its last checked configuration in more than its images is checked first, and a failure ends the client's session, never `displayd`'s with the back end; an `APPLY` naming an image it did not import ends it too;
- its images are released when it goes, and the picture it left stays on screen;
- while it holds the output, `displayd`'s own `ctl` `pattern` and `blank` are refused (`BAD_STATE`).

A second client is refused (`BAD_STATE`).

## 2. Requests

| Ordinal | Request | Reply |
|---|---|---|
| `INFO` (1) | a header | `vx_display_info`: the protocol version (1), outputs (at most; 1 in version 1), layers per output, the formats a layer takes (`VX_FORMAT_*`, linear), constraints (`CONTIGUOUS`: physically contiguous memory; `WC`: draw into it write-combining), the alignment of an image's start and the highest physical address it may reach (0: any) |
| `IMPORT` (2) | `vx_display_import`: a vx-buffer's descriptor, with its memory and timeline as the message's two handles | `arg[0]` the image's id, or a status: `INVALID` for a descriptor `vx_buffer_check` refuses or a format the back end has not, `RANGE` for one past its VMO, `NO_MEMORY` for no room for another |
| `RELEASE` (3) | `arg[0]` an image's id | nothing; an image on screen is let go once a vblank shows another |
| `CHECK` (4) | `vx_display_check`: a configuration (§3) | `flags` 0; or a status, and `arg[0]` the first layer that failed (-1 for the mode) |
| `APPLY` (5) | `vx_display_apply`: a stamp, a configuration, and the damage (§4) | none |
| `POWER` (6) | `vx_display_power`: an output and on or off | nothing |

## 3. Configurations

A `vx_display_cfg` is one output's: its mode and up to `VX_DISPLAY_LAYERS` layers, bottom first. A layer is an image (an id from `IMPORT`) or a solid colour (XRGB8888), with a source rectangle in the image, a destination on the output, an alpha (255 opaque) and a rotation in quarter turns. A mode is a width, a height and a refresh in millihertz; `FIRMWARE` marks the mode the firmware left.

`CHECK` says whether the back end can show a configuration, and why not: it never fails for a reason `APPLY` could have. A configuration that passed `CHECK` stays valid when only its layers' images change, so a flip needs no new check (ADR-0026's hot path).

## 4. Apply and vblank

`APPLY(stamp, cfg, damage)` shows a checked configuration from the next vblank. Stamps strictly increase. It never fails: a back end refuses only what `CHECK` would have, and an `APPLY` of such a configuration is a protocol error that ends the session.

The damage is the rectangles that changed since the stamp before, at most `VX_DISPLAY_DAMAGE` (none: everything). A back end that copies (simplefb, from an image into the framebuffer) or flushes (virtio-gpu's transfer and flush) covers the damage, not the screen (21 §2 item 4).

`VBLANK(output, time, stamp)` comes once a refresh while the output is on, with the newest stamp on screen and the time on `vx_clock`. A back end with no vblank interrupt (simplefb, virtio-gpu) times it at its output's refresh, never at a fixed rate. `displayd` signals the output's vblank Counter from it. An image an `APPLY` replaced is the back end's no more once a vblank shows the newer stamp; the back end signals nothing, keeping no client state, and `displayd` signals the image's timeline then, with the stamp that last showed it.

## 5. Events

| Ordinal | Event |
|---|---|
| `ADDED` (0x101) | `vx_display_added`: an output, its preferred and current modes, and its raw EDID after the record (`edid_len` bytes; 0 for the firmware's framebuffer, which has none). Every back end first adopts what the firmware left (ADR-0026 item 3): its first `ADDED` has the firmware's mode as current, marked `FIRMWARE` |
| `REMOVED` (0x102) | `arg[0]` an output |
| `VBLANK` (0x103) | `vx_display_vblank` (§4) |

## 6. Version 1 leaves out

Writeback, colour management, VRR and HDR scan-out (ADR-0026's consequences; the `/wsys` records carry those fields, the engine does not: 21 §2 item 9), several outputs on one back end, and cursor planes. Each comes as a later version with the back end that first needs it.
