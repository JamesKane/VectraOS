# D120. Outputs: the display class under devmgr, virtio-gpu's 2D path, several outputs arranged left to right with a scale each in 120ths, hotplug as an event, and suspend as a devmgr verb (2026-10-22, decided; the display class, virtio-gpu's 2D path and Radharc on its outputs built 2026-10-22; for the owner's review; extends D55-D62, D74, D82, D107, D110)

V5's step 6 begins with D107's designs: several outputs and device
suspend, before more drivers are written against them. todhchai built
the display class (`todhchai.display.device`, its M5a), a virtio-gpu
driver serving it, and Radharc composing into one attached image a
frame. It has one output and no hotplug, and its scale is n/120 for the
whole desk. NeoVectra's design names an output by its EDID: the
maker's PNP id and the monitor's name. The owner set the goal of
finishing V5 and left the choices here to the recommendations, so this
note is for their review.

## Decided

- **The display class is todhchai's, lifted, at version 2.**
  - `Display` keeps `outputs`, `edid`, `attach`, `detach`, `show` and
    `flush`.
  - It gains `@event outputsChanged`: a connector came or went, or a
    mode changed. The client asks `outputs` again.
  - `Output` gains the mode's refresh, in millihertz.
  - The class is typed (D82): devmgr binds a display driver by its
    `class display` match, and serves it at
    `/svc/devmgr/drivers/<host>/display`.
- **virtio-gpu's 2D path first,** lifted from todhchai:
  - `GET_DISPLAY_INFO`, `GET_EDID`, `RESOURCE_CREATE_2D` over a
    client's pinned VMO, `SET_SCANOUT`, `TRANSFER_TO_HOST_2D` and
    `RESOURCE_FLUSH`;
  - the config change interrupt (`VIRTIO_GPU_EVENT_DISPLAY`) as
    `outputsChanged`.

  Direct scanout is `show` of a client's own image: no copy through
  Radharc's.
- **Radharc composes per output.** Where the image has a display
  driver, Radharc uses it, and the console's GOP framebuffer only
  until it answers. Each enabled output gets an image its size, and a
  frame composes and flushes only the outputs its damage touches.
- **The arrangement:**
  - Outputs sit left to right in the device's order, tops aligned.
  - `Outputs:<name>:Place` (`X Y`) and `Outputs:<name>:Scale` in
    Settings move and scale one.
  - An output's name is its EDID's maker and monitor name, with its
    serial if two match (`DEL U2720Q 1`), or `output-<n>` without
    EDID.
  - The pointer crosses outputs where they touch.
  - A workspace is shown on every output: one desk spans them, as
    space mode is plain placement (D116). Workspaces per output wait
    for a second output on a board to judge them by.
- **Scale is n/120 per output** (todhchai's). The default is from
  EDID's size: 120 at 96 dpi and below, then in steps of 30 (150, 180,
  240, 360), the step nearest the dpi.
  - A window has the scale of the output that holds most of its
    area. It is configured again, with the new scale, when that output
    changes (D110's sizes in logical pixels).
  - Its decorations are drawn at that scale. Where it spans two
    outputs, the other shows it resampled until it moves.
- **Each output's colour** is EDID's chromaticity as a matrix from
  sRGB, kept for the GPU composer. On the CPU path Radharc composes
  sRGB and the matrix isn't applied. D110 keeps sRGB the working
  space, and HDR, ICC and calibration are out of scope.
- **Suspend is a devmgr verb.** A driver host serves `suspend` and
  `resume` in its devmgr protocol, after its children are suspended
  and before its parents. A display driver's `suspend` stops scanout
  and frees its device memory, and `resume` rebuilds its resources
  from what its clients attached. No driver implements it in V5 but
  virtio-gpu, whose suspend is a reset. The protocol's shape is fixed
  now, so drivers written later follow it.

## Then

Venus, the Vulkan loader, Loinnir, Radharc's GPU composer and UIGPU,
lifted from todhchai's M5, come in a design of their own (D121), once
the outputs above work. `theme.compose.4k` is judged there.

## Left out

- A window's own scale override, and fractional scales between the
  steps (Settings can still give any n/120).
- Mirroring an output.
- Hotplug of the GPU itself: an output's hotplug only.

## Built (2026-10-22)

- The display class at version 2 (`drivers/display/lib`), with
  `outputsChanged` and an output's refresh.
- virtio-gpu's 2D path (`drivers/display/virtio-gpu`, virtio-gpu(3)),
  lifted and moved onto this tree's driver host. Its configuration
  interrupt comes on the queue's vector, and a display event wakes each
  client's server to send `outputsChanged`.
- devmgr mounts a display host's whole tree at `dev/display<n>`.
  Mounting its `display` node alone didn't work: a connect through an
  opened node's mount doesn't reach the service.
- Radharc composes onto `/dev/display0`'s enabled outputs, left to
  right. It waits up to five seconds for devmgr to finish binding, and
  scales the mouse's absolute positions from the boot framebuffer's
  space to the desk's.
- boot-display runs QEMU with a virtio GPU of two outputs, one enabled,
  and checks the GPU's own screendump (`qemu.sh --screendump-device`).

Not yet:
- A change of outputs is logged but not acted on until Radharc
  restarts, and no test sees one: QEMU can't plug a display in a test.
- Per-output scale, EDID names, the colour matrix, and devmgr's
  suspend verb.
- Direct scanout of a fullscreen window's own image (todhchai's M5c):
  it needs the windows' images as buffer objects, D121's first part.
