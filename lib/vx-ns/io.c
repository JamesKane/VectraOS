// vx-ns's asynchronous file calls (09 §5.5; ADR-0004 libvx v0, M6 step
// 6e4d2): vx_io_submit's requests and vx_watch's watches, whose results
// come to a loop as events (lib/vx-rt/loop.c's completion queue).
//
// A request is the same as its synchronous call (F-217): in level 0 a loop
// has up to four I/O threads that make them, with the pipelined client
// keeping each one's request in flight at once (6d4). Submitting to the
// ring directly is the same API later.
//
// A watch is 9Px notify (docs/proto/notify.md) on a new fid for the file
// (its path walked again: an open fid cannot be walked from), on the
// process's own connection to its server: its Tnotify is held until
// something changes, so it is sent with p9_ring_send, beside the
// connection's other calls (6d4d1), its reply waited for on the watch's own
// port, and a stop posted to that port flushes it (p9_ring_cancel).

#pragma once

#include "../../abi/vx/loop.h"
#include "file.c"

static constexpr uint32_t VX_IO_THREADS = 4;
static constexpr uint32_t VX_IO_QUEUE = 256;
static constexpr uint32_t VX_IO_WATCHES = 8;

typedef struct vx_io_watch {
  bool used;
  p9_conn *k;
  uint32_t fid;
  vx_handle port; // its reply's doorbell, and a stop (key 2)
  uint64_t key;
  vx_fd fd;
  vx_worker w;
  struct vx_io_pool *pool;
} vx_io_watch;

typedef struct vx_io_pool {
  vx_lock_t lock;
  vx_rendez work;
  vx_loop *loop; // nullptr once the loop is being freed: completions dropped
  bool stopping;
  vx_io q[VX_IO_QUEUE];
  uint32_t head, count;
  vx_worker workers[VX_IO_THREADS];
  struct vx_io_who {
    struct vx_io_pool *pool;
    uint32_t index;
  } who[VX_IO_THREADS]; // each thread's argument
  bool busy[VX_IO_THREADS];
  uint32_t nworkers, live; // started, and not yet ended
  bool orphan;             // the loop is gone, its stop left threads busy: the last frees the pool
  vx_io_watch watch[VX_IO_WATCHES];
} vx_io_pool;

// Gives a completion to the loop, unless it has gone; under the pool's lock.
static void vx_io_complete(vx_io_pool *p, const vx_event *ev, vx_str text) {
  vx_lock(&p->lock);
  if (p->loop) vx_loop_done(p->loop, ev, text);
  vx_unlock(&p->lock);
}

static int64_t vx_io_do(const vx_io *io) {
  switch (io->op) {
  case VX_IO_READ: return vx_pread(io->fd, io->buf, io->off);
  case VX_IO_WRITE: return vx_pwrite(io->fd, (vx_str){(const char *)io->buf.ptr, io->buf.len}, io->off);
  case VX_IO_SYNC: return vx_sync(io->fd);
  default: return VX_ERR_INVALID;
  }
}

static void vx_io_thread(void *arg) {
  const struct vx_io_who *who = arg;
  vx_io_pool *p = who->pool;
  uint32_t me = who->index;
  vx_lock(&p->lock);
  for (;;) {
    while (!p->count && !p->stopping) vx_rendez_sleep(&p->work, &p->lock);
    if (p->stopping) break;
    vx_io io = p->q[p->head];
    p->head = (p->head + 1) % VX_IO_QUEUE, p->count--;
    p->busy[me] = true;
    vx_unlock(&p->lock);
    int64_t r = vx_io_do(&io);
    vx_event ev = {.kind = VX_EV_IO,
                   .source = (uint64_t)(uint32_t)io.fd,
                   .key = io.key,
                   .io = {.count = r, .fd = io.fd, .op = io.op, .off = io.off}};
    vx_io_complete(p, &ev, (vx_str){});
    vx_lock(&p->lock);
    p->busy[me] = false;
  }
  bool last = --p->live == 0 && p->orphan;
  vx_unlock(&p->lock);
  if (last) vx_heap_free(vx_heap_process(), p); // the loop let go of it while this one was busy
}

