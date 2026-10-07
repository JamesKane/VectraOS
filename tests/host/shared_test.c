// shared_test.c: <vx/shared.h> (lib/vx-shared): offsets inside a VMO's
// bounds and aligned, none whose sum wraps, arrays checked whole, and links
// between VMOs through the table at the head: a slot past the table, a
// position past the message's handles and an offset past the VMO it names
// all refused.

#include <string.h>

#include "check.h"
#include "../../lib/vx-shared/shared.h"

typedef struct node {
  uint64_t next; // an offset, 0 for none
  uint32_t value;
  uint32_t pad;
} node;

int main(void) {
  static _Alignas(16) uint8_t a[256], b[64];
  vx_shared sa = {a, sizeof a}, sb = {b, sizeof b};
  CHECK(VX_SHARED_AT(sa, 0, node) == (const node *)a &&
        VX_SHARED_AT(sa, 240, node) == (const node *)(a + 240));
  CHECK(!VX_SHARED_AT(sa, 248, node));                                // runs past the end
  CHECK(!VX_SHARED_AT(sa, 4, node));                                  // misaligned
  CHECK(!VX_SHARED_AT(sa, UINT64_MAX - 7, node));                     // a sum that would wrap
  CHECK(!vx_shared_at(sa, 257, 0, 1) && vx_shared_at(sa, 256, 0, 1)); // the end itself, empty
  CHECK(!vx_shared_at((vx_shared){}, 0, 1, 1));
  CHECK(vx_shared_array(sa, 0, 16, sizeof(node), alignof(node)) &&
        !vx_shared_array(sa, 0, 17, sizeof(node), 8));
  CHECK(!vx_shared_array(sa, 0, UINT64_MAX / 2, 4, 4)); // n * each would wrap

  // A list: followed node by node, each link checked; a bad one stops it.
  node *n0 = (node *)a, *n1 = (node *)(a + 64), *n2 = (node *)(a + 128);
  *n0 = (node){.next = 64, .value = 1}, *n1 = (node){.next = 128, .value = 2},
  *n2 = (node){.next = 0, .value = 3};
  uint32_t sum = 0, hops = 0;
  for (const node *n = VX_SHARED_AT(sa, 0, node); n && hops < 8; hops++) {
    sum += n->value;
    n = n->next ? VX_SHARED_AT(sa, n->next, node) : nullptr;
  }
  CHECK(sum == 6 && hops == 3);
  n1->next = 1000; // out of bounds: refused, not followed
  CHECK(!VX_SHARED_AT(sa, n1->next, node));

  // Links between VMOs: a's table names message positions 1 and 0.
  memset(a, 0, sizeof a);
  vx_shared_table *t = (vx_shared_table *)a;
  t->count = 2, t->position[0] = 1, t->position[1] = 0;
  memcpy(b + 16, "hello", 6);
  vx_shared views[2] = {sa, sb};
  CHECK(vx_shared_follow(sa, views, 2, (vx_shared_link){.slot = 0, .offset = 16}, 6, 1) == b + 16);
  CHECK(vx_shared_follow(sa, views, 2, (vx_shared_link){.slot = 1, .offset = 16}, 6, 1) == a + 16);
  CHECK(!vx_shared_follow(sa, views, 2, (vx_shared_link){.slot = 2, .offset = 0}, 1, 1));  // past the table
  CHECK(!vx_shared_follow(sa, views, 1, (vx_shared_link){.slot = 0, .offset = 0}, 1, 1));  // past the handles
  CHECK(!vx_shared_follow(sa, views, 2, (vx_shared_link){.slot = 0, .offset = 60}, 6, 1)); // past b
  CHECK(!vx_shared_follow(sa, views, 2, (vx_shared_link){.slot = 0, .reserved = 1}, 1, 1)); // not 0
  t->count = 1'000'000; // a table longer than its VMO
  CHECK(!vx_shared_follow(sa, views, 2, (vx_shared_link){.slot = 0, .offset = 16}, 6, 1));
  return check_result();
}
