// SPDX-License-Identifier: BSD-3-Clause

#include "idl_c_tests.h"

#include <test_ipc.h>
#include <stdlib.h>
#include <string.h>

// Handles to send and get back: counters, whose values say which is which
// (V1 has no events, D23).
static int64_t counter_create(uint32_t *out) {
  return croi_syscall(CROI_SYS_COUNTER_CREATE, 0, (uint64_t)(uintptr_t)out, 0, 0, 0);
}
static int64_t counter_value(uint32_t counter) {
  int64_t value = -1;
  int64_t s = croi_syscall(CROI_SYS_COUNTER_READ, counter, (uint64_t)(uintptr_t)&value, 0, 0, 0);
  return s == CROI_OK ? value : s;
}

uint32_t idl_c_encode_say(uint8_t *out, uint32_t capacity) {
  td_wire_msg_t *m = malloc(sizeof *m);
  if (!m) return 0;
  uint32_t n = 0;
  if (echo_say_encode(m, 1, "hi", 2, 3) == CROI_OK && m->byte_count <= capacity) {
    memcpy(out, m->bytes, m->byte_count);
    n = m->byte_count;
  }
  free(m);
  return n;
}

int32_t idl_c_decode_say_reply(const uint8_t *bytes, uint32_t count, char *text, uint32_t capacity) {
  td_wire_msg_t *m = malloc(sizeof *m);
  if (!m || count > sizeof m->bytes) {
    free(m);
    return CROI_ERR_OUT_OF_RANGE;
  }
  memcpy(m->bytes, bytes, count);
  m->byte_count = count;
  m->handle_count = 0;
  const char *result;
  uint32_t len;
  int32_t s = echo_say_decode_reply(m, &result, &len);
  if (s == CROI_OK) {
    if (len + 1 > capacity) {
      s = CROI_ERR_BUFFER_TOO_SMALL;
    } else {
      memcpy(text, result, len);
      text[len] = 0;
    }
  }
  free(m);
  return s;
}

int idl_c_utf8_valid(const uint8_t *bytes, uint32_t count) { return td_wire_utf8_valid(bytes, count); }

#define CHECK(cond)              \
  do {                           \
    if (!(cond)) return __LINE__; \
  } while (0)

static const td_wire_str_t tags[] = {{"a", 1}, {"", 0}, {"ccc", 3}};
static const test_ipc_point_t path[] = {{1, 2}, {INT32_MIN, INT32_MAX}};
static const uint8_t data[] = {0, 255, 7};
static const td_wire_str_t label = {"tri", 3};
static const uint16_t weight = 513;

// The Shaped the Swift tests call `sample`.
static test_ipc_shaped_t sample(void) {
  test_ipc_shaped_t s = {
      .shape = TEST_IPC_SHAPE_TRIANGLE,
      .at = {-3, 4},
      .label = &label,
      .tags = {tags, 3},
      .path = {path, 2},
      .weight = &weight,
      .data = {data, 3},
      .flag = true,
  };
  return s;
}

uint32_t idl_c_encode_reflect(uint8_t *out, uint32_t capacity) {
  td_wire_msg_t *m = malloc(sizeof *m);
  uint32_t n = 0;
  test_ipc_shaped_t s = sample();
  if (echo_reflect_encode(m, 1, &s) == CROI_OK && m->byte_count <= capacity) {
    memcpy(out, m->bytes, m->byte_count);
    n = m->byte_count;
  }
  free(m);
  return n;
}

int32_t idl_c_decode_reflect_reply(const uint8_t *bytes, uint32_t count) {
  static td_wire_msg_t m;
  static uint8_t memory[65536];
  td_wire_arena_t arena = {memory, sizeof memory, 0};
  test_ipc_shaped_t out;
  if (count > sizeof m.bytes) return CROI_ERR_OUT_OF_RANGE;
  memcpy(m.bytes, bytes, count);
  m.byte_count = count;
  m.handle_count = 0;
  return echo_reflect_decode_reply(&m, &arena, &out);
}

static int same_str(td_wire_str_t a, td_wire_str_t b) { return a.len == b.len && memcmp(a.data, b.data, a.len) == 0; }

// Whether `got` is `sample()`, field by field.
static int is_sample(const test_ipc_shaped_t *got) {
  test_ipc_shaped_t want = sample();
  CHECK(got->shape == want.shape && got->at.x == -3 && got->at.y == 4 && got->flag);
  CHECK(got->label && same_str(*got->label, label));
  CHECK(got->tags.count == 3);
  for (uint32_t i = 0; i < 3; i++) CHECK(same_str(got->tags.items[i], tags[i]));
  CHECK(got->path.count == 2 && got->path.items[1].x == INT32_MIN && got->path.items[1].y == INT32_MAX);
  CHECK(got->weight && *got->weight == 513);
  CHECK(got->data.len == 3 && memcmp(got->data.data, data, 3) == 0);
  return 0;
}

