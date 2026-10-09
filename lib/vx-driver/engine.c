// vx-driver engine: the back end's half of the display engine protocol
// (docs/proto/display.md, ADR-0026; M7 step 7b4), which every display back
// end shares: the post's CONNECT, the one session, its requests checked for
// size, APPLY held for the next vblank, and the vblank, a timer at the
// output's refresh for a back end with no interrupt (simplefb, virtio-gpu).
// A back end gives its hardware's half as vx_engine_ops and calls
// vx_engine_serve, which never returns.
//
// One thread, one port: the listen channel, the session, and the vblank
// timer as the port's deadline; a back end's own sources may be bound on
// the port with keys from VX_ENGINE_KEY_USER up, given to ops.event.

#pragma once

#include "displayproto.h"

static constexpr uint64_t VX_ENGINE_KEY_USER = 16;

typedef struct vx_engine_ops {
  // INFO's reply, but for its header.
  void (*info)(vx_display_info *info);
  // A buffer (checked against its VMO, which vx_buffer_take did) as a
  // scan-out image: its id (from 1), or a status, the buffer then closed by
  // the engine.
  int64_t (*import)(vx_buffer *b);
  vx_status (*release)(uint64_t id);
  // CHECK's verdict: -2 for yes, else the layer that failed (-1: the mode) and why.
  int64_t (*check)(const vx_display_cfg *cfg, vx_status *why);
  // A checked configuration onto the screen, at a vblank: its damage only.
  void (*show)(const vx_display_apply *a);
  vx_status (*power)(bool on);
  // A session has opened, or ended: the back end saves or puts back the
  // firmware's picture, and lets every image go when it ends.
  void (*opened)(void);
  void (*closed)(void);
  void (*event)(const vx_packet *pk); // optional: a packet with a key from VX_ENGINE_KEY_USER up
} vx_engine_ops;

typedef struct vx_engine {
  const vx_engine_ops *ops;
  const char *name; // for messages
  vx_handle port, listen, session;
  vx_display_mode mode; // the one output's, for ADDED
  const uint8_t *edid;  // its EDID, if it has one
  uint32_t edid_len;
  vx_duration refresh_ns;
  vx_display_apply pending;
  bool have_pending, on;
  uint64_t stamp_shown;
} vx_engine;

enum : uint64_t { VX_ENGINE_KEY_LISTEN = 1, VX_ENGINE_KEY_SESSION = 2 };

static void engine_reply(vx_engine *e, const vx_msg_header *req, vx_status st, int64_t a0) {
  vx_display_msg r = {.h = {.txid = req->txid, .ordinal = req->ordinal, .flags = (uint32_t)(int32_t)st},
                      .arg = {a0}};
  vx_channel_write(e->session, &r, sizeof r, nullptr, 0);
}

static void engine_refuse(vx_engine *e, const vx_msg_header *req, vx_status why) {
  vx_msg_header rep = {.txid = req->txid, .ordinal = req->ordinal, .flags = (uint32_t)(int32_t)why};
  vx_channel_write(e->listen, &rep, sizeof rep, nullptr, 0);
}

static void engine_end(vx_engine *e) {
  e->ops->closed();
  vx_handle_close(e->session);
  e->session = VX_HANDLE_NONE, e->have_pending = false, e->on = true;
}

static void engine_added(vx_engine *e) {
  static struct {
    vx_display_added a;
    uint8_t edid[1024];
  } m;
  m.a = (vx_display_added){.h = {.ordinal = VX_DISPLAY_ADDED},
                           .output = 0,
                           .edid_len = e->edid_len <= sizeof m.edid ? e->edid_len : 0,
                           .preferred = e->mode,
                           .current = e->mode};
  if (m.a.edid_len) memcpy(m.edid, e->edid, m.a.edid_len);
  vx_channel_write(e->session, &m, (uint32_t)sizeof m.a + m.a.edid_len, nullptr, 0);
}

static void engine_import(vx_engine *e, const vx_display_import *m, uint32_t len, const vx_handle h[2],
                          uint32_t nh) {
  if (nh != 2) {
    for (uint32_t i = 0; i < nh; i++) vx_handle_close(h[i]);
    engine_reply(e, &m->h, VX_ERR_INVALID, 0);
    return;
  }
  vx_buffer b;
  vx_status st = vx_buffer_take(&b, &m->desc, len - (uint32_t)sizeof m->h, h);
  int64_t id = st == VX_OK ? e->ops->import(&b) : st;
  if (id < 0 && st == VX_OK) vx_buffer_close(&b);
  engine_reply(e, &m->h, id < 0 ? (vx_status)id : VX_OK, id < 0 ? 0 : id);
}

