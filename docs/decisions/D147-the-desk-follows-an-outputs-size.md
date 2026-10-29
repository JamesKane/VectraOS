# D147. The desk follows an output's size: new images, the screen resized, windows kept by their nearer edge (2026-10-29, decided; extends D120, D146)

D120 left an output's change said in Radharc's log and not acted on.
With D146's mode setting, an output's size changes under a running desk:
linlon shows Radharc's 1920x1080 image from the top left at 720p, and
the rest of the desk is off the screen. The owner asked for the sizing
next (2026-10-29).

## Decided

- **When.** On `outputsChanged`, Radharc's follower reads the outputs.
  Where an enabled output's size (or the set of them) differs from what
  it attached, it acts, under the state's lock, which frames are
  composed under. An output that comes or goes without a size change
  stays as D120 left it.
- **The images.** Each output gets two new images of its new size. The
  old ones are detached only once the next frame has presented the new,
  so the driver never falls back to firmware's buffer in between.
- **The screen.** A new shadow of the outputs' size; the scene resized;
  the GPU's target made again at the size where Radharc composes there;
  everything damaged and composed at the next latch.
- **Windows.** The desktop and fullscreen windows take the screen, and
  zoomed ones its new zoom area, each with a configure. Tiled
  workspaces are arranged again. Every other window keeps its distance
  from the nearer edge on each axis (Deskbar, 8 from the right, stays
  there), then is kept on the screen where it fits, its tab too; one
  that places itself hears `moved`. The pointer is kept on the screen.
- **No protocol change.** Clients that read `screen` get the new size on
  their next call; none is told the screen changed. The ones that matter
  on the board (the desktop, Deskbar) are kept right by the rule above.

On the board: 1080p to 720p and back, the whole desk shown each time,
Deskbar at the top right.

## Left out

A screen-changed event to clients, outputs coming and going, and a
scale per output (D120's).
