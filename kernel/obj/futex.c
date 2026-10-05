// futex.c: futexes (docs/01 §4.6). A futex is keyed on the VMO that holds its
// word and the word's offset in it (ADR-0037), so the same word mapped into
// two tasks is one futex, and a pager's page evicted and supplied again
// elsewhere keeps its key. Waiters hash into buckets, each with its own lock.
// futex_wait checks the word under the bucket's lock, so a futex_wake that
// changes the word first is never missed.
//
// Robust futexes (ADR-0037, Linux's layout): a thread registers a list of the
// locks it holds, and as it ends the kernel marks each one it still owns
// OWNER_DIED and wakes a waiter.

static constexpr uint32_t FUTEX_BUCKETS = 64;

typedef struct futex_key {
  const void *vmo; // the VMO the word is in
  uint64_t offset; // the word's offset in it
} futex_key;

typedef struct futex_waiter {
  struct futex_waiter *next;
  thread *thread;
  futex_key key;
} futex_waiter;

static struct {
  spinlock lock;
  futex_waiter *head;
} futex_buckets[FUTEX_BUCKETS];

static uint32_t futex_bucket(futex_key k) {
  return (uint32_t)((((uint64_t)k.vmo >> 4) ^ (k.offset >> 2)) * 0x9e3779b97f4a7c15ull >> 58);
}

static bool futex_key_eq(futex_key a, futex_key b) { return a.vmo == b.vmo && a.offset == b.offset; }

// The key of the word at user address word in task t, and whether its page is
// present. False if no mapping holds it, or it is device memory.
static bool futex_key_of(task *t, uint64_t word, futex_key *k, bool *present) {
  bool found = false;
  spin_lock(&t->lock);
  for (uint32_t i = 0; t->maps && i < TASK_MAX_MAPPINGS && !found; i++) {
    const mapping *m = &t->maps[i];
    if (!m->size || word < m->va || word - m->va >= m->size || m->vmo->physical) continue;
    *k = (futex_key){.vmo = m->vmo, .offset = m->offset + (word - m->va)};
    found = true;
  }
  *present = found && t->root && user_page_pa(t->root, word) != 0;
  spin_unlock(&t->lock);
  return found;
}

// Blocks while *word (user address, in the current task) holds `expected`, until
// futex_wake or the deadline. BAD_STATE if the word already differs, or its
// page is absent (a pager's, evicted): the caller loads it, which brings the
// page back, and asks again.
static vx_status futex_wait(uint64_t word, uint32_t expected, vx_instant deadline) {
  if ((word & 3) || word >= USER_TOP) return VX_ERR_INVALID;
  thread *t = this_cpu()->current;
  futex_key key;
  bool present;
  if (!futex_key_of(t->task, word, &key, &present)) return VX_ERR_INVALID;
  if (!present) return VX_ERR_BAD_STATE;
  uint32_t i = futex_bucket(key);
  futex_waiter w = {.thread = t, .key = key};
  spin_lock(&futex_buckets[i].lock);
  // Read through the task's own mapping, not the page: if another thread has
  // unmapped the word since, the load fails rather than read a freed page.
  uint32_t now;
  if (!arch_user_load32((const uint32_t *)word, &now)) {
    spin_unlock(&futex_buckets[i].lock);
    return VX_ERR_BAD_STATE;
  }
  if (now != expected) {
    spin_unlock(&futex_buckets[i].lock);
    return VX_ERR_BAD_STATE;
  }
  t->wait_token = &w;
  w.next = futex_buckets[i].head;
  futex_buckets[i].head = &w;
  spin_unlock(&futex_buckets[i].lock);

  int64_t woke = thread_block(deadline, 0);
  if (woke != VX_OK) { // timed out or killed: leave the bucket if a waker has not already taken us
    spin_lock(&futex_buckets[i].lock);
    for (futex_waiter **link = &futex_buckets[i].head; *link; link = &(*link)->next) {
      if (*link == &w) {
        *link = w.next;
        break;
      }
    }
    spin_unlock(&futex_buckets[i].lock);
  }
  return (vx_status)woke;
}

// Wakes up to `count` threads waiting on *word. Returns how many it woke.
static int64_t futex_wake(uint64_t word, uint32_t count) {
  if ((word & 3) || word >= USER_TOP) return VX_ERR_INVALID;
  futex_key key;
  bool present;
  if (!futex_key_of(this_cpu()->current->task, word, &key, &present)) return VX_ERR_INVALID;
  uint32_t i = futex_bucket(key), woken = 0;
  spin_lock(&futex_buckets[i].lock);
  for (futex_waiter **link = &futex_buckets[i].head; *link && woken < count;) {
    futex_waiter *w = *link;
    if (!futex_key_eq(w->key, key)) {
      link = &w->next;
      continue;
    }
    *link = w->next;
    if (thread_wake_token(w->thread, w, VX_OK)) woken++;
  }
  spin_unlock(&futex_buckets[i].lock);
  return woken;
}

// --- Robust futexes (ADR-0037) ---

static constexpr uint32_t ROBUST_LIST_LIMIT = 2048; // entries walked at most: the list is the thread's memory

static vx_status copy_from_user(void *dst, uint64_t src, uint64_t len); // syscall.c

// One lock word of a thread that has ended: OWNER_DIED, waiters kept, and one
// of them woken, if the word is still the thread's.
static void futex_owner_died(uint64_t word, uint32_t owner) {
  if ((word & 3) || word >= USER_TOP) return;
  uint32_t seen;
  if (!arch_user_load32((const uint32_t *)word, &seen)) return;
  for (int tries = 0; tries < 64; tries++) { // another thread changing it each time: hostile, let go
    if ((seen & VX_FUTEX_OWNER_MASK) != owner) return;
    uint32_t now;
    if (!arch_user_cas32((uint32_t *)word, seen, (seen & VX_FUTEX_WAITERS) | VX_FUTEX_OWNER_DIED, &now))
      return;
    if (now == seen) {
      if (seen & VX_FUTEX_WAITERS) futex_wake(word, 1);
      return;
    }
    seen = now;
  }
}

// Walks thread th's robust list, which is in the current address space, and
// unregisters it. A bad pointer ends the walk.
static void futex_robust_walk(thread *th) {
  uint64_t head = th->robust_head;
  uint32_t owner = th->robust_owner;
  th->robust_head = 0;
  if (!head) return;
  struct {
    uint64_t next;
    int64_t offset;
    uint64_t pending;
  } h;
  if (copy_from_user(&h, head, sizeof h) != VX_OK) return;
  uint64_t entry = h.next & ~1ull; // bit 0: Linux's mark for a PI lock, which there are none of
  for (uint32_t n = 0; entry != head && n < ROBUST_LIST_LIMIT; n++) {
    uint64_t next;
    if (copy_from_user(&next, entry, sizeof next) != VX_OK) break;
    if (entry != (h.pending & ~1ull)) futex_owner_died(entry + (uint64_t)h.offset, owner);
    entry = next & ~1ull;
  }
  if (h.pending) futex_owner_died((h.pending & ~1ull) + (uint64_t)h.offset, owner);
}

// thread_set_robust(head, size, owner): the calling thread's robust list.
static int64_t sys_thread_set_robust(uint64_t head, uint64_t size, uint64_t owner) {
  if (head && (size != 24 || (head & 7) || head >= USER_TOP || !owner || owner > VX_FUTEX_OWNER_MASK))
    return VX_ERR_INVALID;
  thread *th = this_cpu()->current;
  th->robust_head = head;
  th->robust_owner = (uint32_t)owner;
  return VX_OK;
}
