// drv-virtio-gpu: virtio-gpu's 2D commands (virtio 1.2 §5.7; M7 step 7b4) as
// a display engine back end (docs/proto/display.md, ADR-0026), on /srv/display0.
// Venus, its Vulkan, is M8's.
//
// The screen is one host resource, the size of the output's mode, and it
// is shown on scanout 0. An imported image is guest memory, its VMO given to
// the device through the DMA domain, and is attached as that resource's
// backing when it is applied; a vblank then transfers the damage from it
// into the resource and flushes the damage to the screen. So virtio-gpu, as
// simplefb, copies only what the APPLY says changed: the resource holds the
// screen as it is, whatever image last fed it. A colour layer is an image of
// the driver's own, filled with it.
//
// The mode is the device's (GET_DISPLAY_INFO), its EDID (GET_EDID) is given
// to displayd unparsed, and the vblank is a timer at 60 Hz: virtio-gpu has no
// vblank and says no refresh. Nothing the firmware showed survives its exit
// (QEMU's virtio-gpu goes blank), so there is no picture to adopt or put
// back: the output is reported in the device's mode, and a session that ends
// leaves the last picture showing.
//
// Commands go on the control queue a batch at a time and are waited for;
// what the device writes back is read as untrusted, its lengths bounded.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-driver/virtio.c"
#include "../../lib/vx-driver/engine.c"

static constexpr uint64_t VIRTIO_GPU_F_EDID = 1ull << 1;
static constexpr uint16_t QSIZE = 128; // descriptors on the control queue
static constexpr uint32_t SLOTS = 32;  // commands in a batch, a page each: request, then response from 1 KiB
static constexpr uint32_t MAX_IMAGES = 8;
// An image's backing list: up to 16384 runs (64 MiB of scattered pages), given
// to the device in pieces of dma_map's most, 512 pages.
static constexpr uint32_t MAX_ENTRY_PAGES = 64;
static constexpr uint32_t DMA_PAGES = 512;
static constexpr uint32_t MAX_MAPPINGS = 32;
static constexpr uint32_t SCREEN = 1;          // the screen's resource
static constexpr uint32_t FORMAT_B8G8R8X8 = 2; // XRGB8888's bytes (VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM)
static constexpr uint64_t KEY_IRQ = 1;

enum : uint32_t {
  CMD_GET_DISPLAY_INFO = 0x100,
  CMD_RESOURCE_CREATE_2D = 0x101,
  CMD_SET_SCANOUT = 0x103,
  CMD_RESOURCE_FLUSH = 0x104,
  CMD_TRANSFER_TO_HOST_2D = 0x105,
  CMD_RESOURCE_ATTACH_BACKING = 0x106,
  CMD_RESOURCE_DETACH_BACKING = 0x107,
  CMD_GET_EDID = 0x10a,
  RESP_OK_NODATA = 0x1100,
  RESP_OK_DISPLAY_INFO = 0x1101,
  RESP_OK_EDID = 0x1104,
};

typedef struct gpu_hdr {
  uint32_t type, flags;
  uint64_t fence_id;
  uint32_t ctx_id;
  uint8_t ring_idx, padding[3];
} gpu_hdr;
static_assert(sizeof(gpu_hdr) == 24);

typedef struct gpu_rect {
  uint32_t x, y, width, height;
} gpu_rect;

typedef struct gpu_entry { // a run of backing pages
  uint64_t addr;
  uint32_t length, padding;
} gpu_entry;

typedef struct gpu_display_info {
  gpu_hdr h;
  struct {
    gpu_rect r;
    uint32_t enabled, flags;
  } pmodes[16];
} gpu_display_info;

typedef struct gpu_edid {
  gpu_hdr h;
  uint32_t size, padding;
  uint8_t edid[1024];
} gpu_edid;

static vx_virtio dev;
static vx_virtq ctrl;
static vx_handle irq, cmd_port;
static uint8_t *slots;          // SLOTS pages: the batch's requests and responses
static uint64_t slot_pa[SLOTS]; // their device addresses
static uint32_t width, height;  // the mode
static uint32_t res_width;      // the screen's resource, in pixels a row: a vx_buffer_layout row's
static vx_engine engine;
static gpu_edid edid;

