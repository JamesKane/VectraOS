# Adversarial review pass, 2026-10-05 (mid-M6, at f4ac6b6 + the 6d4c working tree)

A read-only review of the first-party code, in eleven areas, each assuming hostile input: userland processes, 9P peers, devices, media, network, mirrors. Vendored trees (`third_party/`) were out of scope; how we use them was in scope. Nothing was changed; fixes wait until M6 is done.

Findings already in `docs/milestones.md` Known gaps, or in earlier review passes, were dropped. **[WIP]** marks a finding in the uncommitted 6d4c diff (Twstat, ORCLOSE, DMEXCL/DMAPPEND, Tversion), which can be fixed before that step is committed.

**Confidence** is either:
- **confirmed**: traced in code, and in a few cases reproduced in a scratch host build;
- **plausible**: the logic holds, but it needs a test to show it.

## Summary

| | critical | high | medium | low | total |
|---|---|---|---|---|---|
| KERN kernel core | 1 | 2 | 2 | 5 | 10 |
| ARCH kernel arch + IOMMU | 1 | 2 | 1 | 2 | 6 |
| RT musl back end + runtime | 1 | 6 | 6 | 3 | 16 |
| 9P vx-9p, ring, ns, nsd | | 1 | 3 | 5 | 9 |
| FS vx-fs, fsd | | 1 | 1 | 6 | 8 |
| MEDIA FAT, ISO, GPT, tmpfs, … | | 1 | 2 | 4 | 7 |
| DRV drivers, devmgr, bus-acpi | | 1 | 5 | 4 | 10 |
| DIST distd, store, slots, install | | 2 | 1 | 3 | 6 |
| SVC procfs, ptyd, netd, vx-net | | 2 | 4 | 4 | 10 |
| SH rc, commands, guide, debugger | | | 5 | 4 | 9 |
| BLD build.c and tests | | 1 | 7 | 4 | 12 |
| **total** | **3** | **19** | **37** | **44** | **103** |

Duplicates are merged and their IDs kept:
- ARCH-4 is merged into KERN-1.
- FS-2 is merged into 9P-3.
- RT-15 is merged into 9P-8.

### Themes

1. **M6's threads meet a back end built for one thread.**
   - RT-1 to RT-7, RT-9, RT-12 and RT-13 are races between threads, signals and the back-end lock.
   - The pthreads tests use one waiter and no cancellation, so none of them show up.
   - RT-1 (broadcast loses waiters) breaks every condition-variable thread pool.
