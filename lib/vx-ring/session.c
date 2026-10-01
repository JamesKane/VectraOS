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
  if (st == VX_OK && (st = vx_ring_attach(r, (void *)base, layout.size, client, params)) != VX_OK)
    vx_as_unmap(vx_self, base, layout.size); // a ring it would not attach to
  return st;
}

// A session is over: its ring's memory leaves this task's address space.
[[maybe_unused]] static void vx_session_unmap(vx_ring *r) {
  if (r->base) vx_as_unmap(vx_self, (uint64_t)r->base, r->h.size);
  r->base = nullptr;
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

// Dialling without waiting, for a client that cannot stall on a server that
// may not be there (netd, before its driver starts). vx_session_ask writes
// the request on the connector; when the connector is readable,
// vx_session_answer reads the reply. Only one ask is outstanding per
// connector, so nothing else may read it meanwhile.
[[maybe_unused]] static vx_status vx_session_ask(vx_handle connector, uint32_t ordinal) {
  vx_msg_header req = {.txid = 1, .ordinal = ordinal};
  return vx_channel_write(connector, &req, sizeof req, nullptr, 0);
}

// The reply to vx_session_ask: SHOULD_WAIT if it has not come; ACCESS if the
// server refused (it has a client already); otherwise the session, attached.
[[maybe_unused]] static vx_status vx_session_answer(vx_handle connector, const vx_ring_params *params,
                                                    vx_ring *r, vx_handle *end) {
  *end = VX_HANDLE_NONE;
  vx_msg_header rep;
  vx_handle got[2] = {};
  vx_msg_size size;
  vx_status st = vx_channel_read(connector, &rep, sizeof rep, got, 2, &size);
  if (st == VX_ERR_TOO_SMALL) { // not a reply this protocol makes: read it, to be rid of it
    static uint8_t junk[VX_CHANNEL_MAX_BYTES];
    static vx_handle junk_handles[VX_CHANNEL_MAX_HANDLES];
    if (vx_channel_read(connector, junk, sizeof junk, junk_handles, VX_CHANNEL_MAX_HANDLES, &size) == VX_OK)
      for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk_handles[i]);
    return VX_ERR_ACCESS;
  }
  if (st != VX_OK) return st;
  if (size.bytes != sizeof rep || size.handles != 2) {
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(got[i]);
    return VX_ERR_ACCESS;
  }
  st = vx_session_map(got[1], true, params, r);
  vx_handle_close(got[1]); // the mapping keeps the memory
  if (st != VX_OK) {
    vx_handle_close(got[0]);
    return st;
  }
  *end = got[0];
  return VX_OK;
}