[[noreturn]] static void fail(const char *what) {
  vx_printf("drv-virtio-gpu: FAILED: %s\n", what);
  vx_exits(what);
}

// --- The control queue ---

// A batch: commands written into slots, each a chain of descriptors.
static struct {
  uint32_t n;     // commands
  uint16_t descs; // descriptors used
  uint32_t resp_len[SLOTS];
} batch;

// The next command's request, in its slot, of len bytes (at most 1 KiB).
static void *command(uint32_t type, uint32_t len) {
  if (batch.n == SLOTS) return nullptr;
  uint8_t *req = slots + (size_t)batch.n * 4096;
  memset(req, 0, len);
  ((gpu_hdr *)req)->type = type;
  return req;
}

// Queues the command in the batch's next slot: its request (len bytes), any
// more device-read buffers (extra, n of them), and a response of resp bytes.
static bool queue(uint32_t len, const uint64_t *extra_addr, const uint32_t *extra_len, uint32_t extra,
                  uint32_t resp) {
  uint16_t need = (uint16_t)(2 + extra);
  if (batch.n == SLOTS || batch.descs + need > ctrl.size) return false;
  uint32_t s = batch.n++;
  uint16_t d = batch.descs, head = d;
  batch.descs += need;
  ctrl.desc[d] =
      (vx_virtio_desc){.addr = slot_pa[s], .len = len, .flags = VIRTQ_DESC_F_NEXT, .next = (uint16_t)(d + 1)};
  for (uint32_t i = 0; i < extra; i++, d++)
    ctrl.desc[d + 1] = (vx_virtio_desc){
        .addr = extra_addr[i], .len = extra_len[i], .flags = VIRTQ_DESC_F_NEXT, .next = (uint16_t)(d + 2)};
  ctrl.desc[d + 1] = (vx_virtio_desc){.addr = slot_pa[s] + 1024, .len = resp, .flags = VIRTQ_DESC_F_WRITE};
  batch.resp_len[s] = resp;
  memset(slots + (size_t)s * 4096 + 1024, 0, resp);
  ctrl.avail[2 + ctrl.avail_idx % ctrl.size] = head;
  __atomic_thread_fence(__ATOMIC_RELEASE);
  ctrl.avail[1] = ++ctrl.avail_idx;
  return true;
}

static const void *response(uint32_t s) { return slots + (size_t)s * 4096 + 1024; }

// Sends the batch and waits for all of it: false if the device did not
// finish within a second or refused a command (its response type logged).
static bool run(void) {
  uint32_t n = batch.n, done = 0;
  batch.n = 0, batch.descs = 0;
  if (!n) return true;
  vx_virtq_kick(&ctrl);
  vx_instant deadline = vx_now() + 1'000'000'000;
  while (done < n) {
    uint16_t d;
    uint32_t len;
    while (vx_virtq_used(&ctrl, &d, &len)) done++;
    if (done >= n) break;
    vx_packet pk;
    vx_port_bind(cmd_port, irq, VX_TRIGGER_IRQ, KEY_IRQ, 0);
    if (vx_virtq_used(&ctrl, &d, &len)) {
      done++;
      continue;
    }
    if (vx_port_wait(cmd_port, deadline, 0, &pk, 1) != 1) {
      vx_print(VX_STR("drv-virtio-gpu: the device did not answer\n"));
      return false;
    }
  }
  bool ok = true;
  for (uint32_t s = 0; s < n; s++) {
    uint32_t type = ((const gpu_hdr *)response(s))->type;
    if (type < RESP_OK_NODATA || type > RESP_OK_EDID) {
      vx_printf("drv-virtio-gpu: command %#x refused: %#x\n",
                ((const gpu_hdr *)(slots + (size_t)s * 4096))->type, type);
      ok = false;
    }
  }
  return ok;
}