2. **Servers that never ask who is calling.** netd (SVC-1) and ptyd (SVC-3) use plain `attach` and serve every file to everyone; vx-9p checks no permissions for them. fsd's symlinks (FS-1) are the same class: a mode of 0777 is taken at its word.
3. **Restart and teardown windows.** DRV-1, DRV-2 and DRV-5 (devmgr restart), ARCH-3 (dying IOMMU domain), KERN-2 (exec against a killed task), KERN-5 (an unstarted fork child leaks), 9P-2 (unmount under open files), SVC-5 (listener hangup).
7. **Protection keys and exec.** KERN-6, KERN-7 and KERN-10 each let a key's rights slip: across exec, after a debugger write, or after a failed divert.
4. **The entry path and hardening are behind the docs.** ARCH-1 (#DB without IST), ARCH-5 (no SMEP/SMAP/UMIP/PAN, which 01 §11 requires).
5. **Some tests cannot fail.**
   - BLD-1: the GPT fuzzer is cut to 4 KiB and so rejects every input.
   - BLD-7: a reset passes as a power-off.
   - BLD-8: the protection-key suite skips itself when keys go missing.
   - QEMU's SMMU ignores nG (ARCH-2).
6. **Trust-chain caching.** DIST-1 and DIST-2 let distd serve bytes as verified that were never verified, reaching `apply`.

### A note on the kernel core

The KERN reviewer's first report was cut off by the API's safety filter. The full report was recovered from a file it wrote afterwards. KERN-1 and KERN-2 were also re-checked by hand against the code.

---

## Critical

### KERN-1 (merged with ARCH-4): GET_FPREGS writes past its kernel page on x86 with PKU or AVX-512
- Confidence: confirmed (re-checked)
- Location:
  - `kernel/obj/exception.c:452-455`: `view = area + ARCH_FP_MAX/2` in a one-page `phys_alloc(0)`.
  - `kernel/arch/x86_64/arch.c:645-646`: `arch_fp_view` copies the whole `xsave_size`, and its component memsets also write at `xcomp_off[i]`.
  - `arch.c:211`: the boot check only panics when `xsave_size` exceeds 4096.
- Defect: the comment assumes the image fits in the page's top half (2 KiB). With PKRU in XCR0 the standard-format size is at least 2696; with AVX-512 it is about 2.7 KiB. So the write runs at least 648 bytes into the next physical page.
- Failure scenario: any task that holds MANAGE on a stopped thread can trigger this, and that includes a task acting on its own threads through its own exception port. The adjacent page is often a free buddy block, so its list links are overwritten, and `phys_free` then coalesces with it. The result is kernel memory corruption, with the content partly chosen by SET_XSTATE. On a PKU CPU with zeros there (QEMU `-cpu max`), the free list is silently cut, which is why ktest's GET_FPREGS checks (`tests/kernel/ktest.c:1787-1806`) pass. aarch64 is unaffected, since its view copies `sizeof(vx_fpregs)`.
- Fix direction: give `arch_fp_view` an output length, or use a full-size buffer for the partial view. Assert `ARCH_FP_MAX/2 >= xsave_size` wherever the split layout is used.

### ARCH-1: x86 #DB has no IST stack, and `trap_entry` picks the GS from the saved CS alone
- Confidence: confirmed in code; the CPU behaviour is the documented MOV SS / POP SS delayed-#DB case (the CVE-2018-8897 class)
- Location:
  - `kernel/arch/x86_64/arch.c:156-159`: only vectors 2, 8 and 18 get an IST.
  - `kernel/arch/x86_64/entry.S:36-39`: the swapgs decision is made from the saved CS.
  - `entry.S:86-90`: `syscall_entry` runs on the user RSP until `movq %gs:0, %rsp`.
  - `arch.c:531-549` and `kernel/obj/exception.c:389-421`: user-settable data watchpoints.
- Defect: a #DB can be delivered at the first instruction of the SYSCALL handler, at CPL0 but on the user's RSP and GS. The CPU pushes its frame there, the C trap handler runs on that stack, and no swapgs is done because the saved CS is the kernel's.
- Impact: the kernel writes to and runs on a stack the user chose, with the user's GS base. That is a privilege-escalation-class failure, and at the least a panic.
- Fix direction: give #DB, NMI and #MC IST stacks, and decide GS ownership on those vectors from the GS-base MSR. See also ARCH-6.

### RT-1: `pthread_cond_broadcast` with three or more waiters can leave waiters asleep for good
- Confidence: confirmed (re-checked)
- Location:
  - `ports/musl/vx/start.c:208-221`: `time_futex` supports only WAIT and WAKE, and every other op returns `-ENOSYS`.
  - `third_party/musl/src/thread/pthread_cond_timedwait.c:48-54` (`unlock_requeue`) and `:157`.
- Defect: musl's private condition variable passes the wakeup from one waiter to the next with `FUTEX_REQUEUE`. Both of its attempts get ENOSYS, and its only other action is the `a_store(l, 0)` before them, which wakes nobody.
- Failure scenario: N threads in `pthread_cond_wait` and one broadcast. The first waiter whose wakeup needs the next one passed on leaves that one asleep, and every later waiter with it, unless they used timed waits. ctest broadcasts to a single waiter (`tests/posix/ctest.c:1317`, `:1735`).
- Fix direction: implement FUTEX_REQUEUE and CMP_REQUEUE in `time_futex`, or at least emulate them with a wake. Add a three-waiter broadcast test.

## High

### KERN-2: killing the scratch task during `task_exec` makes the caller take a torn-down address space
- Confidence: confirmed (re-checked)
- Location:
  - `kernel/syscall/syscall.c:907-920`: the fresh check, which sets `execing`.
  - `syscall.c:924-942`: both locks are dropped for `handles_take` and `futex_robust_walk` (up to 2048 user entries).
  - `syscall.c:946-956`: the swap, done without a re-check.
  - `kernel/obj/process.c:124-139`: `task_kill` ignores `execing`, and an idle task is torn down at once (`:30-53` sets `root = 0`, `maps = nullptr`).
- Failure scenario: another holder of a handle to the scratch task kills it inside that window. The caller then swaps in `root = 0` and `maps = nullptr`, loads root 0 and dereferences NULL later. The old address space, now on `s`, is also never freed, because the closing `task_kill(s)` returns early for an already-killed task.
- Fix direction: have `task_kill` refuse to tear down (or defer teardown of) a task with `execing` set, or re-check `s->killed`/`s->root` under the locks before the swap and back out cleanly.

### KERN-3: user deadlines are not validated, and can stop the timer on a CPU
- Confidence: confirmed (code, plus a host check of the arithmetic)
- Location: `kernel/obj/futex.c:82`; `kernel/obj/channel.c:232`; `kernel/sched/sched.c:202-210`, `:262-276`; `kernel/time.c:49-53`; `kernel/time_math.c:19-21`
- Defect:
  - `futex_wait` and `channel_call` pass the user's deadline straight to `thread_block`; only `port_wait` refuses past ones.
  - A negative deadline becomes the earliest entry in the CPU's sleep queue, and its conversion to a counter value wraps to decades away. It also beats `slice_end`, so `sched_timer` never runs on that CPU.
  - Very large deadlines can wrap on x86 too.
- Impact: on each affected CPU, timed waits stop timing out (pager deadlines, sleeps, poll timeouts) and preemption stops. Any unprivileged process can do this to every CPU.
- Fix direction: in the syscall layer, answer a deadline at or before now with an immediate TIMED_OUT, and saturate the conversion to counter values instead of letting it wrap.

### ARCH-2: SMMUv3 stage-1 leaf entries are global (no nG), so ASID invalidation leaves them cached
- Confidence: confirmed in code (re-checked); the effect is the Arm TLB rules. QEMU's SMMU ignores nG.
- Location: `kernel/iommu/smmuv3.c:202` (leaf attributes without bit 11). The only invalidation is CMD_TLBI_NH_ASID, at `:190-195`, `:227` and `:304`.
- Impact on real hardware:
  - a device keeps DMAing through stale translations after unmap, revoke or detach, into pages that have been freed and reused;
  - domains match each other's cached entries for the same IOVA, since all of them allocate from the same base (`device.c:311-322`).
- Fix direction: set nG on stage-1 leaves, as Linux's io-pgtable does for stage 1.

### ARCH-3: the IOMMU fault interrupts take a reference on a domain that may be dying
- Confidence: confirmed
- Location:
  - `kernel/iommu/vtd.c:386-396` and `kernel/iommu/smmuv3.c:337-348` use `object_ref`, not `object_tryref`.
  - The domain stays in `vtd_domains[]`/`smmu_domains[]` until late in `iommu_detach` (`vtd.c:356-358`, `smmuv3.c:309-311`).
  - The attach failure path calls `pool_free(d)` after the domain was published (`kernel/obj/device.c:299-302`).
- Impact: a fault arriving in that window raises the count from 0 to 1 and back, queues the domain on the dying list twice, and frees its page tables twice. This is a kernel use-after-free or double free that a misbehaving device can trigger.
- Fix direction: use `object_tryref` in both handlers, and remove the domain from the table before its last reference can go.

### RT-2: a signal during `be_enter`'s lock wait runs a handler in the back end without the lock; one at `be_leave` deadlocks the thread
- Confidence: confirmed
- Location: `ports/musl/vx/backend.c:127-133`, `:734-737`, `:747-749`; `lib/vx-rt/base.c:539-547`
- Defect:
  - `depth` is raised before `vx_mutex_lock` returns, while `sig_depth` is still 0. A note during the futex wait runs a handler at once, and a `write()` inside it sees depth 1, skips the lock and runs alongside the lock holder.
  - `be_leave` lowers depth before it unlocks. A note in that gap makes the handler lock a mutex this thread still holds, so the thread deadlocks itself, even in a single-threaded program.
- Fix direction: set `sig_depth` (meaning "in the back end") before taking the lock and keep it until after the release. Change `depth` only while the lock is held.

### RT-3: `posix_spawn` runs the back end without the lock, and its signal guard is a dead global
- Confidence: confirmed
- Location: `ports/musl/vx/process.c:250` (a separate `static volatile int sig_depth`, declared before signal.c's per-thread `#define` in the unity build), `:441-467`; `lib/vx-rt/spawn.c:147`
- Failure scenario: a threaded program spawns (Swift's `Process` does) while other threads open and close files. `fd_table` refcounts, `fd_cwd` (FDOP_CHDIR) and the static spawn buffers race, and signals run their handlers in the middle of the spawn.
- Fix direction: wrap it in `be_enter`/`be_leave`, and delete the stale declaration.

### RT-4: `pthread_cancel` livelocks the target thread instead of cancelling it
- Confidence: confirmed
- Location: `ports/musl/vx/signal.c:167-199` (the handler's `uc_sigmask` is ignored, and the mask is restored from `old`), `:225-233` (delivery at a call's return passes PC 0); `backend.c:798-800`
- Defect:
  - musl's `cancel_handler` acts only when the PC lies inside `__cp_begin..__cp_end`. Otherwise it blocks SIGCANCEL in `uc_sigmask` and re-sends the signal to its own thread.
  - Here the mask change is thrown away and the PC is 0 (on aarch64 it can never lie in that range), so the handler loops forever. In the call-return case it does so while holding `be_lock`, which stops the whole process's back end.
- Fix direction: apply `uc->uc_sigmask` after a handler returns, and give call-return delivery a PC inside the cancellation range, or handle SIGCANCEL in the back end itself.

### RT-5: one `fd_port` serves every thread, so a wakeup taken by the wrong thread is lost
- Confidence: confirmed
- Location: `ports/musl/vx/fd.c:117-144`, `:480`; `poll.c:144-146`, `:242`
- Failure scenario: thread A reads a child's stdout while thread B reads its stderr. B receives A's packet, clears `read_bound` and sleeps again, so A sleeps with data waiting. Signal wakeups (`FD_KEY_SIGNAL`) are stolen the same way.
- Fix direction: give each thread its own wait port, or re-post packets that belong to another thread.

### RT-6: blocking pipe, terminal, console and socket reads hold no reference across their wait
- Confidence: confirmed
- Location: `ports/musl/vx/fd.c:425-491`; `poll.c:141-191`; `socket.c:377`, `:454`, `:599`, `:614`; `fd.c:158-171`
- Failure scenario: another thread closes the descriptor to wake its reader, which is how servers usually shut down. The read-ahead is unmapped and the woken reader faults, or the slot is reused and the reader acts on the new description or a reused handle number.
- Fix direction: hold `o->refs` across every wait that releases the lock, as `file_read_unlocked` does, and re-validate the description after waking.

### RT-7: process-wide signals go to the newest thread, which may have no TLS or stack yet, or none left
- Confidence: plausible
- Location: `kernel/obj/process.c:79-80`; `kernel/obj/exception.c:559-561`; `ports/musl/vx/backend.c:548-558`, `:630-690`
- Failure scenario: a server that creates detached threads continually receives SIGCHLD or SIGTERM. The note lands on a thread whose TLS is not set up yet (its mask is 0, so even blocked signals are delivered), or on one whose stack is already unmapped, so the process faults in the handler, or the signal is lost.
- Fix direction: send process-wide notes to a thread the back end has marked ready, or the oldest one, and refuse or re-route notes for a thread that is starting or exiting.

### 9P-1: Tflush gets a slot but no reply budget, so two held large reads can freeze or kill a ring connection
- Confidence: confirmed (traced, not run)
- Location: `lib/vx-9p/ring.c:451` (budget check), `:225-240` (`p9_reply_max`), `:482` (the wait uses `hear=false`), `:489-501` (`p9_ring_flush`)
- Failure scenario:
  - Two threads block in 16 KiB reads that the server holds, such as two ptyd terminals. Between them they reserve almost the whole 32 KiB reply budget.
  - Every further call then waits without interruption, even a Tclunk.
  - When one reader is signalled, its Tflush cannot be queued and times out after 5 s, and `p9_ring_kill` ends the connection, breaking every fd on that server.
  - The known gap said seven held calls; two are enough.
- Fix direction: keep a small reply budget alongside the flush slot, and optionally cap each call's read reservation.

### FS-1: anyone who can reach a symbolic link can rewrite where it points
- Confidence: confirmed
- Location:
  - `lib/vx-fs/file.c:698`: a link is created with mode 0777.
  - `servers/fsd/fsd.c:931-958` (`fs_open`), `:996-1008`, `:1034-1052` and `:888-922`: no refusal of write opens or writable maps on links.
  - `vxfs_write` never checks `DMSYMLINK`.
- Failure scenario: any attacher, `none` included, opens a link in a searchable directory with OWRITE and rewrites its target. Other users and services are then redirected. A target longer than 511 bytes also breaks the step 10 rule that targets are stored inline.
- Fix direction: refuse write opens and writable Tmap on DMSYMLINK in `fs_open`, and in `vxfs_write`. Check tmpfs for the same hole.

### MEDIA-1: a FAT rename that only changes case, or names the file's own alias, deletes the entry first and can lose the file
- Confidence: confirmed (repro)
- Location: `lib/vx-fat/fat.c:1160-1165` (`fat_unlink` comes before `fat_add`), `:1166-1171` (a replaced target is removed before the add)
- Failure scenario: on a full FAT16 root, `readme.txt` → `Readme.txt` needs a long name, so two slots. `fat_add` fails with NO_SPACE, and neither name finds the file, whose clusters are now orphaned. A power cut between the two steps does the same.
- Fix direction: rewrite in place when the slots fit. Otherwise add before unlinking, and remove the target only after a successful add.

### DRV-1: on restart, devmgr re-reads the driver's own BAR registers and grants whatever address they hold
- Confidence: confirmed
- Location: `servers/devmgr/devmgr.c:202-216` (`start_driver`), `:332-338` (`reset_function` puts saved BARs back), `:199` (the config space is a writable VMO); `kernel/obj/device.c:67-74` (only RAM is refused)
- Failure scenario: a compromised driver points its BAR at the VT-d or SMMU registers, the LAPIC, ECAM or another device, then exits. On restart devmgr mints a VMO over that address, and the driver can turn DMA translation off. bus-acpi can plant the same value through `VX_ACPI_PCI` (`:636-642`).
- Fix direction: record BAR bases and sizes once, at enumeration. Grant only those, put them back after FLR, and refuse any overlap with the taken ranges.

### DIST-1: reading an object of 68 KiB or more overwrites a cached, verified object, and that object stays marked valid
- Confidence: confirmed
- Location: `servers/distd/distd.c:102-123` (`valid = false` comes after the `n == OBJ_MAX` return); used without a re-check at `:146-149` (`dir_object`) and `:855-869`
- Failure scenario: any oversized object read (the index of a file over about 130 MiB) corrupts the evicted entry. An attacker who supplies an oversized object can replace a cached directory, such as a release's tree root. `apply`'s `check_tree` and `copy_to_slot` then walk the substituted tree and write its kernel and bootfs into a slot.
- Fix direction: invalidate the victim before reading into it, or read into scratch and copy in only after the check.

### DIST-2: `keep()` validates every pending slot of the same name, including one whose check failed
- Confidence: confirmed (host simulation)
- Location: `servers/distd/distd.c:126-129`; lookup order at `:96-101`
- Failure scenario: a bad read of H is refused, then a good read of H lands in another slot. `keep(H)` marks both valid, and the lower index (the bad bytes) wins every later lookup. Today this is a store writer or a race with a half-copied object; with M10's `fetch` it becomes remote.
- Fix direction: mark only the slot just checked, and clear the name and length of a slot whose check failed.

### SVC-1: netd checks nothing about who opens its files
- Confidence: confirmed
- Location: `servers/netd/netd.c:282-287` (every file is mode 0666), `:338-343` (`attach`, not `attach_as`), `:363-373`, `:457-469`, `:742-760`, `:777-782`
- Failure scenario: any process can:
  - rewrite the interface's routes and gateway (`ipifc/0/ctl`);
  - read or inject another process's TCP stream, including a 9P-over-TCP mount;
  - hang up another process's connection;
  - take over its listener.
- Fix direction: use `attach_as`. Make `ipifc/ctl` the network owner's alone, and give each conversation an owner and mode 0660, checked at open and carried to `listen` and accepted calls.

### SVC-2: vx-net's random values can be predicted from its own packets
- Confidence: confirmed
- Location: `lib/vx-net/net.c:205-209` (xorshift32, whose output is its state), `:280` (IP IDs), `:419-425` (sequential ports); `tcp.c:185` (ISN); `dns.c:259-260`; `servers/netd/netd.c:175` (seeded from the clock and the MAC)
- Failure scenario: an off-path attacker recovers the generator's state from packets it can see, such as a SYN-ACK or a few IP IDs, and predicts DNS IDs, ports, TCP ISNs and DHCP xids. With those it can forge DNS answers so that `tcp!name!564` mounts its server, make blind spoofed TCP connections, or forge DHCP during renewal.
- Fix direction: seed from the entropy service, use a keyed CSPRNG for IDs, ports and xids, RFC 6528 ISNs, and a separate generator for IP IDs.

### BLD-1: the GPT fuzzer never gets past vx-gpt's size check under `./build check`
- Confidence: confirmed (reproduced)
- Location: `build.c:4364` (`-max_len=4096`); `lib/vx-gpt/gpt.c:155` (fewer than 68 sectors is refused); `tests/fuzz/gpt_fuzz.c:27`
- Defect: every input is cut to 8 sectors and refused, so no assertion is ever reached. The guide seed is truncated too, and milestone 1b's claim of a GPT fuzz target is hollow.
- Fix direction: set `max_len` per target (at least 68×512 bytes for GPT), or present inputs as a sparse disk. Fail `check` when a target accepts no seeds.

## Medium

### ARCH-5: SMEP, SMAP, UMIP (x86) and PAN (aarch64) are not enabled, although 01 §11 requires them
- Location: `kernel/arch/x86_64/arch.c:253-256` (CR4 sets bits 9, 10, 18 and 22 only); nothing sets PAN in `kernel/arch/aarch64`; `docs/01-kernel-ipc.md:494`
- Impact: with UMIP off, user code can read the GDT and IDT addresses. Without SMEP/SMAP, bugs like ARCH-1 are much easier to exploit.
- Fix direction:
  - Enable them, with STAC/CLAC around the user copies.
  - `arch_user_cas32` (`vectors.S:238-247`) uses privileged exclusives and would fault under PAN.
  - Otherwise amend §11 to say they are deferred.

### KERN-4: the robust-list walk fails on write-protected pager pages, so robust waiters can hang
- Confidence: confirmed in code; plausible in practice (fsd writes back about every 10 s)
- Location: `kernel/obj/futex.c:125-140`; `kernel/obj/pager.c:253-259` (CLEAN), `:264-282` (EVICT)
- Defect: `futex_owner_died`'s fault-safe CAS fails on a page that CLEAN has made read-only or EVICT has removed, and it does not resolve the fault as `pager_fault` would.
- Failure scenario: a robust mutex in a MAP_SHARED file is held across a writeback, then its owner is killed. The word is never marked OWNER_DIED, so the waiters sleep for ever. This breaks ADR-0037's contract.
- Fix direction: on such a fault, make the page writable (marking it dirty) or fault it in, then retry.

### KERN-5: a forked child that is never started leaks, held alive by its own self-handle
- Confidence: confirmed
- Location: `kernel/syscall/syscall.c:826-832`, `:60-68` (`return_handle`); `kernel/obj/task.c:481-486`
- Failure scenario: `return_handle` fails (a full table or a bad `out` pointer), or the parent dies before starting a thread. Nothing kills the child, which keeps a full copy of the parent's memory, so kernel memory leaks without bound.
- Fix direction: `task_kill` the child when `return_handle` fails, and consider tearing down a never-started task when its last outside handle closes.

### RT-8: a blocking TCP send holds `be_lock` until netd has taken all the data
- Confidence: plausible
- Location: `ports/musl/vx/socket.c:520-529`
- Failure scenario: a thread sends to its own loopback listener (the usual stand-in for `socketpair`), and the receiving thread cannot get into the back end, so the process deadlocks. Any slow peer stalls every thread.
- Fix direction: release the lock around the data write, as `file_write_unlocked` does.

### RT-9: handlers delivered at a call's return run holding `be_lock`
- Confidence: confirmed
- Location: `ports/musl/vx/backend.c:739-749`; `signal.c:173-178`, `:289-291`
- Defect / failure: `siglongjmp` out of such a handler leaves the lock held, and other threads hang. A fault on a user buffer inside the back end runs its handler with `sig_depth` forced to 0, in the middle of non-reentrant work.
- Fix direction: release the lock before running handlers at a call's return. Turn faults on user buffers into EFAULT.

### RT-10: `sigwait`, `sigtimedwait`, `sigwaitinfo`, `alarm`, `setitimer` and `timer_create` are all ENOSYS, and none is listed
- Location: `ports/musl/vx/backend.c:530`
- Failure scenario: the block-everything-and-`sigwait` threading design fails outright. musl's `alarm()` ignores the error and returns 0, so timeouts never fire and scripts hang.
- Fix direction: implement them, or add them to Known gaps with wave F's list.

### RT-11 [WIP]: `utimensat` turns UTIME_NOW into an explicit time for every server, so `touch` fails for non-owners on fsd
- Location: `ports/musl/vx/fd.c:1636-1643`; `servers/fsd/fsd.c:1180-1181`
- Failure scenario: `touch` on a file someone else owns, which the caller may write, now fails with EACCES (POSIX allows it). The time also comes from the client's clock rather than the server's.
- Fix direction: convert "now" into an explicit time only in the 9P2000 Twstat fallback.

### RT-12: `waitpid` from two threads: one keeps the other's child record, and the other blocks
- Location: `ports/musl/vx/process.c:199-219`
- Failure scenario: worker threads that each spawn and then `waitpid(pid)`, as parallel build tools do, hang until some unrelated child changes state.
- Fix direction: wake the other waiters when a record is kept (a futex on a generation count), and have them check `wait_kept` again before reading.

### RT-13: the console read path flushes and reconnects the shared console connection without the lock
- Confidence: plausible
- Location: `ports/musl/vx/fd.c:583-591`; `lib/vx-rt/stdio.c:29-31`, `:56-62`, `:82-95`
- Failure scenario: the console driver restarts while one thread reads and another prints, and the printing thread uses the ring after it has been freed.
- Fix direction: flush under the lock, and serialise reconnects with writers.

### 9P-2: unmount releases a connection that open files still use, and the slot is reused
- Confidence: plausible
- Location: `lib/vx-ns/ns.c:498-506`; `lib/vx-ns/spawn.c:41-50`, `:77-99`; `lib/vx-9p/client.c:137`; `lib/vx-ns/dial.c:62-76`
- Failure scenario: `{ unmount /n/x; mount /srv/y /n/y; echo hi } >/n/x/log`. The redirection's fid now refers to whatever that fid number is on server y, so the write and the clunk go to the wrong file, possibly on another server.
- Fix direction: count references to a connection from open files and dials, or give each slot a generation that open files check.

### 9P-3 [WIP] (merged with FS-2): DMAPPEND is enforced only for plain Twrite
- Confidence: confirmed
- Location: `lib/vx-9p/server.c:333` (only `p9_write` checks QTAPPEND), `:600-627` (`p9_serve_dref`), `:580-596` (`p9_serve_map`); `servers/fsd/fsd.c:888-922`, `:1034-1052`
- Failure scenario: Twriteref at an explicit offset, or a Tmap with PROT_WRITE, overwrites an append-only file in place. That breaks man/5/read's new promise.
- Fix direction: force the end-of-file offset in the dref write path, and refuse writable maps of DMAPPEND files.

### 9P-4: one client can fill the server-wide open-file and lock tables
- Location: `lib/vx-9p/server.c:105` (256 open files and 256 locks, shared by all connections), `:239-248`, `:813-819`, `:476-487` (Tshare holds keep a slot live 10 s after the last clunk), `:403-414`
- Failure scenario: one connection holds 256 opens, or cycles open, Tshare and clunk to keep slots live. Everyone else's opens on that server then fail with "out of memory", and their locks fail as well.
- Fix direction: per-connection quotas on open files, holds and locks.

### FS-3: qids on disk are not range-checked, so a crafted volume can forge permissive or other-user node ids
- Location: `servers/fsd/fsd.c:120-122` (`node_of` ORs the qid in unmasked), `:301-303`, `:1099`; `lib/vx-fs/file.c:69-79`; `lib/vx-fs/vol.c:904` (`nextqid` taken unchecked)
- Failure scenario: an entry whose qid has bit 55 (PERMISSIVE) or high user bits set bypasses `may`, `may_setattr` and `is_adm`, so `ctl` too. A `nextqid` near 2^48 collides with `CTL_QID` and `STATUS_QID`. Known gap 13 covers damage from crafted images, not this gain of privilege.
- Fix direction: refuse, as `vol_bad`, any qid or `nextqid` at or above the reserved top of the 48-bit space.

### MEDIA-2: names from a hostile volume are not checked: "..", ".", "", '/', control characters and bad UTF-8 reach clients
- Location: `lib/vx-fat/fat.c:338-344`, `:399-411`; `lib/vx-iso/iso.c:331-335`, `:264-293`; `lib/vx-9p/server.c:300-325` (outgoing names are never checked)
- Failure scenario: `ls`, `cp -r` and `rm -r` on a crafted stick or ISO meet names that ADR-0013 forbids. Recursive tools then loop, or act on paths other than the ones listed.
- Fix direction: in vx-fat and vx-iso, map bad bytes to U+FFFD and hide or rename "", "." and "..". Alternatively, check names centrally in `p9_read_dir` and stat.

### MEDIA-3: a failed FAT write leaves the changed sector in the cache
- Confidence: plausible
- Location: `lib/vx-fat/fat.c:559-565`, `:583-589`, `:692-695`, `:775-778`, `:539-546`
- Failure scenario: after a transient I/O error the cache says a cluster is taken while the disk says it is free. A later write can then cross-link two files, which breaks the header's promise.
- Fix direction: invalidate the cache line when `fat_store` fails, or change a copy and commit it to the cache only after the store succeeds.

### DRV-2: devmgr declares the device quiesced without a reset, and drv-nvme enables bus mastering before it disables the controller
- Confidence: plausible (needs a function without FLR)
- Location: `servers/devmgr/devmgr.c:330`, `:348-355`; `drivers/drv-nvme/nvme.c:344` vs `:355`
- Failure scenario: an NVMe function without FLR restarts with commands in flight. In pass-through mode it DMAs into pages already freed, which is kernel memory corruption.
- Fix direction: call QUIESCED only after a real reset. Clear CC.EN and wait for RDY=0 before setting bus master.

### DRV-3: the I/O-port mint wraps around, so bus-acpi can get every port
- Location: `servers/devmgr/devmgr.c:624-629` (also `:245-247`, `:669`)
- Failure scenario: a base near 2^64 makes the sum wrap past the overlap checks, while the kernel is handed the base truncated to 16 bits. A bus-acpi compromised through AML then gets the PIC, PIT, COM1, the PCI config ports and the RTC.
- Fix direction: refuse a base above 0xFFFF, use checked addition, and pass the same validated 16-bit values to the checks and to the kernel.

### DRV-4: devmgr's "taken" ranges are incomplete and fail open
- Location: `servers/devmgr/devmgr.c:503-505`, `:514-553`, `:251-253`, `:616-621`
- Defect: entries past 32 are dropped silently, and the MADT fills the list first, so DMAR and IORT entries are the ones lost. The ECAM window and aarch64's console PL011 are never added.
- Failure scenario: a hostile `_CRS` maps the IOMMU registers or ECAM.
- Fix direction: fail closed when the list is full, and add every MCFG region and the console's MMIO.

### DRV-5: a dead driver's device handles carry TRANSFER/DUPLICATE and outlive its restart
- Confidence: plausible
- Location: `servers/devmgr/devmgr.c:199`, `:209`, `:234-235`; `kernel/syscall/syscall.c:173`, `:199`
- Failure scenario: a driver passes its config, BAR or DMA-domain handles to a colluding process before it dies. That process keeps control of the device after the restart.
- Fix direction: give drivers these handles without TRANSFER/DUPLICATE, and use a fresh domain per start, or revoke the old one.

### DRV-6: the block client never matches completions to requests
- Confidence: plausible (needs a stall over 30 s)
- Location: `lib/vx-driver/blkclient.c:100-107`, `:39-58`, `:156-157`, `:182`
- Failure scenario: a read times out and the next write reuses the arena. The late read's completion is taken as the write's success, and its DMA overwrites the write's data, so wrong data reaches the disk through fsd, dosfs, isofs or install.
- Fix direction: tag each request in `user_data`, and drop the session after a timeout.

### DIST-3: after a rollback, `apply` overwrites the known-good rollback target
- Location: `lib/vx-slots/slots.c:189`; `servers/distd/distd.c:700`, `:714`
- Failure scenario: booted into c (a bad release), the admin runs `rollback`, which sets boot=b and previous=c. An `apply` before the reboot then writes over b, and a failed new release rolls back to c.
- Fix direction: track explicitly that `boot` was staged by an apply and has not booted.

### SVC-3: ptyd lets any process open any terminal's slave or ctl
- Location: `servers/ptyd/ptyd.c:221-226`, `:237-252`, `:270-277` (mode 0620 is reported but never enforced), `:288-303`, `:425-445`
- Failure scenario: a background program reads another session's keystrokes, a password at a prompt included, turns off its echo, or flushes its input. Known gap #305 covers only the `pgrp` side.
- Fix direction: use `attach_as`. The terminal belongs to whoever opened `ptmx`, and slave and ctl opens are checked against that owner.

### SVC-4: a peer advertising a zero window holds a released TCP connection forever
- Location: `lib/vx-net/tcp.c:133-143`, `:557-568`, `:687-707`
- Failure scenario: an attacker uses up the 32 conversations, which ICMP, UDP and TCP share, one connection at a time, until nobody on the machine can open a socket, ping or resolve a name.
- Fix direction: bound an orphaned connection's life with a probe-retry limit or a linger deadline, then reset it.

### SVC-5: hanging up a listener leaves its un-accepted connections behind, and the next listener in that slot accepts them
- Location: `lib/vx-net/tcp.c:673-678`, `:687-699`, `:609-621`; `servers/netd/netd.c:780-782`
- Failure scenario: process B's listener on port 9999 is handed process A's waiting port-80 call. If no listener reuses the slot, the waiting connection leaks one of the 32 conversations instead.
- Fix direction: reset waiting children when a listener stops listening, and have accept check the child's local port.

### SVC-6: a packet that claims the machine's own address as its source starts a loopback ACK storm (LAND)
- Location: `lib/vx-net/net.c:692-705`, `:328-333`; `lib/vx-net/tcp.c:388-393`, `:509-521`
- Failure scenario: one spoofed frame every two minutes keeps netd at 100% CPU. Broadcast sources are also let through, so replies go to 255.255.255.255.
- Fix direction: drop wire packets whose source is our own address, a broadcast address or 0 (RFC 1122 §3.2.1.3).

### SH-1: rc's ELF size check can wrap, so a crafted file makes it read before its `image` buffer
- Location: `cmd/rc.c:294-300` (`elf_needs`), `:333`, `:338`
- Failure scenario: running a hostile file faults or crashes rc, the console shell included.
- Fix direction: use `ckd_add` and per-field bounds, as `cmd/dbg.c:170` already does.

### SH-2: an error partway through an interactive pipeline leaks its stages, and no redirected file is ever closed after that
- Confidence: confirmed (repro)
- Location: `lib/vx-rc/rc.c:2932-2942`, `:2324-2339`, `:2311-2321`
- Failure scenario:
  1. `echo a | cat $nothing^x` fails partway through the pipeline.
  2. From then on, every redirection's close is deferred until the session ends.
  3. After 16 redirections, every new one fails with "too many files open".
- Fix direction: record `rc_nstages` in `rc_frame` and unwind it.

### SH-3: compiled rc code keeps 64 bytes of instruction space per source byte
- Confidence: confirmed (repro)
- Location: `lib/vx-rc/rc.c:3365`, `:3390-3401`; `cmd/rc.c:753` (the 4 MiB heap)
- Failure scenario: about 55 KB of functions, or a single 53 KB `switch`, runs the shell out of memory. Exported function libraries break child shells too.
- Fix direction: size the instruction and string space from what is actually emitted, and shrink it after compiling.

### SH-4: `-e` never applies to a pipeline
- Confidence: confirmed (repro)
- Location: `lib/vx-rc/rc.c:1667-1669`, `:1627-1628`; compare `../9front/sys/src/cmd/rc/havefork.c:96` and `code.c:418-425`
- Failure scenario: `rc -e` scripts such as `cc … | tee log` keep going after a failure that stops them on 9front.
- Fix direction: emit `X_EFLAG` after `X_PIPELINE`, checked against the last stage's status.

### SH-5: glob results are silently capped at 4096 names per directory
- Location: `lib/vx-rc/rc.c:2069`
- Failure scenario: `rm *` or `for(f in *.log)` in a large directory silently misses files.
- Fix direction: fail with "too many matches" instead, or drop the cap.

### BLD-2: ACPICA's port cache ignores the headers that are force-included into every object
- Location: `build.c:475-484`, `:1700-1712`; `ports/acpica/port.ndb:16`; `ports/acpica/acvectra.h:53`
- Failure scenario: an edit to `acvectra.h` or `lib/vx-mem/mem.h` leaves the old `libacpica.a`, which then silently disagrees with `bus-acpi.c`.
- Fix direction: hash `ports/<name>/` as a whole, plus any first-party header a port's flags name.

### BLD-3: the host tools' rebuild check misses most of what they include
- Location: `build.c:2825-2834` (vxstore), `:2998-3004` (vx9pserve), `:3020-3026` (vxfs)
- Failure scenario: a change to `store.def` leaves the old `out/host/vxstore`, so `./build release` writes records and trees in the old format.
- Fix direction: depfiles (`-MD`), or always rebuild these small tools.

### BLD-4 [WIP]: the 6d4c server change breaks `p9_server_test`
- Confidence: confirmed (ran: exit 1)
- Location: `tests/host/p9_server_test.c:324`
- Defect: the test still expects every Twstat to answer UNSUPPORTED, so `./build check` fails.
- Fix direction: update the assertion, and add host cases for each wstat outcome.

### BLD-5 [WIP]: the p9_server fuzzer cannot reach the new Twstat, ORCLOSE or DMAPPEND code
- Location: `tests/fuzz/p9_server_fuzz.c:93-101`
- Defect: the harness gives the server no `setattr`, `rename`, `remove`, `create`, `write` or `fsync` callbacks.
- Fix direction: writable fuzz callbacks with invariants: a rename stays inside the root, ORCLOSE removes only the node that was opened, and a failed wstat changes nothing.

### BLD-6: parallel scenario and per-arch processes rewrite shared generated files in place
- Confidence: plausible
- Location: `build.c:2552`, `:2564`, `:4929`, `:1473-1477`, `:3699-3706`, `:3485-3489`
- Failure scenario: a reader sees a short `out/man/index/base` while another process rewrites it, and a scenario fails or packs a broken index. `out/gen/usage` and vxstore have the same race.
- Fix direction: generate these once in the parent before forking, or write to a temporary file and `rename` it into place.

### BLD-7: `exits` cannot tell a power-off from a reset or a triple fault
- Location: `build.c:3155` (`-no-reboot`), `:3607-3608`, `:3655`; `tests/qemu/poweroff.ndb:7`
- Failure scenario: a kernel that triple-faults while writing the sleep register still passes `poweroff`.
- Fix direction: `-action reboot=pause`, or check the guest's shutdown event over QMP.

### BLD-8: ktest silently skips the whole protection-key suite when the kernel reports no keys
- Location: `tests/kernel/ktest.c:1672-1678`; `tests/qemu/ktest.ndb`
- Failure scenario: a regression in PKU detection on x86 turns 6c4's tests into a pass.
- Fix direction: expect `protection keys: 15` on x86 hosts with PKU, and pin ktest's check count.

## Low

**ARCH**
- **ARCH-6:** an x86 NMI or #MC in either swapgs window (`entry.S:77-80`, `:86-89`) runs with the user's GS base. This is latent, since no NMI source is wired up yet. The fix is the same as ARCH-1.
- **ARCH-7:** on aarch64, CNTKCTL_EL1 is only OR'd (`kernel/arch/aarch64/arch.c:579-582`), and PMUSERENR_EL0 and SCTLR_EL1's EL0 bits are left as firmware set them. Write them whole at CPU init.

**KERN**
- **KERN-6:** `task_exec` swaps root, maps, `map_next` and mapped but not `keys` (`kernel/syscall/syscall.c:949-954`; `kernel/obj/task.c:53`, `:634-659`). The new program keeps the old program's key allocations, which breaks ADR-0035's invariant that a freed key never names a live mapping, and keys pile up over a chain of execs until NO_SPACE.
- **KERN-7:** `mapping_privatize`, used by debugger writes, builds the new PTEs from W/X only and drops the protection key (`kernel/obj/exception.c:689-696`).
- **KERN-8:** `task_map` finds overlaps only through existing PTEs, so it misses a pager mapping's unsupplied pages (`kernel/obj/task.c:412-427`; `kernel/obj/pager.c:98-109`). Possible results are a fault loop, a wrong `task_protect` count, or a failed fork. No memory-safety consequence was found.
- **KERN-9:** past 64 threads, `thread_suspend` and `resume` work in batches by count over a list that new threads join at its head (`kernel/obj/exception.c:587-601`, `:638-678`), so a thread can be suspended twice or not at all. Plausible.
- **KERN-10:** `exception_divert` opens key 0 in PKRU before `arch_frame_divert` and does not restore it if the divert fails (`kernel/obj/exception.c:47-54`).

**RT**
- **RT-14:** `recvmsg` uses one static scatter buffer shared across lock-releasing waits (`ports/musl/vx/socket.c:721-739`), so concurrent MSG_WAITALL readers can receive each other's bytes.
- **RT-16:** `sig_deliver_in` clears pending bits non-atomically after acting on them (`signal.c:208-217`, `:253-256`), so a nested note can deliver a signal twice or lose a bit.
- **RT-17:** alternate signal stacks of MINSIGSTKSZ (2048) are accepted, but the XSAVE image on AVX-512 is about 2.7 KiB. `pipe_write` also keeps a 4 KiB buffer on the stack (`backend.c:311`, `lib/vx-rt/note.c:42`, `:104`, `fd.c:426`, `:663`).

**9P**
- **9P-5 [WIP]:** ORCLOSE permission is never checked at open (`lib/vx-9p/server.c:787-790`, `:224`). man/5/clunk says it is; fsd checks at clunk instead (`fsd.c:1150`). Check at open, or correct the page.
- **9P-6 [WIP]:** man/8/vx9pserve says ORCLOSE removes the host file, but `hostfs_open` refuses ORCLOSE (`host/vx9pserve/fs.c:193`).
- **9P-7 [WIP]:** ORCLOSE on dosfs can delete a different file that has taken over the directory slot (`servers/dosfs/dosfs.c:85`, `:217-225`). Make dosfs refuse ORCLOSE, or check the entry's identity at clunk.
- **9P-8 [WIP] (merged with RT-15):** the client's rename fallback for 9P2000 servers removes the target without POSIX's type checks (`ports/musl/vx/fd.c:1543-1551`; `p9c_rename_wstat`). Directory over file and file over directory both go through, and the target is gone if the second rename fails. A same-name EXISTS could delete the source.
- **9P-9:** an open union-directory read keeps a pointer into the namespace table across refreshes (`lib/vx-ns/ns.c:685`, `:701`, `:757`; `spawn.c:268-270`).

**FS**
- **FS-4:** fsd's 64-entry page cache can be filled by one client, after which every other Tmap fails (`servers/fsd/fsd.c:747`, `:899-911`).
- **FS-5 [WIP]:** `..` now walks out of a regular file, because `fs_parent` answers for files (`fsd.c:531-532`) and `p9_step` never checks QTDIR (`server.c:288-294`).
- **FS-6 [WIP]:** the Twstat rename's "replaces nothing" check treats ACCESS as absent (`server.c:678-683`; `fsd.c:504`, `:1232`), so a user with write but no search permission on a directory can replace an entry in it.
- **FS-7:** `none` counts as the leader of its own group in `may_setattr` (`fsd.c:1173`, `:1176-1178`; `lib/vx-users/users.c:47-61`).
- **FS-8:** rolling back an open branch leaves the restored orphans in place until fsd restarts (`fsd.c:484-489`, `:731-733`).
- **FS-9:** growing a mapped file exposes bytes a mapping wrote past the old end of file (`fsd.c:792-804`, `:860-883`).

**MEDIA**
- **MEDIA-4:** long-name assembly reads uninitialised stack memory when a deleted or out-of-sequence slot resets `expect` but not `count` (`lib/vx-fat/fat.c:362-383`). Confirmed under MSan.
- **MEDIA-5:** a name that needs more slots than one cluster holds fails once and leaves an allocated cluster behind (`fat.c:1014-1023`).
- **MEDIA-6:** truncate cuts the chain before it writes the smaller size (`fat.c:837-844`).
- **MEDIA-7:** dosfs truncates a read-only file through Tsetattr or Twstat (`servers/dosfs/dosfs.c:244-252`).

**DRV**
- **DRV-7:** bus-acpi's port grants are not recorded, so drv-rtc-cmos is later granted ports 0x70/0x71 that AML may still use (`devmgr.c:557-569`, `:665-676`).
- **DRV-8:** devmgr spins on an oversized message, or one carrying a handle, from bus-acpi or a clock driver (`devmgr.c:600-605`, `:718-719`, `:831-837`).
- **DRV-9:** virtio-blk's discard clamps in the wrong units and multiplies in 32 bits (`drivers/drv-virtio-blk/blk.c:153`, `:250`, `:337`).
- **DRV-10:** the UART drivers' receive loops have no bound (`drivers/drv-uart-16550/uart.c:60`, `:64`; `drivers/drv-uart-pl011/uart.c:58`).

**DIST**
- **DIST-4:** install copies every `b2/` entry on the medium into the store without checking it or its name, and `b2/..<64>` lands in the store root (`cmd/install.c:297-313`).
- **DIST-5:** install's `check_tree` recursion has no bound, so a medium of shared directories takes exponential time or overflows the stack (`cmd/install.c:88-127`, `:154-161`).
- **DIST-6:** after `rescan`, a release's `tree/` node keeps serving the old tree (`servers/distd/distd.c:256-264`, `:353-358`).

**SVC**
- **SVC-7:** any unacceptable segment restarts TIME_WAIT (`lib/vx-net/tcp.c:388-393`).
- **SVC-8:** ptyd treats a control character set to 0 as NUL rather than as disabled (`servers/ptyd/ptyd.c:172-203`).
- **SVC-9:** TCP has no RFC 5961 §5 check of the ACK value (`tcp.c:266`). Plausible.
- **SVC-10:** any process can use up netd's 16 cs/dns slots and vx-net's 16 DNS entries (`netd.c:292`, `:478-488`; `dns.c:240-256`).

**SH**
- **SH-6:** exported function names are not quoted (`cmd/rc.c:384-389`), so a newline in a name runs commands in every child rc. 9front uses `%q`.
- **SH-7:** every word is globbed or deglobbed whatever its origin (`lib/vx-rc/rc.c:2762`, `:3085`, `:3125`, `:3181`, `:3303`), so data containing byte 0x01 is changed. 9front globs only words marked at compile time.
- **SH-8:** imported environment lists are silently cut at 4096 words (`cmd/rc.c:423`).
- **SH-9:** profiling zone ids grow past the 64-name table and are not thread-safe (`lib/vx-prof/prof.h:95-101`).

**BLD**
- **BLD-9 [WIP]:** the Known gaps rows removed for 6d4c claim more than the u9fs tests cover. Truncate, utimens, rename over an existing file and EXDEV are untested, and of the ORCLOSE servers only fsd and tmpfs are tested.
- **BLD-10:** the host tools (`host/vx9pserve`, `host/vxfs`, `host/vxstore`) are outside clang-tidy and the analyzer (`build.c:4392-4426`).
- **BLD-11:** `release`, `image` and `test` never run vendor-check (`build.c:2901-2903`, `:4942`).
- **BLD-12:** the Scenarios table lists 23 of the 54 `tests/qemu` files. The harness comment says each phase ends in a power-off, but the code kills QEMU, so install's power-off is never checked (`build.c:3384-3386` vs `:3536-3537`).

---

## Read and not found suspicious

Recorded so the next pass can spend its time elsewhere.

- **KERN:**
  - object refcounts and the dying list;
  - the handle table and duplicate rights;
  - vmo.c, and pager supply, wait, dirty and resize;
  - channel.c, including channel_call, and the port, counter and ring objects;
  - device.c;
  - futex keying and the `thread_set_robust` checks;
  - the scheduler's wake logic;
  - process start, exit, reap and teardown;
  - exception stop, resume and park;
  - unmap, protect and fork splits;
  - kstack guard pages, phys.c and elf.c.
- **ARCH:**
  - context switch and the AP and park stubs on both architectures;
  - TLB shootdown;
  - PTE construction and protection-key bits;
  - `arch_frame_set_regs` and `arch_frame_divert`;
  - FP save and load, `simd_begin`/`simd_end`, `arch_fp_check`;
  - user copies and fault fixups;
  - futex address checks and watchpoint validation;
  - the map/unmap/revoke ordering of VT-d and the SMMU;
  - the ITS, GIC and IOAPIC, and the I/O port bitmap.
- **RT:**
  - vx-mem, vx-rand's DRBG, vx-posix's note parsing and vx-note;
  - the vx-rt ELF loader;
  - start.c's argv, environment and auxv sizing;
  - memory.c's overflow checks and `time_deadline`;
  - `__clone` and robust-list registration;
  - fork's TLS and rights.
- **9P:**
  - codec decoding;
  - vx-ring header and index checks;
  - the ring server's flush and completions;
  - the ring client's slot and generation checks;
  - Twalk confinement and fid lifetime;
  - lock ranges and Tshare token comparison (constant time);
  - vx9pserve's `O_NOFOLLOW` walks;
  - the newns and nsd parsers.
- **FS:**
  - blk.c's checks, log replay and retirement;
  - tree.c's check_table, merge and split;
  - vol.c's commit phases and mount repair;
  - the rest of file.c;
  - check.c and vx-users parsing;
  - fsd's ctl splitter, `may` and `is_adm`, and OJOIN.
- **MEDIA:**
  - vx-gpt and partd;
  - vx-iso's SUSP walk and its CE cap;
  - the FAT mount, chains and directory iteration;
  - tmpfs (WIP hunks included), nullfs, sysfs and bootfs;
  - the vx-tar reader and vx-utf.
- **DRV:**
  - drv-nvme's CQ ids, PRP lists and MSI-X;
  - the virtio used rings;
  - vx-pci's capability walk;
  - bus-acpi's table handling;
  - svcd's manifests and restarts;
  - the RTC's BCD checks.
- **DIST:**
  - vx-store's hash domains and `index_check`;
  - distd's adm-only ctl and walk filtering;
  - `copy_to_slot`'s per-block checks;
  - the vx-tar reader;
  - the vx-slots parser and writer;
  - the DRBG's ratchet;
  - share-token comparison.
- **SVC:**
  - vx-net framing and every buffer bound;
  - TCP options, SYN and RST handling;
  - DNS decompression and DHCP options;
  - procfs's parsers and its root refusals;
  - ptyd's line buffer bounds.
- **SH:**
  - the vx-rc interpreter: 2.4M fuzzed scripts under ASan/UBSan, no memory errors;
  - vx-guide, vx-ndb and vx-man;
  - vx-debug's ELF, DWARF and eval;
  - the rest of cmd/*.
- **BLD:**
  - command construction (no shell);
  - self-rebuild;
  - the musl family's port hashes;
  - vendor-check's fail-closed rules;
  - the format and tidy gates;
  - harness parsing caps;
  - test wiring;
  - the other fuzz harnesses;
  - the WIP wstattest.

## Suggested order once M6 is done

1. Kernel: KERN-1, ARCH-1, KERN-3, KERN-2, ARCH-3, ARCH-2. Then KERN-4 and KERN-5, and ARCH-5's hardening.
2. Back end: RT-1 to RT-7, with tests: three-waiter broadcast, cancel, close-while-reading, threaded spawn, two-thread waitpid.
3. Permissions: SVC-1, SVC-3, FS-1, FS-3. Device trust: DRV-1 to DRV-5.
4. Trust chain: DIST-1, DIST-2, DIST-3.
5. The tests that cannot fail: BLD-1, BLD-7, BLD-8. Then the rest by area.

The [WIP] items (9P-3, 9P-5 to 9P-8, FS-5, FS-6, RT-11, BLD-4, BLD-5, BLD-9) belong to 6d4c and are cheapest to settle before that step is committed.
