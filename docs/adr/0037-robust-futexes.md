# ADR-0037: Robust futexes

Status: accepted, 2026-10-06 (proposed 2026-10-05). M6 step 6d3's change to the ABI (01 §3, §13 question 6, decided 2026-10-04: robust futexes in Linux's layout). It adds one syscall, `thread_set_robust`, which 01 §2's list already names, and changes how futexes are keyed. It also gives the POSIX layer's thread ids a form the lock words can hold.

## Context

A futex in shared memory (a VMO two tasks map, or a file both map `MAP_SHARED`) can be held by a thread that then dies. When it does, every waiter sleeps for ever. Linux's answer, which musl's `PTHREAD_MUTEX_ROBUST` is written against, has four parts:
- the lock word holds the owner's thread id;
- each thread registers a list of the robust locks it holds;
- when a thread ends, the kernel walks the list, sets an owner-died bit in each word the thread still holds, and wakes a waiter;
- that waiter's lock returns `EOWNERDEAD`.

musl walks the list itself when a thread calls `pthread_exit`. A thread that is killed, a process that crashes, and a process that execs do not get there, so those are the kernel's to handle.

Two things in the tree stand in the way.
- **Futex keys.** Futexes are keyed by the physical address of the word, so the same word mapped into two tasks is one futex. A pager may evict a clean page (`vmo_op` EVICT, docs/11 §8) and supply it again later in a different physical page, so a waiter that went to sleep before the eviction is keyed on a page that is gone. Checked in 6d3: the wake that follows computes the new key, and the waiter sleeps to its deadline. The freed page can also be reused by someone else, whose wakes then reach it.
- **POSIX thread ids.** Since 6d2a these are the kernel thread id with bit 30 set. Bit 30 is the owner-died bit of a lock word, and the id has to fit in its 30 low bits. musl's recursive and error-checking mutexes mask the word to 30 bits and compare it with the thread's id, so on any thread but the first they already misjudge their owner.

## Decision

1. **The lock word** is Linux's: bit 31 `WAITERS`, bit 30 `OWNER_DIED`, bits 0 to 29 the owner. The owner is whatever value the thread registered; the kernel does not choose it.
2. **`thread_set_robust(head, size, owner)`** registers the calling thread's robust list:
   - <head> is the user address of a list head in Linux's form, three words: the first entry (a ring, which ends at the head), the offset from an entry to its lock word, and the entry being added or removed now (or 0);
   - <size> is 24;
   - <owner> is the value of the thread's lock words, 1 to 2^30 - 1.
   A <head> of 0 unregisters. A bad <size> or <owner> is `INVALID`. The list is the caller's only.
3. **When a thread ends** (`thread_exit`, a kill, its task's end) the kernel walks its list, before its address space goes. The same walk runs at `task_exec`, before the old address space is given up, after which the registration is cleared.
   - The walk takes at most 2048 entries, plus the pending one.
   - It reads user memory through the fault-safe copies, so a bad pointer ends the walk.
   - For each word whose owner bits are the thread's owner, it sets the word to `OWNER_DIED`, keeping `WAITERS`, by a fault-safe compare-and-swap. If `WAITERS` was set, it wakes one waiter.
   - Words the thread does not own are left alone.
   A new thread has no list, nor do fork's thread and exec's new one.
4. **Futexes are keyed by VMO and offset,** not by physical address. The kernel finds the mapping that holds the word, and the key is the VMO plus the word's offset in it. One VMO mapped by two tasks, or two mappings of one file's pager VMO, is still one futex, and a page that is evicted and supplied again keeps its key. A `futex_wait` on a word whose page is absent returns `BAD_STATE`, as for a word that has changed, so the caller loads it again in user mode, which faults the page in, and retries.
5. **The POSIX layer's thread ids:** the first thread's id stays the pid. Another thread's is its slot in the back end's thread table (1 to 255) shifted left 22, plus the pid. So the id fits in 30 bits and is unique across processes while pids stay under 2^22, the cap Linux's pids have too. That limits a POSIX process to 255 live threads besides its first; past that, `pthread_create` fails with `EAGAIN`. Native threads (libvx) are not limited by this.
6. **The musl back end** maps `set_robust_list` onto `thread_set_robust` with the thread's id as <owner>. `PTHREAD_MUTEX_ROBUST`, `EOWNERDEAD` and `pthread_mutex_consistent` are then musl's own.

## Consequences

- The ABI gains `thread_set_robust`. Futex keys change inside the kernel only, though a `futex_wait` on an absent page now answers `BAD_STATE`.
- A futex call looks up its mapping, a scan of at most 85 entries under the task's lock, where it used to walk the page tables.
- A process killed while holding a shared robust mutex no longer hangs the processes that share it. ctest covers it through a `MAP_SHARED` file, and ktest through a shared VMO and a raw child task.
- Pids past 2^22 would give thread ids that overlap. Task ids are not reused, so a system that has created four million tasks reaches that. It is recorded as a known gap.

## Alternatives

- **The kernel choosing the owner value** (its thread id): the kernel's thread ids are per task, so two processes sharing a lock could have the same one. The C library already has an id in every lock it takes.
- **Walking at task teardown,** after the threads have gone: by then nothing says which thread held which word, and the address space may already be gone.
- **Keeping physical keys and pinning pages that have waiters:** it needs a count per page, and it keeps a pager from evicting memory it was asked to free.
- **Wider POSIX thread ids:** the lock word has 30 bits, and Linux's layout is what musl expects.