static void simple(uint32_t type, const void *body, uint32_t len) {
  uint8_t *req = command(type, sizeof(gpu_hdr) + len);
  if (!req) return;
  memcpy(req + sizeof(gpu_hdr), body, len);
  queue((uint32_t)sizeof(gpu_hdr) + len, nullptr, nullptr, 0, sizeof(gpu_hdr));
}

// --- Images ---

typedef struct image {
  bool used;
  vx_buffer buf;
  uint8_t *at;                     // mapped here: only the colour image, which the driver fills
  vx_handle mapping[MAX_MAPPINGS]; // the buffer's pages, given to the device 2 MiB at a time
  gpu_entry *entries;              // its backing as runs of pages, for ATTACH_BACKING
  uint32_t nentries;
  vx_handle entries_mapping;
  uint64_t entries_pa[MAX_ENTRY_PAGES];
  uint32_t entries_pages;
} image;
static image images[MAX_IMAGES], colour;
static image *attached; // the screen's backing now
static uint32_t colour_now = 0xffff'ffff;
static bool scanning;

static image *image_of(uint64_t id) {
  return id && id <= MAX_IMAGES && images[id - 1].used ? &images[id - 1] : nullptr;
}

static void image_free(image *im) {
  if (attached == im) {
    uint32_t body[2] = {SCREEN, 0};
    simple(CMD_RESOURCE_DETACH_BACKING, body, sizeof body);
    run();
    attached = nullptr;
  }
  if (im->entries_mapping) vx_handle_close(im->entries_mapping);
  for (uint32_t i = 0; i < MAX_MAPPINGS; i++)
    if (im->mapping[i]) vx_handle_close(im->mapping[i]);
  if (im->entries) vx_as_unmap(vx_self, (uint64_t)im->entries, (uint64_t)im->entries_pages * 4096);
  if (im->at) vx_buffer_unmap(&im->buf, im->at);
  vx_buffer_close(&im->buf);
  *im = (image){};
}

// The buffer's pages to the device, and its backing list: runs of
// consecutive device addresses. The image owns b from here.
static vx_status image_make(image *im, const vx_buffer *b) {
  static uint64_t pa[(size_t)MAX_MAPPINGS * DMA_PAGES];
  *im = (image){.used = true, .buf = *b};
  uint64_t bytes = (b->desc.size + 4095) & ~4095ull, pages = bytes / 4096;
  vx_status st = pages > (uint64_t)MAX_MAPPINGS * DMA_PAGES ? VX_ERR_NO_MEMORY : VX_OK;
  for (uint64_t p = 0, i = 0; st == VX_OK && p < pages; p += DMA_PAGES, i++) {
    uint64_t n = pages - p < DMA_PAGES ? pages - p : DMA_PAGES;
    st = vx_dma_map(dev.dma, b->memory, p * 4096, n * 4096, VX_DMA_READ, pa + p, &im->mapping[i]);
  }
  if (st != VX_OK) return st;
  uint32_t n = 0;
  for (uint64_t i = 0; i < pages; i++) {
    if (n && pa[i] == pa[i - 1] + 4096) continue;
    n++;
  }
  im->entries_pages = (uint32_t)((n * sizeof(gpu_entry) + 4095) / 4096);
  if (im->entries_pages > MAX_ENTRY_PAGES) return VX_ERR_NO_MEMORY;
  vx_handle vmo = VX_HANDLE_NONE;
  uint64_t at = 0, size = (uint64_t)im->entries_pages * 4096;
  st = vx_vmo_create(size, 0, &vmo);
  if (st == VX_OK) st = vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at);
  im->entries = (gpu_entry *)at;
  if (st == VX_OK) {
    uint32_t e = 0;
    for (uint64_t i = 0; i < pages; i++) {
      if (e && pa[i] == im->entries[e - 1].addr + im->entries[e - 1].length) {
        im->entries[e - 1].length += 4096;
        continue;
      }
      im->entries[e++] = (gpu_entry){.addr = pa[i], .length = 4096};
    }
    im->nentries = e;
    st = vx_dma_map(dev.dma, vmo, 0, size, VX_DMA_READ, im->entries_pa, &im->entries_mapping);
  }
  if (vmo) vx_handle_close(vmo);
  return st;
}

