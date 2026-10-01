// vx-ring sessions: opening a ring to a server through its listen channel
// (docs/01 §4.3, 02 §3.2). A server reads requests on a listen channel (a
// post, /srv/NAME); a client sends one with channel_call; the server creates
// a ring with its protocol's parameters, keeps the server end, and answers
// with the client end and the ring's memory. Each session is its own ring, so
// each queue has one producer.
//
// The ring is attached only if its header is exactly what the protocol's
// parameters make (vx_ring_attach): a server cannot hand a client a ring with
// bigger entries than the client's buffers.

#pragma once

#include "../vx-rt/base.c"
#include "ring.c"

// Maps a ring's memory into this task and attaches to it as one side.
static vx_status vx_session_map(vx_handle memory, bool client, const vx_ring_params *params, vx_ring *r) {
  vx_ring_header layout;
  vx_status st = vx_ring_layout(params, &layout);
  uint64_t base = 0;
  if (st == VX_OK) st = vx_as_map(vx_self, memory, 0, layout.size, VX_MAP_WRITE, &base);
  // The mapping stays for the life of the task until as_unmap lands (01 §5).
  if (st == VX_OK) st = vx_ring_attach(r, (void *)base, layout.size, client, params);
  return st;
}

// Opens a session through `connector` (a post's client end, which stays the
// caller's), asking with `ordinal`. On success *end is this side's ring end.
[[maybe_unused]] static vx_status vx_session_dial(vx_handle connector, uint32_t ordinal,
                                                  const vx_ring_params *params, vx_ring *r, vx_handle *end) {
  *end = VX_HANDLE_NONE;
  vx_msg_header req = {.ordinal = ordinal}, rep;
  vx_handle got[2] = {};
  vx_call call = {.wr_bytes = &req,
                  .wr_len = sizeof req,
                  .rd_bytes = &rep,
                  .rd_cap = sizeof rep,
                  .rd_handles = got,
                  .rd_count_cap = 2};
  vx_status st = vx_channel_call(connector, &call, vx_clock_read() + 5'000'000'000);
  if (st == VX_OK && call.actual.handles != 2) st = VX_ERR_ACCESS; // refused
  if (st == VX_OK) st = vx_session_map(got[1], true, params, r);
  if (got[1]) vx_handle_close(got[1]); // the mapping keeps the memory
  if (st != VX_OK) {
    if (got[0]) vx_handle_close(got[0]);
    return st;
  }
  *end = got[0];
  return VX_OK;
}

// Answers one request read from `listen` (req is its header): a new ring with
// these parameters, mapped and attached as the server, its server end in
// *end. On failure the request is refused, with a reply without handles.
[[maybe_unused]] static vx_status vx_session_accept(vx_handle listen, const vx_msg_header *req,
                                                    const vx_ring_params *params, vx_ring *r,
                                                    vx_handle *end) {
  *end = VX_HANDLE_NONE;
  vx_msg_header rep = {.txid = req->txid, .ordinal = req->ordinal};
  vx_ring_handles h = {};
  vx_status st = vx_ring_create(params, &h);
  if (st == VX_OK) st = vx_session_map(h.memory, false, params, r);
  if (st == VX_OK) {
    vx_handle give[2] = {h.client, h.memory};
    st = vx_channel_write(listen, &rep, sizeof rep, give, 2);
    h.client = h.memory = VX_HANDLE_NONE; // moved, whatever happened
  }
  if (st == VX_OK) {
    *end = h.server;
    return VX_OK;
  }
  if (h.client) vx_handle_close(h.client);
  if (h.server) vx_handle_close(h.server);
  if (h.memory) vx_handle_close(h.memory);
  rep.flags = 1; // refused
  vx_channel_write(listen, &rep, sizeof rep, nullptr, 0);
  return st;
}