// The watch's thread: Tnotify after Tnotify, each change an event, until a
// stop (key 2 on its port) or the connection ends.
static void vx_io_watcher(void *arg) {
  vx_io_watch *w = arg;
  p9_conn *k = w->k;
  bool stop = false;
  while (!stop) {
    p9_msg t = {.type = P9_Tnotify, .fid = w->fid, .mask = 0xff};
    if (p9_ring_send(k, &t, w->port, 1) != VX_OK) break;
    uint16_t tag = t.tag;
    p9_msg r;
    vx_status st;
    while ((st = p9_ring_receive(k, tag, &r)) == VX_ERR_SHOULD_WAIT) {
      if (!p9_ring_arm(k, w->port, 1)) continue; // a reply may be there already
      vx_packet pk;
      if (vx_port_wait(w->port, VX_INFINITE, 0, &pk, 1) == 1 && pk.key == 2) {
        stop = true;
        break;
      }
    }
    vx_ring_end_sleep(&k->ring);
    if (stop) {
      p9_ring_cancel(k, tag);
      break;
    }
    if (st != VX_OK) break; // the connection ended, or the server refused
    // kind[1] name[s] each: name's length in two bytes, then its bytes.
    for (uint32_t at = 0; at + 3 <= r.count;) {
      uint8_t kind = r.data.ptr[at];
      uint32_t len = r.data.ptr[at + 1] | (uint32_t)r.data.ptr[at + 2] << 8;
      if (at + 3 + len > r.count) break;
      vx_event ev = {.kind = VX_EV_CHANGED,
                     .source = (uint64_t)(uint32_t)w->fd,
                     .key = w->key,
                     .changed = {.what = kind}};
      vx_io_complete(w->pool, &ev, (vx_str){(const char *)r.data.ptr + at + 3, len});
      at += 3 + len;
    }
  }
}

static void vx_io_watch_end(vx_io_watch *w) {
  vx_packet stop = {.key = 2};
  vx_port_post(w->port, &stop);
  vx_worker_join(&w->w);
  p9c_clunk(&w->k->c, w->fid); // the watch's end (notify.md)
  vx_handle_close(w->port);
  *w = (vx_io_watch){};
}

// The loop's stop hook: watches ended, idle threads joined. A thread in a
// request (a read held open, say) is left to finish; the pool is freed by
// whichever ends last, and that thread's stack stays mapped (a gap).
static void vx_io_stop(vx_loop *l) {
  vx_io_pool *p = l->io;
  for (uint32_t i = 0; i < VX_IO_WATCHES; i++)
    if (p->watch[i].used) vx_io_watch_end(&p->watch[i]);
  vx_lock(&p->lock);
  p->loop = nullptr;
  p->stopping = true;
  vx_rendez_wake_all(&p->work);
  bool busy[VX_IO_THREADS];
  memcpy(busy, p->busy, sizeof busy);
  uint32_t n = p->nworkers;
  vx_unlock(&p->lock);
  for (uint32_t i = 0; i < n; i++)
    if (!busy[i]) vx_worker_join(&p->workers[i]);
  vx_lock(&p->lock);
  bool last = p->live == 0;
  p->orphan = !last;
  vx_unlock(&p->lock);
  if (last) vx_heap_free(vx_heap_process(), p);
  l->io = nullptr, l->io_stop = nullptr;
}

static vx_io_pool *vx_io_pool_of(vx_loop *l) {
  if (l->io) return l->io;
  if (vx_loop_done_open(l) != VX_OK) return nullptr;
  vx_io_pool *p = vx_heap_alloc(vx_heap_process(), sizeof *p);
  if (!p) return nullptr;
  memset(p, 0, sizeof *p);
  p->loop = l;
  l->io = p, l->io_stop = vx_io_stop;
  return p;
}