// The screen's backing becomes im's.
static void attach(image *im) {
  if (attached == im) return;
  if (attached) {
    uint32_t body[2] = {SCREEN, 0};
    simple(CMD_RESOURCE_DETACH_BACKING, body, sizeof body);
  }
  uint32_t *req = command(CMD_RESOURCE_ATTACH_BACKING, 32);
  if (!req) return;
  req[6] = SCREEN, req[7] = im->nentries;
  uint64_t addr[MAX_ENTRY_PAGES];
  uint32_t len[MAX_ENTRY_PAGES];
  uint32_t left = im->nentries * (uint32_t)sizeof(gpu_entry);
  for (uint32_t i = 0; i < im->entries_pages; i++) {
    addr[i] = im->entries_pa[i], len[i] = left < 4096 ? left : 4096;
    left -= len[i];
  }
  if (queue(32, addr, len, im->entries_pages, sizeof(gpu_hdr))) attached = im;
}

// --- The engine's operations ---

static void gpu_info(vx_display_info *i) {
  i->nformats = 2;
  i->formats[0] = VX_FORMAT_XRGB8888, i->formats[1] = VX_FORMAT_ARGB8888;
  i->align = 4096;
}

static int64_t gpu_import(vx_buffer *b) {
  if (b->desc.format != VX_FORMAT_XRGB8888 && b->desc.format != VX_FORMAT_ARGB8888) return VX_ERR_INVALID;
  uint32_t i = 0;
  while (i < MAX_IMAGES && images[i].used) i++;
  if (i == MAX_IMAGES) return VX_ERR_NO_MEMORY;
  vx_status st = image_make(&images[i], b);
  if (st != VX_OK) {
    *b = (vx_buffer){}; // image_free closes it
    image_free(&images[i]);
    return st;
  }
  return i + 1;
}

static vx_status gpu_release(uint64_t id) {
  image *im = image_of(id);
  if (!im) return VX_ERR_NOT_FOUND;
  image_free(im);
  return VX_OK;
}