// Every message waiting on the session; false once it has gone, or broke the protocol.
static bool engine_serve_session(vx_engine *e) {
  static union {
    vx_msg_header h;
    vx_display_msg msg;
    vx_display_import import;
    vx_display_check check;
    vx_display_apply apply;
    vx_display_power power;
    uint8_t bytes[1024];
  } m;
  for (;;) {
    vx_handle h[VX_CHANNEL_MAX_HANDLES];
    vx_msg_size size;
    vx_status st = vx_channel_read(e->session, &m, sizeof m, h, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK) return false;
    uint32_t want = 0;
    switch (m.h.ordinal) {
    case VX_DISPLAY_INFO: want = sizeof m.h; break;
    case VX_DISPLAY_IMPORT: want = sizeof m.import; break;
    case VX_DISPLAY_RELEASE: want = sizeof m.msg; break;
    case VX_DISPLAY_CHECK: want = sizeof m.check; break;
    case VX_DISPLAY_APPLY: want = sizeof m.apply; break;
    case VX_DISPLAY_POWER: want = sizeof m.power; break;
    default: break;
    }
    bool ok = want && size.bytes == want;
    if (!ok || m.h.ordinal != VX_DISPLAY_IMPORT)
      for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(h[i]);
    if (!ok) {
      if (m.h.ordinal == VX_DISPLAY_APPLY || size.bytes < sizeof m.h) return false;
      engine_reply(e, &m.h, VX_ERR_INVALID, 0);
      continue;
    }
    vx_status why;
    int64_t bad;
    switch (m.h.ordinal) {
    case VX_DISPLAY_INFO: {
      vx_display_info i = {.version = VX_DISPLAY_VERSION, .outputs = 1, .layers = 1};
      e->ops->info(&i);
      i.h = (vx_msg_header){.txid = m.h.txid, .ordinal = m.h.ordinal};
      vx_channel_write(e->session, &i, sizeof i, nullptr, 0);
      break;
    }
    case VX_DISPLAY_IMPORT: engine_import(e, &m.import, size.bytes, h, size.handles); break;
    case VX_DISPLAY_RELEASE: engine_reply(e, &m.h, e->ops->release((uint64_t)m.msg.arg[0]), 0); break;
    case VX_DISPLAY_CHECK:
      bad = e->ops->check(&m.check.cfg, &why);
      engine_reply(e, &m.h, why, bad == -2 ? 0 : bad);
      break;
    case VX_DISPLAY_APPLY:
      // Stamps rise, and only what CHECK passes is applied: else the session ends.
      if (m.apply.stamp <= (e->have_pending ? e->pending.stamp : e->stamp_shown) ||
          m.apply.ndamage > VX_DISPLAY_DAMAGE || e->ops->check(&m.apply.cfg, &why) != -2)
        return false;
      e->pending = m.apply, e->have_pending = true;
      break;
    case VX_DISPLAY_POWER:
      why = m.power.output != 0 ? VX_ERR_NOT_FOUND : e->ops->power(m.power.on != 0);
      if (why == VX_OK) e->on = m.power.on != 0;
      engine_reply(e, &m.h, why, 0);
      break;
    default: break;
    }
  }
}

static void engine_accept(vx_engine *e) {
  for (;;) {
    vx_msg_header req;
    vx_msg_size size;
    vx_handle junk[VX_CHANNEL_MAX_HANDLES];
    vx_status st = vx_channel_read(e->listen, &req, sizeof req, junk, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_SHOULD_WAIT) return;
    if (st == VX_ERR_PEER_CLOSED) {
      vx_printf("%s: the listen channel is gone\n", e->name);
      vx_exits("the listen channel is gone");
    }
    if (st != VX_OK) continue; // too large: not this protocol's
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk[i]);
    if (size.bytes != sizeof req || req.ordinal != VX_DISPLAY_CONNECT) {
      engine_refuse(e, &req, VX_ERR_INVALID);
      continue;
    }
    if (e->session) {
      engine_refuse(e, &req, VX_ERR_BAD_STATE);
      continue;
    }
    vx_handle ends[2];
    if (vx_channel_create(0, ends) != VX_OK) {
      engine_refuse(e, &req, VX_ERR_NO_MEMORY);
      continue;
    }
    vx_msg_header rep = {.txid = req.txid, .ordinal = req.ordinal};
    if (vx_channel_write(e->listen, &rep, sizeof rep, &ends[1], 1) != VX_OK) {
      vx_handle_close(ends[0]), vx_handle_close(ends[1]);
      continue;
    }
    e->session = ends[0], e->stamp_shown = 0, e->on = true;
    e->ops->opened();
    engine_added(e);
    vx_port_bind(e->port, e->session, VX_TRIGGER_READABLE, VX_ENGINE_KEY_SESSION, 0);
  }
}

