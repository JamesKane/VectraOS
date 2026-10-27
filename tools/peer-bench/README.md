# peer-bench: D127's rows

VectraOS against stock and tuned Ubuntu and FreeBSD on the Orange Pi 6
Plus (D127), and against Fuchsia, the microkernel peer, under KVM on the
dev machine (below). This directory holds the rows run as the *same
program* column, one portable C source for every OS, and each OS's
harness.

- `rows.c`: the rows that need neither the bench drive nor the network's
  far end: the primitives (`syscall_null`, `ipc_rtt_same`,
  `ipc_rtt_cross`, `wake_cross`, `fault_anon`, `map_unmap`,
  `spawn_exit_static`, `spawn_exit_linked`, `thread_create`,
  `clock_mono`), `cpu_mhz` (the core's clock while the rows ran), the cached file rows (`small_read`, `read_4k`,
  `tree_walk`) and `timer_wake_idle`. Each prints `budget
  name=peer.<row>` lines. `hello.c` is the spawn rows' child.
- `build.sh OS OUT`: builds them for `freebsd` or `linux` with the
  bundled clang and lld, the same flags and `-march` (D53's baseline)
  for every OS, against a sysroot in `.cache/peer-sysroots/OS`.
- `freebsd.sh DIR [stock|tuned [COOL]]`: FreeBSD's share of a round,
  run on the board: the run's facts (uname, WITNESS and INVARIANTS,
  loader.conf, the file system), a wait until the SoC has cooled, every
  row pinned to the same cores, each row's temperatures, then
  `idle_rss` and `idle_wakeups`.
- `linux.sh DIR [stock|tuned [COOL]]`: the same for Linux; `tuned` sets
  the performance governor (sudo). Run with DIR on the root file system
  (Ubuntu's `/tmp` is tmpfs), and the system booted to
  `multi-user.target`.

## The cores

Every row runs on the 2.5 GHz Cortex-A720 pair, MPIDR Aff1 8 and 9: the
fastest pair that isn't the boot core's (VectraOS takes every device
interrupt on the boot core, Aff1 10). FreeBSD numbers them 10 and 11.

## FreeBSD's kernel

D127's stock FreeBSD has no WITNESS or INVARIANTS. The board's kernel
has both, so the runs boot `GENERIC-HMP-IOMMU-NODEBUG` (this
directory's copy: the board kernel's `kern.conftxt` with `include
"std.nodebug"`), built from AbyssBSD's `orangepi-6-plus` at the board
kernel's commit with its docs/BUILDING.md recipe for arm64. On a Linux
host, pass `MACHINE=arm64 MACHINE_ARCH=aarch64 MACHINE_CPUARCH=aarch64`
to buildkernel (the modules otherwise take the host's) and not `STRIP=`
(install's flag). Installed as `/boot/kernel.nodebug` beside the
others, then `kldxref`, and booted once a round with `nextboot -k
kernel.nodebug`.

## Fuchsia, under KVM

Fuchsia can't boot the Orange Pi 6 Plus: arm64 Zircon takes a devicetree,
and only its x86 platform reads ACPI. Its column runs on the dev machine
instead, beside VectraOS amd64, each under QEMU/KVM with 4 vCPUs, 8 GiB,
`-cpu host` and nothing pinned, one VM at a time; only that pair of
columns is compared, not the board's.

- **Fuchsia**: `core.x64`, `--release`, in the jiri checkout beside this
  tree (`../fuchsia-jiri`), with this directory linked in as
  `//local/peer-bench`:

      ln -s $PWD/tools/peer-bench ../fuchsia-jiri/local/peer-bench
      fx --dir out/core.x64-release set core.x64 --release \
          --with-test //local/peer-bench/fuchsia:peer-bench
      fx --dir out/core.x64-release build
      fx --dir out/core.x64-release ffx emu start --headless --smp 4 \
          --net user --engine qemu --name peer
      fx --dir out/core.x64-release serve --address 127.0.0.1 &
      fx --dir out/core.x64-release ffx test run \
          fuchsia-pkg://fuchsia.com/peer-bench#meta/files.cm

  `fuchsia/BUILD.gn` builds the rows into three test components
  (`files`, `primitives`, `timer`), because a test's `/data` is Fxfs
  (test_manager's `fxfs_backed_data`), where `ffx component run`'s is
  memfs, and `ffx test` shows the output. `--engine qemu` is plain QEMU,
  the VMM the other columns use (the default, AEMU, isn't). Fuchsia's
  differences, in `rows.c`: no affinity call for a program (the rows run
  unpinned, so `ipc_rtt_same` and `ipc_rtt_cross` are the same), its null
  call is `zx_handle_close` of the invalid handle (its `getppid` makes no
  call), spawning is `fdio_spawn` and nothing is linked static (no
  `spawn_exit_static`), `tree_walk` walks by hand (no `nftw`), and
  `timer_wake_idle` sleeps with `zx_nanosleep` (`clock_nanosleep` says
  ENOSYS).
- **VectraOS amd64**: `vx boot --cpu`'s image carries `bin/peer-bench`;
  boot it headless under KVM with a 2 GiB Taisce disk of its own and run
  the rows from a cpu session:

      vx disk build/amd64/qemu-peer/data.img 2G 'taisce:*' --man .
      tools/qemu.sh --test NEVER --timeout 1800 --forward 17019:17019 \
          --disk build/amd64/qemu-peer/data.img amd64 build/amd64/esp-cpu \
          build/amd64/qemu-peer /usr/share/edk2 -accel kvm -cpu host -m 8G
      vx cpu -c 'mkdir -p /data/peer; peer-bench -d /data/peer' localhost

## Results

`bench/peers/<date>-<os>/`: each run's output and a summary.

## Ubuntu's host key

Ubuntu and FreeBSD answer at the board's one address with different host
keys; keep Ubuntu's in a file of its own (`ssh -o
UserKnownHostsFile=~/.ssh/known_hosts.opi6-ubuntu`) so FreeBSD's stays.

## Sysroots

Copied from the board, host-only (D4); `PROVENANCE` in each says which
system and when. FreeBSD's:

```sh
ssh BOARD 'cd / && tar cf - usr/include lib/libc.so.7 lib/libsys.so.7 \
  lib/libthr.so.3 lib/libm.so.5 lib/libgcc_s.so.1 usr/lib/crt*.o \
  usr/lib/Scrt1.o usr/lib/libc.* usr/lib/libc_nonshared.a usr/lib/libsys.* \
  usr/lib/libthr.* usr/lib/libpthread.* usr/lib/libm.* usr/lib/libgcc* \
  usr/lib/libcompiler_rt.a usr/lib/libssp_nonshared.a' \
  | tar xf - -C .cache/peer-sysroots/freebsd
```

## Each OS's best mechanism

To come with the best column: rings and Sys on VectraOS, io_uring on
Linux, kqueue on FreeBSD; the deadline profile, SCHED_DEADLINE and
rtprio.

## Not yet here

The bench drive's rows, the network rows, the loaded latency rows,
`boot_shell` and VectraOS's column (its libc has no
posix_spawn, nftw or clock_nanosleep yet), and `vx bench --peers`.
