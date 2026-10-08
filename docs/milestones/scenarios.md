# Scenarios

The QEMU scenarios `./build test` runs. Moved from [milestones.md](../milestones.md) on 2026-10-08.

`./build test` boots each of `tests/qemu/*.ndb` on both architectures; `--release` and `--tcg` run the same set. A release gate (`release` in its record) runs only when named, as `./build test install`, when a change risks what it covers and at a release; it is no milestone's gate (decided 2026-10-05). The release gates are the scenarios that take minutes: `install` (some 6 minutes on aarch64) and `slots` (some 17). Those of about a minute on aarch64 (`rcscript`, `dosfs`, `fsdadm`; seconds on x86_64) stay in the full run.

| Scenario | What it checks |
|---|---|
| `threads` | A native program's threads (6d1): `thread_local` storage from `PT_TLS`, stack bounds, `vx_mutex`, joins |
| `p9pipe` | The pipelined 9P client and ring server (6d4a), against `ptyd`: a held read ended by a write on the same connection from another thread, threads calling while it is held, `Tflush` by a note and by a timeout with the connection whole after |
| `fsdwstat` | What vx-9p's server does for every file server (6d4c1), against fsd and tmpfs: `Twstat`'s rename, truncate, chmod and mtime, all or none, and what it refuses; `ORCLOSE` at create and open; `DMAPPEND` and `DMEXCL` |
| `srv` | `/srv` as a file tree (6d4d2a): svcd's `srvmode=` post listed and opened for a connector that works; a post made, refused to another user, written twice, removed by its owner only; a name taken twice; an entry not posted yet; `ORCLOSE` |
| `relay` | The relay against u9fs (6d4d2b): one TCP conversation for two clients numbering fids alike; a file made through one read through the other; two threads on each at once; a hundred flushed reads leak nothing; an error passed on; a client gone leaves the other working; the relay outlives its connector while a client is left, and exits after the last |
| `srvcmd` | `srv` and shared mounts (6d4d2c), against u9fs: `srv` posts and mounts and the shell has the mount after it exits; `/srv` lists the post; `mount /srv/NAME`; a second `srv` finds the post; `-q`; `mount tcp!...` through a relay, which a child replays rather than dialing (two conversations while it has both mounts); a dial that fails |
| `pool` | Worker threads in the ring server (6d5a), against a test server with four threads whose reads wait let go: others answered meanwhile, on other connections and the same one; three slow reads waiting at once; a `Tflush` of a busy read waiting for it; a connection closed after its busy read, the server going on |
| `fsdconc` | `fsd`'s readers with the server let go (6d5b): four reader threads checking every byte, one file larger than the block cache, a writer making, removing and committing meanwhile; `fsd` with more than one thread after; a clean check |
| `fsdfix` | `fsd`'s review findings (6d5c): each open of status its own copy; `ctl` and `status` never made real by rename or symlink; more than 256 dated labels in the dump view; 40 snapshots opened in turn, 32 held and a 33rd refused until one goes; a snapshot deleted under a fid finds it nothing, before and after another opens; users kept in their places across a reload; no reaping or commit after `halt` |
| `dbgthreads` | The debugger and threads (6d6a): each of 32 threads stopped at a breakpoint in turn, more than the 16 procfs followed; then one at another with the other 32 seen stopped (frozen), before and after it steps; another thread's call stack, and its FP/SIMD state (`ymm`, `k`, `pkru` on x86_64; `v` on aarch64); the program going on to its end |
| `proc` (6d6b) | A ring per thread: four busy threads of proctest's own each claim a ring and write only their own records into it, none into the shared one; `/proc/N/prof/zones` has all four merged by their ends |
| `sched` | Scheduling contexts (6d6c): under 32 busy threads on four CPUs, each counting, measured against what a hog gets meanwhile (so a busy host slows both), all running one out-of-line loop (two loops compared their code's layout too, 15%): a thread of their band gets what one does (0.9 to 1.0 times); one bound to a realtime context of 3 ms in each 10 ms gets its 30% and no more (2.4 to 2.6 times, of an expected 2.6; a whole CPU would be 10.7); one bound to a reserved CPU keeps it (9.6 to 9.8 times); admission past 80% of the CPUs, a reservation of the shared CPU, and parameters out of range refused. Donation (6d6c2): the realtime thread's calls to a background server, which the hogs would starve, one in each period, are answered in at most 0.6 ms (x86_64) or 1.2 ms (aarch64) of its 3 ms budget, the server reporting itself realtime on the caller's loan, and background after; back to back, they spend the caller's budget (6 to 9 periods exhausted) |
| `rcscript` (6d7a's part) | The current directory: rc's `cd`, absolute, relative, `..`, through `$cdpath` and to `$home`; a file or a missing name refused, the directory unchanged; sbase's and native children (`pwd`, `cat`) starting in it, and a relative name in each; cdtest, run by rc, from C: `vx_getwd`, `vx_chdir`, `..` above the root, a relative open, create, walk and `bind ... .`, another thread seeing the change; and in `posix`, ctest's `chdir` passed to a native rc child |
| `boot` | M1's exit test: the kernel reaches `svcd`, which starts the console driver and `bootfs` |
| `panic` | A kernel fault reaches the panic handler, with a symbolized backtrace |
| `write-text`, `write-text-alias` | Kernel code is read-only (W^X), and through the direct map too |
| `lower-half` | The kernel's own page tables leave the lower half empty: a load near 0 faults |
| `phys` | The page allocator hands out and takes back a block of every order, and its count balances |
| `timer` | A 10 ms deadline wakes the idle kernel, never early |
| `smp` | Every CPU comes online, and all four use the page allocator at once without losing a block |
| `ktest` | The kernel's objects and syscalls from user space (`tests/kernel/ktest.c` as the root task): channels, ports, counters, futexes, threads, child tasks, devices |
| `ns` | A namespace built from a spawn message over ring connections to `bootfs`: mounts, binds, unions |
| `cons` | The user-space console: cooked lines, erase and kill-line, `^D`, output that overflows the driver's queue |
| `shell` | M2's exit test |
| `pci` | `devmgr` finds the PCI functions through ACPI |
| `net` | `drv-virtio-net`: a session, ARP to QEMU's gateway and back, the driver killed and restarted |
| `block` | The block class against `drv-virtio-blk` on a second disk, and its two partitions through `partd`: `INFO`, transfers across page boundaries and as large as the driver takes, `FLUSH`, `WRITE_FUA`, `DISCARD`, every refusal, a read-only window as a second session, 100 requests in flight; the drivers killed, restarted by `devmgr`, and what was written read back |
| `netd` | DHCP, `/net/ipifc/0/status` as M3's exit test reads it, `ping 10.0.2.2`, `cs` through `/net/cs` and `/net/dns` (a service name, `localhost` through QEMU's DNS proxy, NXDOMAIN) |
| `tcp` | TCP against QEMU's own stack: 256 KiB echoed through a host `cat`, hangup, a refused connection |
| `mount` | M3's exit test against `vx9pserve` at 10.0.2.100!5640: `mount`, `ls` and `cat` (children dialing their own), a write found on the host, `9p://`, `ns` |
| `iso` | The ISO, as a CD with no disk, boots to the shell |
| `stack-overflow` | A kernel stack that overflows hits its guard page, and the panic says so |
| `u9fs` | Interoperability: the same against `u9fs`, a stock 9P2000 server, chrooted in a user namespace |

Host tests (`tests/host/`, under ASan and UBSan) and fuzzers (`tests/fuzz/`) run in `./build check`.