// Serves the post's listen end for ever. e->port may have the back end's own
// bindings on it already.
[[noreturn]] [[maybe_unused]] static void vx_engine_serve(vx_engine *e) {
  if (!e->port && vx_port_create(0, &e->port) != VX_OK) vx_exits("no port");
  if (!e->refresh_ns)
    e->refresh_ns = 1'000'000'000'000LL / (e->mode.refresh_mhz ? e->mode.refresh_mhz : 60'000);
  e->on = true;
  vx_port_bind(e->port, e->listen, VX_TRIGGER_READABLE, VX_ENGINE_KEY_LISTEN, 0);
  vx_instant next = vx_now() + e->refresh_ns;
  for (;;) {
    vx_packet pk[8];
    int64_t n = vx_port_wait(e->port, e->session ? next : VX_INFINITE, e->refresh_ns / 16, pk, 8);
    for (int64_t i = 0; i < n; i++) {
      if (pk[i].key == VX_ENGINE_KEY_LISTEN) {
        engine_accept(e);
        vx_port_bind(e->port, e->listen, VX_TRIGGER_READABLE, VX_ENGINE_KEY_LISTEN, 0);
      } else if (pk[i].key == VX_ENGINE_KEY_SESSION && e->session) {
        if (engine_serve_session(e))
          vx_port_bind(e->port, e->session, VX_TRIGGER_READABLE, VX_ENGINE_KEY_SESSION, 0);
        else
          engine_end(e);
      } else if (pk[i].key >= VX_ENGINE_KEY_USER && e->ops->event) {
        e->ops->event(&pk[i]);
      }
    }
    vx_instant now = vx_now();
    if (!e->session) {
      next = now + e->refresh_ns;
      continue;
    }
    if (now < next) continue;
    // A vblank: what is pending goes on screen, and displayd is told.
    if (e->have_pending && e->on) {
      e->ops->show(&e->pending);
      e->stamp_shown = e->pending.stamp, e->have_pending = false;
    }
    while (next <= now) next += e->refresh_ns;
    if (e->on) {
      vx_display_vblank v = {
          .h = {.ordinal = VX_DISPLAY_VBLANK}, .output = 0, .time = (uint64_t)now, .stamp = e->stamp_shown};
      vx_channel_write(e->session, &v, sizeof v, nullptr, 0);
    }
  }
}

// --- What every back end's CHECK and copy share ---

// a ∩ b; its width 0 if they do not meet.
[[maybe_unused]] static vx_display_rect vx_display_intersect(vx_display_rect a, vx_display_rect b) {
  int64_t x0 = a.x > b.x ? a.x : b.x, y0 = a.y > b.y ? a.y : b.y;
  int64_t x1 = (int64_t)a.x + a.width, y1 = (int64_t)a.y + a.height;
  int64_t bx1 = (int64_t)b.x + b.width, by1 = (int64_t)b.y + b.height;
  if (bx1 < x1) x1 = bx1;
  if (by1 < y1) y1 = by1;
  if (x1 <= x0 || y1 <= y0) return (vx_display_rect){};
  return (vx_display_rect){(int32_t)x0, (int32_t)y0, (uint32_t)(x1 - x0), (uint32_t)(y1 - y0)};
}

// Whether r lies inside a w by h area.
[[maybe_unused]] static bool vx_display_inside(vx_display_rect r, uint64_t w, uint64_t h) {
  return r.x >= 0 && r.y >= 0 && (uint64_t)r.x + r.width <= w && (uint64_t)r.y + r.height <= h;
}
