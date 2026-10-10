# ADR-0056: libvx level 2's first calls, and libvxui.so

Status: proposed, 2026-10-10. M7 step 7g2a, for hot reload (03 §6.1, steps 7g2b and 7g2c).

## Context

Hot reload maps an app's code image, `app.so`, into a running host, and the image calls the toolkit. The toolkit must be one copy in the process: `vxui`'s state (its app, its windows, the connection to the window server) and `libvx`'s (the namespace, the heap, the loop) cannot be duplicated between the host and each image. So `vxui` must be a shared object, as 09 §4.8 and ADR-0047 intend, and the host a dynamic program on `libvx.so` and `libvxui.so`. That is the known gap 7e2a recorded: `vxui` is a header library compiled into each program, because it reaches past `libvx`'s public calls to open a window's channel, the window server's open-with-a-channel (9Px's srv extension, 02 §3.3), and since 7g1b1 to write frame spans.

The host also has to map an image into itself after it started. ADR-0047 left that to "the hot-reload host, later", with `lib/vx-dl` written to serve both. A native program reaches only `libvx`, so it must be a `libvx` call, as `dlopen` is libc's.

ADR-0004 governs the ABI: levels only add, a call after level 1 is declared inside `#if VX_TARGET_ABI >= n`, `libvx.so` exports exactly what the public headers declare, and a frozen level's export list is held by every build. Level 1 was frozen at M6's close. There is no level 2 yet.

## Decision

1. **Level 2 opens as a draft** (`VX_ABI_LEVEL` 2, M7 step 7g2a). Until it is frozen, the build holds `libvx.so` to every symbol of level 1's list (`abi/levels/1.symbols`) and allows more; its new calls are declared inside `#if VX_TARGET_ABI >= 2`. It is frozen at a milestone's close the user names, with its own behaviour suite, which starts with this step's test (`imagetest`, scenario `image`). Each file of the suite is marked with the level that added it (`BEHAVIOUR_SUITE` in build.c), so a release while level 2 is a draft still holds level 1's files to `abi/levels/1.behaviour`.
2. **`vx_open_post(path, &channel)`** (`<vx/file.h>`): opens a file whose server answers with a channel (9Px's srv extension): a window from `/wsys/new`, a posted service. The file is closed once the channel is had.
3. **`vx_span_begin()` and `vx_span_end(start, what, flow)`** (`<vx/trace.h>`): a span into the process's profiling ring, as the 9Px client and server write theirs (20 §5); one predictable branch while `/proc/trace` has spans off. `what` is a message type, 9Px's or one of the frames' (`VX_SPAN_FRAME_*`, 7g1b1).
4. **`vx_image_open(path, &image)` and `vx_image_symbol(image, name)`** (`<vx/image.h>`, `lib/vx-dl/image.c`): a code image, a shared library, mapped into the running process and bound against what is loaded, the executable first, then the libraries in load order, then the image itself; its initialisation array run. It is never unmapped (03 §6.1: a reload's old images stay mapped, so pointers into them stay valid), and each open maps a fresh copy, at a new address, even of a path already open. An image with TLS is refused (dynamic TLS is not implemented, ADR-0047 item 6), as is one needing a library not yet loaded. The image is copied into fresh memory, never mapped from the file's pages, so a build renamed over its path leaves it as it was; it takes part in its own binding only, so no image binds against one opened before it. `vx_image_symbol` finds a defined, exported function or object by name, or null.
4a. **`vx_vmo_size(vmo, &size)`** (`<vx/sys.h>`): a VMO's size in bytes, through any handle to it (`vmo_op`'s `VX_VMO_SIZE`), which a receiver of a buffer checks its descriptor against (`lib/vx-buffer`), and so `libvxui.so`.
5. **`libvxui.so`:** `vxui.h` is its interface, each call marked `VXUI_API` as `libvx`'s are `VX_API`: static in a unity build, exported when the library is built, a plain declaration for an app. It links against `libvx.so` and holds its own copies of code with no state of its own to share (the font port, `lib/vx-font`, `lib/vx-buffer`, the window and input protocols' headers). It is at `/lib/libvxui.so`. Its exports are written beside it (`usr/lib/libvxui.symbols`), held as `libvx`'s are once it is frozen, with `libvx`'s level 2.
6. **First-party programs still compile `vxui` in** (ADR-0004: unity-built through the same headers), as they compile `libvx` in; an SDK app (`native`) links `libvxui.so`.

## Consequences

- An SDK app is a dynamic program on two shared objects; a fix to either reaches every app without a rebuild, and hot reload has one toolkit to keep across reloads.
- Level 2 is a draft: a program built for it may break until it is frozen. Level 1 programs are unaffected, which the build checks.
- Swift (ADR-0048): VectraOS 2 is level 2, so `@available(VectraOS 2, *)` marks what Swift adds with it, and while it is a draft `#available(VectraOS 2, *)` is already true on a running system. swift-on-vectra's `swifta` expects a level-2 system.
- Old code images accumulate for a session: a few megabytes over a long one (03 §6.1).
- `vx_image_open` is a binary loader in every process that calls it, over files the caller names; it maps them as `/lib/ld-vx` maps libraries, with the same checks (`lib/vx-dl`), and needs no right beyond reading the file.
