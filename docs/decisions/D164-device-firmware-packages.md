# D164. Firmware for devices: each blob a package pinned by hash, cached by vx from the board and put on a board's image, and given only to the driver whose record names it (2026-11-20, accepted by the owner; amends D4)

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

## The decision

1. **A package per device's firmware.** `firmware/packages/<name>.pkg`,
   a text record: each file's path under `lib/firmware/` (the name the
   driver asks for, `arm/mali/arch12.8/mali_csffw.bin`), where it comes
   from (a URL and a commit, or a tarball), its SHA-256, its licence
   (an SPDX id or the licence file's name) and its size. The blobs
   themselves are never committed.
2. **vx caches and checks.** `vx firmware fetch --from [HOST:]DIR`
   fills `.cache/firmware/` once, from the board's FreeBSD
   (`root@BOARD:/boot/firmware`) or a directory, and refuses a file
   whose hash differs; nothing is fetched over the network. A board
   image's bootfs (`bootfs-board*.img`) puts the packages of its arch
   at `lib/firmware/`. QEMU images take none. Without the cache the
   board image builds without them, and the driver says `no firmware`
   in its status.
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


## The owner's answers (2026-11-20)

- **CIX's `.fwb` images are included.** They are useless without CIX's
  hardware, so redistributing them on a VectraOS board image is
  accepted. Their package, `mali-v`, says so in its licence field
  (`CIX-fwb-owner-accepted`) and in `firmware/README.md`.
- **The cache is filled once from the board's FreeBSD, not fetched
  over the network.** The image is cached, and where it comes from
  will move later anyway.

## As built

- **Packages.** `firmware/packages/mali-csf.pkg` (Arm's
  `LICENCE.mali_csffw`; `arm/mali/arch12.8/mali_csffw.bin`, 307200
  bytes) and `mali-v.pkg` (CIX's 16 `.fwb` images under `cix/vpu/`,
  5.4 MB). Records are directives (D86) with `package`, `arch`,
  `licence`, `source` and `file PATH SHA256 SIZE [from PATH]`
  (firmware(6)); `arch` picks the board images that carry it. A
  package's name and licence must be a row of `firmware/README.md`'s
  Packages table, which is the owner's acceptance.
- **vx.** `vx firmware list|check|fetch` (vx-firmware(1);
  `tools/firmware/lib`, `tools/vx/FirmwareCommand.swift`). The cache is
  `.cache/firmware/PATH`. `fetch --from DIR|HOST:DIR` copies a file
  (scp for a host) to a `.part` name, checks size and SHA-256, and
  renames it, so a refused file never reaches the cache. `check` also
  holds every driver record's `firmware` line to a packaged file.
- **Images.** `kernel/CMakeLists.txt` adds `lib/firmware/PATH` entries
  of this arch's packages to `_board_entries`, so every
  `bootfs-board*.img` has them: 0.3 MB for `mali-csf` and 5.4 MB for
  `mali-v`, 5.7 MB in all. A file not cached is left out with a status
  message; one whose SHA-256 differs stops the configure. `boot-board`
  runs the same image in QEMU, which binds no device that names them.
- **devmgr.** `firmware PATH` lines in `driver.manifest`
  (`DriverManifest.firmware`; paths without `..`, `.` or empty parts,
  no repeats). In the host's start path (`launcher.extraStartup`),
  devmgr reads just those files from bootfs's `lib/firmware/` into a
  `NodeTree` of its own for that host, served on a channel mounted at
  the host's `/lib/firmware`: no new service, and a host has no path to
  another's tree. A file bootfs lacks is logged (`no firmware PATH`).
- **mali.** Its record names the CSF image; on start it reads it and
  puts `firmware N bytes, first word 0xHHHHHHHH, not loaded` (or
  `no firmware`) first in its `status`. Loading it into the GPU is a
  later item.
- **Tests.** `FirmwareTests` (the record parser, the hash and size
  check, the licence refusal, the `firmware` lines against packages),
  `DevMgrTests` (the record line) and `MaliTests` (the status line).
  A QEMU check that a driver sees only its named files isn't built:
  no QEMU device binds a driver with a `firmware` line, and a test
  driver for it would be one more mechanism for a property of one
  `NodeTree` per host; the Orange Pi 6 Plus run shows it (mali's
  status, and its `/lib/firmware` listing).