// The device's mode, one layer covering the screen: an imported image whose
// rows are the screen resource's (vx_buffer_layout's for the mode), the
// source inside it and unscaled, or a colour; opaque and upright.
static int64_t gpu_check(const vx_display_cfg *c, vx_status *why) {
  *why = VX_ERR_UNSUPPORTED;
  if (c->output != 0 || c->mode.width != width || c->mode.height != height ||
      (c->mode.refresh_mhz && c->mode.refresh_mhz != 60'000))
    return -1;
  if (c->nlayers != 1) return c->nlayers ? 1 : -1;
  const vx_display_layer *l = &c->layer[0];
  *why = VX_ERR_INVALID;
  if (l->alpha != 255 || l->rotation || l->dst.x || l->dst.y || l->dst.width != width ||
      l->dst.height != height)
    return 0;
  if (l->kind == VX_DISPLAY_LAYER_COLOR) {
    *why = VX_OK;
    return -2;
  }
  image *im = l->kind == VX_DISPLAY_LAYER_IMAGE ? image_of(l->image) : nullptr;
  *why = VX_ERR_NOT_FOUND;
  if (!im) return 0;
  *why = VX_ERR_INVALID;
  if (im->buf.desc.plane[0].stride != res_width * 4 || l->src.width != width || l->src.height != height ||
      !vx_display_inside(l->src, im->buf.desc.width, im->buf.desc.height))
    return 0;
  *why = VX_OK;
  return -2;
}

static void transfer(const image *im, const vx_display_layer *l, vx_display_rect r) {
  const vx_buffer_desc *d = &im->buf.desc;
  uint64_t offset = d->plane[0].offset + ((uint64_t)l->src.y + (uint64_t)r.y) * d->plane[0].stride +
                    ((uint64_t)l->src.x + (uint64_t)r.x) * 4;
  struct {
    gpu_rect r;
    uint64_t offset;
    uint32_t resource, padding;
  } t = {{(uint32_t)r.x, (uint32_t)r.y, r.width, r.height}, offset, SCREEN, 0};
  simple(CMD_TRANSFER_TO_HOST_2D, &t, sizeof t);
}

static void flush(vx_display_rect r) {
  struct {
    gpu_rect r;
    uint32_t resource, padding;
  } f = {{(uint32_t)r.x, (uint32_t)r.y, r.width, r.height}, SCREEN, 0};
  simple(CMD_RESOURCE_FLUSH, &f, sizeof f);
}

static void scanout(bool on) {
  struct {
    gpu_rect r;
    uint32_t scanout, resource;
  } s = {{0, 0, on ? width : 0, on ? height : 0}, 0, on ? SCREEN : 0};
  simple(CMD_SET_SCANOUT, &s, sizeof s);
  scanning = on;
}

// The damage from the layer's image into the screen, then to the display.
static void gpu_show(const vx_display_apply *a) {
  const vx_display_layer *l = &a->cfg.layer[0];
  image *im = l->kind == VX_DISPLAY_LAYER_COLOR ? &colour : image_of(l->image);
  if (!im) return;
  vx_display_rect screen = {0, 0, width, height};
  bool all = !a->ndamage;
  if (im == &colour && l->color != colour_now) { // a new colour: all of it
    for (uint32_t y = 0; y < height; y++) {
      uint32_t *row = (uint32_t *)(colour.at + (size_t)y * res_width * 4);
      for (uint32_t x = 0; x < width; x++) row[x] = l->color;
    }
    colour_now = l->color, all = true;
  }
  attach(im);
  uint32_t n = all ? 1 : a->ndamage;
  for (uint32_t i = 0; i < n; i++) {
    vx_display_rect r = all ? screen : vx_display_intersect(a->damage[i], screen);
    if (r.width) transfer(im, l, r);
  }
  if (!scanning) scanout(true);
  for (uint32_t i = 0; i < n; i++) {
    vx_display_rect r = all ? screen : vx_display_intersect(a->damage[i], screen);
    if (r.width) flush(r);
  }
  run();
}

static vx_status gpu_power(bool on) {
  scanout(on);
  if (on) flush((vx_display_rect){0, 0, width, height});
  return run() ? VX_OK : VX_ERR_IO;
}

static void gpu_opened(void) {}

static void gpu_closed(void) {
  for (uint32_t i = 0; i < MAX_IMAGES; i++)
    if (images[i].used) image_free(&images[i]);
}

static const vx_engine_ops OPS = {.info = gpu_info,
                                  .import = gpu_import,
                                  .release = gpu_release,
                                  .check = gpu_check,
                                  .show = gpu_show,
                                  .power = gpu_power,
                                  .opened = gpu_opened,
                                  .closed = gpu_closed};

// --- Starting ---

// Maps the handle the spawn message calls `name` (`size` bytes), or returns nullptr.
static volatile uint8_t *map_handle(const char *name, uint64_t size) {
  vx_handle h = vx_spawn_take(name);
  uint64_t at = 0;
  if (!h || vx_as_map(vx_self, h, 0, size, VX_MAP_WRITE, &at) != VX_OK) return nullptr;
  vx_handle_close(h);
  return (volatile uint8_t *)at;
}

static void setup_device(uint64_t *features) {
  dev.fn.cfg = map_handle("config", 4096);
  dev.dma = vx_spawn_take("dma");
  if (!dev.fn.cfg || !dev.dma) fail("no configuration space or DMA domain");
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  vx_msi msi = {};
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    uint64_t n, v;
    if (vx_ndb_get_u64(&rec, "bar", &n) && n < 6 && vx_ndb_get_u64(&rec, "size", &v)) {
      char name[5] = {'b', 'a', 'r', (char)('0' + n), 0};
      dev.bar[n] = map_handle(name, v);
      dev.bar_size[n] = dev.bar[n] ? v : 0;
    } else if (vx_ndb_get_u64(&rec, "msi", &n) && n == 0 && vx_ndb_get_u64(&rec, "address", &v)) {
      uint64_t data = 0;
      vx_ndb_get_u64(&rec, "data", &data);
      msi = (vx_msi){.address = v, .data = (uint32_t)data};
    }
  }
  irq = vx_spawn_take("msi0");
  if (!irq || !msi.address) fail("no MSI");
  if (vx_virtio_find(&dev) != VX_OK || dev.msix_count < 1) fail("not a modern virtio device with MSI-X");
  if (vx_virtio_start(&dev, VIRTIO_GPU_F_EDID, features) != VX_OK) fail("feature negotiation");
  vx_virtio_msix(&dev, 0, msi);
  if (vx_virtq_init(&dev, &ctrl, 0, QSIZE, 0) != VX_OK) fail("the control queue");
  vx_handle vmo, mapping; // kept as long as the driver lives
  uint64_t at = 0;
  if (vx_vmo_create((uint64_t)SLOTS * 4096, 0, &vmo) != VX_OK ||
      vx_as_map(vx_self, vmo, 0, (uint64_t)SLOTS * 4096, VX_MAP_WRITE, &at) != VX_OK ||
      vx_dma_map(dev.dma, vmo, 0, (uint64_t)SLOTS * 4096, VX_DMA_READ | VX_DMA_WRITE, slot_pa, &mapping) !=
          VX_OK)
    fail("no memory for commands");
  vx_handle_close(vmo);
  slots = (uint8_t *)at;
  if (vx_port_create(0, &cmd_port) != VX_OK) fail("no port");
  vx_virtio_ready(&dev);
}

const char *vx_main(void) {
  uint64_t features = 0;
  setup_device(&features);
  // The mode: scanout 0's.
  command(CMD_GET_DISPLAY_INFO, sizeof(gpu_hdr));
  queue(sizeof(gpu_hdr), nullptr, nullptr, 0, sizeof(gpu_display_info));
  if (!run()) fail("GET_DISPLAY_INFO");
  const gpu_display_info *di = response(0);
  width = di->pmodes[0].r.width, height = di->pmodes[0].r.height;
  if (di->h.type != RESP_OK_DISPLAY_INFO || !di->pmodes[0].enabled || !width || !height || width > 1u << 14 ||
      height > 1u << 14)
    fail("no display on scanout 0");
  if (features & VIRTIO_GPU_F_EDID) {
    uint32_t *req = command(CMD_GET_EDID, 32);
    req[6] = 0; // scanout 0
    queue(32, nullptr, nullptr, 0, sizeof(gpu_edid));
    if (run()) {
      memcpy(&edid, response(0), sizeof edid);
      if (edid.h.type != RESP_OK_EDID || edid.size > sizeof edid.edid) edid.size = 0;
    }
  }
  // The screen's resource, its rows vx_buffer_layout's; and the colour image.
  vx_buffer_desc layout = vx_buffer_layout(width, height, VX_FORMAT_XRGB8888);
  res_width = layout.plane[0].stride / 4;
  struct {
    uint32_t resource, format, width, height;
  } create = {SCREEN, FORMAT_B8G8R8X8, res_width, height};
  simple(CMD_RESOURCE_CREATE_2D, &create, sizeof create);
  if (!run()) fail("RESOURCE_CREATE_2D");
  vx_buffer cb;
  if (vx_buffer_alloc(&cb, width, height, VX_FORMAT_XRGB8888) != VX_OK || image_make(&colour, &cb) != VX_OK ||
      vx_buffer_map(&colour.buf, true, &colour.at) != VX_OK)
    fail("no memory for the colour image");

  engine = (vx_engine){.ops = &OPS, .name = "drv-virtio-gpu"};
  engine.listen = vx_spawn_take("listen");
  if (!engine.listen) fail("no listen channel");
  engine.mode = (vx_display_mode){width, height, 60'000, 0};
  engine.edid = edid.edid, engine.edid_len = edid.size;
  vx_printf("drv-virtio-gpu: %ux%u at 60 Hz, EDID %u bytes, serving /srv/display0\n", width, height,
            edid.size);
  vx_engine_serve(&engine);
}