VX_API vx_status vx_io_submit(vx_loop *l, const vx_io *ops, size_t n) {
  vx_io_pool *p = vx_io_pool_of(l);
  if (!p) return vx_file_fail("submit", VX_STR("requests"), VX_ERR_NO_MEMORY);
  for (size_t i = 0; i < n; i++)
    if (ops[i].op < VX_IO_READ || ops[i].op > VX_IO_SYNC)
      return vx_file_fail("submit", VX_STR("requests"), VX_ERR_INVALID);
  vx_lock(&p->lock);
  if (n > VX_IO_QUEUE - p->count) { // all or none: the caller waits for completions and tries again
    vx_unlock(&p->lock);
    return vx_file_fail("submit", VX_STR("requests"), VX_ERR_SHOULD_WAIT);
  }
  for (size_t i = 0; i < n; i++) p->q[(p->head + p->count++) % VX_IO_QUEUE] = ops[i];
  // A thread for each request waiting beyond the idle ones, up to four.
  uint32_t idle = 0;
  for (uint32_t i = 0; i < p->nworkers; i++) idle += !p->busy[i];
  while (p->nworkers < VX_IO_THREADS && p->count > idle) {
    uint32_t i = p->nworkers;
    p->who[i] = (struct vx_io_who){p, i};
    if (vx_worker_start(&p->workers[i], vx_io_thread, &p->who[i], 64 << 10) != VX_OK) break;
    p->nworkers++, p->live++, idle++;
  }
  vx_rendez_wake_all(&p->work);
  vx_unlock(&p->lock);
  return VX_OK;
}

// A watch on a file of a server with notify: its own connection, the file
// joined there by token.
static vx_status vx_io_watch_file(vx_io_pool *p, vx_fd fd, uint64_t key) {
  vx_io_watch *w = nullptr;
  for (uint32_t i = 0; i < VX_IO_WATCHES && !w; i++)
    if (!p->watch[i].used) w = &p->watch[i];
  if (!w) return VX_ERR_NO_MEMORY;
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return VX_ERR_BAD_HANDLE;
  char path[VX_NS_MAX_PATH];
  size_t len = s->path_len < sizeof path ? s->path_len : 0;
  if (len) memcpy(path, s->path, len);
  vx_unlock(&s->lock);
  if (!len) return VX_ERR_UNSUPPORTED;
  p9_client *c = nullptr;
  uint32_t clone = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_ns_walk(vx_ns_process(), (vx_str){path, len}, &c, &clone);
  vx_unlock(&vx_ns_proc_lock);
  if (st != VX_OK) return st;
  if (!(c->extensions & P9_EXT_NOTIFY) || c->pipe != &P9_RING_PIPE) { // not a ring: dialled over TCP
    p9c_clunk(c, clone);
    return VX_ERR_UNSUPPORTED;
  }
  p9_conn *k = c->ctx;
  vx_handle port = VX_HANDLE_NONE;
  if (st == VX_OK) st = vx_port_create(0, &port);
  if (st == VX_OK) {
    *w = (vx_io_watch){.used = true, .k = k, .fid = clone, .port = port, .key = key, .fd = fd, .pool = p};
    st = vx_worker_start(&w->w, vx_io_watcher, w, 64 << 10);
  }
  if (st != VX_OK) {
    if (port) vx_handle_close(port);
    if (clone) p9c_clunk(c, clone);
    *w = (vx_io_watch){};
  }
  return st;
}

VX_API vx_status vx_watch(vx_loop *l, vx_fd fd, uint64_t key) {
  vx_status st;
  if (fd == VX_STDIN) {
    st = vx_loop_watch_stdin(l, key);
  } else {
    vx_io_pool *p = vx_io_pool_of(l);
    st = p ? vx_io_watch_file(p, fd, key) : VX_ERR_NO_MEMORY;
  }
  return st == VX_OK ? VX_OK : vx_file_fail("watch", VX_STR("a file"), st);
}