static int typed_calls(uint32_t ch, td_wire_msg_t *buf) {
  int32_t code = 0;
  static uint8_t memory[16384];
  td_wire_arena_t arena = {memory, sizeof memory, 0};

  test_ipc_shaped_t in = sample(), out;
  CHECK(echo_reflect(ch, buf, &code, &in, &arena, &out) == CROI_OK);
  CHECK(is_sample(&out) == 0);
  // Too little arena for the reply's vectors: the decode says so.
  td_wire_arena_t tiny = {memory, 8, 0};
  CHECK(echo_reflect(ch, buf, &code, &in, &tiny, &out) == CROI_ERR_BUFFER_TOO_SMALL);

  // many: the shapes back, one per nested list (its sum as the weight),
  // and one for `maybe`.
  arena.used = 0;
  const uint32_t l0[] = {1, 2, 3}, l2[] = {10};
  const test_ipc_vec_uint32_t lists[] = {{l0, 3}, {NULL, 0}, {l2, 1}};
  test_ipc_vec_shaped_t shapes = {&in, 1}, many;
  test_ipc_vec_point_t maybe = {path, 1};
  CHECK(echo_many(ch, buf, &code, shapes, (test_ipc_vec_vec_uint32_t){lists, 3}, &maybe, &arena, &many) == CROI_OK);
  CHECK(many.count == 5 && is_sample(&many.items[0]) == 0);
  CHECK(*many.items[1].weight == 6 && *many.items[2].weight == 0 && *many.items[3].weight == 10);
  CHECK(many.items[4].shape == TEST_IPC_SHAPE_TRIANGLE && many.items[4].path.count == 1 && !many.items[4].weight);
  CHECK(echo_many(ch, buf, &code, (test_ipc_vec_shaped_t){NULL, 0}, (test_ipc_vec_vec_uint32_t){NULL, 0}, NULL,
                  &arena, &many) == CROI_OK);
  CHECK(many.count == 0);

  // optionals: the handle comes back only if everything else was present.
  uint32_t event, back = TD_WIRE_NO_HANDLE;
  CHECK(counter_create(&event) == CROI_OK);
  td_wire_str_t text = {"t", 1};
  td_wire_bytes_t none = {NULL, 0};
  test_ipc_point_t point = {1, 1};
  CHECK(echo_optionals(ch, buf, &code, &text, &none, &point, event, &back) == CROI_OK);
  CHECK(back != TD_WIRE_NO_HANDLE && croi_handle_close(back) == CROI_OK);
  CHECK(echo_optionals(ch, buf, &code, NULL, &none, NULL, TD_WIRE_NO_HANDLE, &back) == CROI_OK);
  CHECK(back == TD_WIRE_NO_HANDLE);

  // carry: a struct with two handles, which come back swapped.
  uint32_t a, b;
  CHECK(counter_create(&a) == CROI_OK && counter_create(&b) == CROI_OK);
  CHECK(croi_counter_add(a, 24) == CROI_OK && croi_counter_add(b, 25) == CROI_OK);
  test_ipc_carried_t carried = {{"box", 3}, a, b, &in}, got;
  arena.used = 0;
  CHECK(echo_carry(ch, buf, &code, &carried, &arena, &got) == CROI_OK);
  CHECK(got.name.len == 4 && memcmp(got.name.data, "box!", 4) == 0 && got.inner && is_sample(got.inner) == 0);
  CHECK(counter_value(got.handle) == 25 && counter_value(got.spare) == 24);
  CHECK(croi_handle_close(got.handle) == CROI_OK && croi_handle_close(got.spare) == CROI_OK);
  return 0;
}

static int echo_client(uint32_t ch, td_wire_msg_t *buf) {
  int32_t code = 0;
  const char *text;
  uint32_t len;
  CHECK(echo_say(ch, buf, &code, "hi", 2, 3, &text, &len) == CROI_OK);
  CHECK(len == 6 && memcmp(text, "hihihi", 6) == 0);
  CHECK(echo_say(ch, buf, &code, "long", 4, 100, &text, &len) == TD_ERR_REMOTE);
  CHECK(code == ECHO_ERROR_TOO_LONG);

  CHECK(echo_note(ch, buf, 5, false) == CROI_OK);
  CHECK(echo_note(ch, buf, 5, true) == CROI_OK);
  uint64_t noted = 0;
  CHECK(echo_noted(ch, buf, &code, &noted) == CROI_OK);
  CHECK(noted == 15);

  // The handle goes to the server and comes back: the same counter, as
  // the value it had before sending shows.
  uint32_t event, back = TD_WIRE_NO_HANDLE;
  CHECK(counter_create(&event) == CROI_OK);
  CHECK(croi_counter_add(event, 24) == CROI_OK);
  CHECK(echo_swap(ch, buf, &code, event, &back) == CROI_OK);
  CHECK(back != TD_WIRE_NO_HANDLE);
  CHECK(croi_counter_add(event, 1) == CROI_ERR_BAD_HANDLE);  // it moved
  CHECK(counter_value(back) == 24);
  CHECK(croi_handle_close(back) == CROI_OK);
  return typed_calls(ch, buf);
}

int idl_c_echo_client(uint32_t channel) {
  td_wire_msg_t *buf = malloc(sizeof *buf);
  if (!buf) return __LINE__;
  int result = echo_client(channel, buf);
  free(buf);
  croi_handle_close(channel);
  return result;
}
