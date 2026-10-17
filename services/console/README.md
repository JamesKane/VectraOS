# The console

`bin/console`: the boot console and the system log on the framebuffer.

## The console

`bin/console` (`services/console`, M3j; V2 item 8) maps the GOP framebuffer
that croi's boot data names (write-combining) and shows the system log,
read from the debuglog's ring (D38: its manifest's `debuglog` grants the
ring and its doorbell), plus what is written to its `write` leaf;
`screen` reads back the grid. kbdfs (D83) writes its echo and its
cons's writes there, so the shell on the console (`shell/rc/shell.manifest`)
shows here. Radharc's handoff comes with Radharc
(V5). launch-test mounts it at `/mnt/console` and finds a line it logged
on the screen.
`services/console/lib` (tier 0) is the text grid and renderer, in the desktop's
colors. Its font is Spleen (third-party data, `data/fonts/spleen`, with
PROVENANCE.md); after changing the data, regenerate and commit:

    .build/debug/fontgen services/console/lib/generated/Spleen.swift data/fonts/spleen

`services/console/tests` fails if the committed table doesn't match the data. To
look at the screen, boot without `--test` with `-- -monitor
unix:SOCK,server=on,wait=off` and send `screendump FILE.ppm`.
