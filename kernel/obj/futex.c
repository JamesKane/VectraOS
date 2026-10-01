// futex.c: futexes (docs/01 §4.6). A futex is keyed on the physical address of
// its word, so the same word mapped into two tasks is one futex. Waiters hash
// into buckets, each with its own lock. futex_wait checks the word under the
// bucket's lock, so a futex_wake that changes the word first is never missed.

static constexpr uint32_t FUTEX_BUCKETS = 64;

typedef struct futex_waiter {
  struct futex_waiter *next;
  thread *thread;
  uint64_t key; // physical address of the word
} futex_waiter;

static struct {
  spinlock lock;
  futex_waiter *head;
} futex_buckets[FUTEX_BUCKETS];

static uint32_t futex_bucket(uint64_t key) { return (uint32_t)((key >> 2) * 0x9e3779b97f4a7c15ull >> 58); }

// Blocks while *word (user address, in the current task) holds `expected`, until
// futex_wake or the deadline. BAD_STATE if the word already differs.
static vx_status futex_wait(uint64_t word, uint32_t expected, vx_instant deadline) {
  if ((word & 3) || word >= USER_TOP) return VX_ERR_INVALID;
  thread *t = this_cpu()->current;
  uint64_t key = user_page_pa(t->task->root, word);
  if (!key || !in_direct_map(key, 4)) return VX_ERR_INVALID; // device memory has no direct mapping
  uint32_t i = futex_bucket(key);
  futex_waiter w = {.thread = t, .key = key};
  spin_lock(&futex_buckets[i].lock);
  // Read through the task's own mapping, not the page: if another thread has
  // unmapped the word since, the load fails rather than read a freed page.
  uint32_t now;
  if (!arch_user_load32((const uint32_t *)word, &now)) {
    spin_unlock(&futex_buckets[i].lock);
    return VX_ERR_INVALID;
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
  if (word & 3) return VX_ERR_INVALID;
  uint64_t key = user_page_pa(this_cpu()->current->task->root, word);
  if (!key) return VX_ERR_INVALID;
  uint32_t i = futex_bucket(key), woken = 0;
  spin_lock(&futex_buckets[i].lock);
  for (futex_waiter **link = &futex_buckets[i].head; *link && woken < count;) {
    futex_waiter *w = *link;
    if (w->key != key) {
      link = &w->next;
      continue;
    }
    *link = w->next;
    if (thread_wake_token(w->thread, w, VX_OK)) woken++;
  }
  spin_unlock(&futex_buckets[i].lock);
  return woken;
}
