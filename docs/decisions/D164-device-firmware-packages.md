# D164. Firmware for devices: each blob a package pinned by hash, fetched by vx onto a board's image, and given only to the driver whose record names it (2026-11-20, proposed; amends D4)

D4 lets on the device the firmware blobs the hardware requires, listed
in `firmware/README.md`. So far every one fit inside a driver: the
RTL8126's microcode is BSD-licensed register writes, generated into
`drivers/net/rge/lib/RTL8126Code.swift`. The Orange Pi 6 Plus's next
devices need real images that a processor on the device runs:

- **The GPU:** the Mali-G720's CSF firmware, one image per GPU
  architecture, `arm/mali/arch12.8/mali_csffw.bin` (panthor 05 §5.1,
  11). Arm's, under Arm's redistributable binary licence
  (linux-firmware's `LICENCE.mali_csffw`); FreeBSD's
  `/boot/firmware/arm/mali/arch12.8/mali_csffw.bin` on the board.
- **The video codec:** the Mali-V's per-codec `.fwb` images (16 of
  them: `h264dec.fwb`, `hevcdec.fwb`, `vp9dec.fwb`, `hevcenc.fwb` and
  the rest; linlon-vpu 03), from CIX's `cix_opensource__vpu_driver` at
  `5b9b07b` (`firmware-binaries/`). Their licence isn't stated there.
- **The NPU:** none found yet; the Zhouyi's command buffers come from
  its compiler (zhouyi-npu 02).

D4 says these may be loaded. It doesn't say where the bytes live, how a
build gets them, or which process may read them.

## Proposal

1. **A package per device's firmware.** `firmware/packages/<name>.pkg`,
   a text record: each file's path under `lib/firmware/` (the name the
   driver asks for, `arm/mali/arch12.8/mali_csffw.bin`), where it comes
   from (a URL and a commit, or a tarball), its SHA-256, its licence
   (an SPDX id or the licence file's name) and its size. The blobs
   themselves are never committed.
2. **vx fetches and checks.** `vx firmware fetch` downloads each
   package into `.cache/firmware/`, refuses a file whose hash differs,
   and a board image's bootfs (`bootfs-board*.img`) puts the packages
   its board names (`docs/hardware/support.tsv`'s new column, or the
   board's file) at `lib/firmware/`. QEMU images take none. Without the
   cache the board image builds without them, and the driver says
   `no firmware` in its status.
3. **Only the driver that names it reads it.** A driver's record
   (driver(6)) gets `firmware PATH` lines; devmgr mounts just those
   files, read-only, at the driver's `/lib/firmware/`. No other process
   sees them, and the driver can't read a blob another device's
   firmware package brought.
4. **`firmware/README.md` lists each package** with its licence, as it
   lists the RTL8126's code, and a licence not listed there as
   accepted fails `vx firmware fetch`.

## Not chosen

- **Blobs in git.** The repository would carry megabytes of
  third-party binaries whose licences forbid changes, and every clone
  would take them, though only one board needs them.
- **Loading from FreeBSD's volume or the ESP at run time.** It would
  tie a VectraOS device to another OS's files, and the ESP is
  firmware's, read only by the loader.
- **A firmware service** serving every blob by name. One more process
  for what devmgr's grants already do, and a driver could ask it for
  another's blob.

## Open for the owner

- Whether CIX's `.fwb` images may be redistributed: their repository
  states no licence for them.
- Whether board images built on the Mac fetch over the network, or the
  cache is filled from the board's FreeBSD once (`vx firmware fetch
  --from jkane@192.168.0.19:/boot/firmware`).
