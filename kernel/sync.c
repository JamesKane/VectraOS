// sync.c: spinlocks. The kernel runs with interrupts off, so a lock never has to
// guard against an interrupt on its own CPU, only against the other CPUs.
//
// A ticket lock: a CPU takes the next ticket and waits for it to come up, so
// CPUs get the lock in the order they asked. All zeroes is an unlocked lock.

#include <stdatomic.h>

typedef struct spinlock {
  _Atomic uint32_t next;  // the next ticket to hand out
  _Atomic uint32_t owner; // the ticket that holds the lock
} spinlock;

static void spin_lock(spinlock *l) {
  uint32_t ticket = atomic_fetch_add_explicit(&l->next, 1, memory_order_relaxed);
  while (atomic_load_explicit(&l->owner, memory_order_acquire) != ticket) arch_pause();
}

static void spin_unlock(spinlock *l) { atomic_fetch_add_explicit(&l->owner, 1, memory_order_release); }
