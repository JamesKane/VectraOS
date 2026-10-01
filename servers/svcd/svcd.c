// svcd: the first process (docs/01 §7, §10). It starts the system's services
// from the manifests in boot/svc/*.ndb, in file order, and restarts them when
// they exit.
//
// The kernel gives svcd the boot image. svcd reads the manifests and the
// programs straight from it, because the file server that will serve it,
// bootfs, is one of the services svcd starts.
//
// A manifest is ndb records: a service= record, then the records that belong
// to it, up to the next service=.
//
//   service=NAME program=/boot/bin/PROG [post=SRV] [bootimage] [restart]
//   arg=VALUE                                  an argument, in order
//   mount=OLD srv=SRV [aname=A] [flags=abc]    a mount in its namespace
//   bind=OLD new=NEW [flags=abc]               a bind in its namespace
//
// post=SRV: svcd makes a listen channel, gives the service its server end
// ("listen") and keeps the client end as /srv/SRV, for mounts. It keeps a
// second handle to the server end, so connections made while the service is
// restarting wait for it, and none is lost. bootimage: the service gets the
// boot image, read-only. A service gets nothing that is not named here: no
// ambient authority (01 §2).

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-tar/tar.c"

static constexpr uint32_t MAX_SERVICES = 16;
static constexpr uint32_t MAX_RESTARTS = 5;                   // in RESTART_WINDOW, then svcd gives up
static constexpr vx_duration RESTART_WINDOW = 10'000'000'000; // 10 s
static constexpr uint32_t BOOT_IMAGE_RIGHTS =
    VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;
static constexpr uint32_t CONNECTOR_RIGHTS = VX_RIGHT_READ | VX_RIGHT_WRITE | VX_RIGHT_WAIT |
                                             VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;

typedef struct service {
  vx_str manifest; // the whole file, in the boot image
  size_t at;       // where its service= record starts
  vx_str name;     // in the boot image or in `names`
  bool restart;
  vx_handle task;
  uint32_t restarts;
  vx_instant window_start;
} service;

typedef struct post {
  vx_str name;              // into buf
  vx_handle client, server; // /srv/NAME, and svcd's handle to the service's end
  char buf[32];
} post;

static service services[MAX_SERVICES];
static uint32_t service_count;
static post posts[MAX_SERVICES];
static uint32_t post_count;
static const uint8_t *image;
static uint64_t image_size;
static vx_handle image_vmo, port;
static char names[MAX_SERVICES][32];

static void say(vx_str a, vx_str b, vx_str c) {
  vx_print(VX_STR("svcd: "));
  vx_print(a);
  vx_print(b);
  vx_print(c);
}

[[noreturn]] static void fail(const char *what) {
  say(VX_STR("FAILED: "), vx_cstr(what), VX_STR("\n"));
  for (;;) vx_port_wait(port, VX_INFINITE, 0, &(vx_packet){}, 1); // the root task never exits
}

static bool str_eq(vx_str a, vx_str b) { return a.len == b.len && memcmp(a.ptr, b.ptr, a.len) == 0; }

static post *find_post(vx_str name) {
  for (uint32_t i = 0; i < post_count; i++)
    if (str_eq(posts[i].name, name)) return &posts[i];
  return nullptr;
}

// A reader over one manifest, from `at`; values decode into its own scratch.
static vx_ndb_reader manifest_reader(vx_str text, size_t at) {
  static char scratch[16 * 1024];
  return (vx_ndb_reader){
      .src = text, .pos = at, .line = 1, .scratch = scratch, .scratch_cap = sizeof scratch};
}

// Reads one manifest's service= records. A malformed manifest is reported and skipped.
static void read_manifest(vx_str path, vx_str text) {
  vx_ndb_reader r = manifest_reader(text, 0);
  vx_ndb_record rec;
  vx_ndb_result res;
  size_t before = r.pos;
  while ((res = vx_ndb_next(&r, &rec)) == VX_NDB_RECORD) {
    if (vx_ndb_has(&rec, "service")) {
      vx_str name = vx_ndb_get(&rec, "service"), srv = vx_ndb_get(&rec, "post");
      if (service_count == MAX_SERVICES || !name.len || name.len >= sizeof names[0] ||
          !vx_ndb_get(&rec, "program").len) {
        say(VX_STR("skipping a service in "), path, VX_STR(": no name or program, or too many services\n"));
      } else {
        memcpy(names[service_count], name.ptr, name.len); // the record's values do not outlive the reader
        services[service_count] = (service){.manifest = text,
                                            .at = before,
                                            .name = {names[service_count], name.len},
                                            .restart = vx_ndb_has(&rec, "restart")};
        if (srv.len && !find_post(srv)) {
          post *p = &posts[post_count];
          vx_handle ch[2];
          if (post_count == MAX_SERVICES || srv.len >= sizeof p->buf) fail("too many posts, or a long name");
          if (vx_channel_create(0, ch) != VX_OK) fail("channel_create");
          *p = (post){.client = ch[0], .server = ch[1]};
          memcpy(p->buf, srv.ptr, srv.len);
          p->name = (vx_str){p->buf, srv.len};
          post_count++;
        }
        service_count++;
      }
    }
    before = r.pos;
  }
  if (res == VX_NDB_ERROR) say(path, VX_STR(": "), vx_cstr(r.error));
  if (res == VX_NDB_ERROR) vx_print(VX_STR("\n"));
}

// Builds the spawn message's records and handles for a service, and starts it.
static vx_status start(service *s) {
  static char records[16 * 1024];
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1] = {}; // NONE until given, so a failure closes only real ones
  vx_str handle_names[VX_CHANNEL_MAX_HANDLES - 1];
  static char ns_names[VX_CHANNEL_MAX_HANDLES][8];
  uint32_t count = 0;
  vx_status st = VX_OK;

  vx_ndb_reader r = manifest_reader(s->manifest, s->at);
  vx_ndb_record rec;
  if (vx_ndb_next(&r, &rec) != VX_NDB_RECORD) return VX_ERR_INVALID;
  vx_str program = vx_ndb_get(&rec, "program");
  vx_tar_entry elf;
  if (program.len < 2 || program.ptr[0] != '/' ||
      vx_tar_find(image, image_size, (vx_str){program.ptr + 1, program.len - 1}, &elf) != VX_OK || elf.dir) {
    say(VX_STR("no program "), program, VX_STR(" in the boot image\n"));
    return VX_ERR_NOT_FOUND;
  }
  if (vx_ndb_has(&rec, "bootimage")) {
    st = vx_handle_dup(image_vmo, BOOT_IMAGE_RIGHTS, &handles[count]);
    handle_names[count++] = VX_STR("bootimage");
    vx_ndb_flag(&w, "bootimage");
    vx_ndb_put_u64(&w, "size", image_size);
    vx_ndb_end(&w);
  }
  vx_str srv = vx_ndb_get(&rec, "post");
  if (st == VX_OK && srv.len) {
    post *p = find_post(srv);
    st = p ? vx_handle_dup(p->server, CONNECTOR_RIGHTS, &handles[count]) : VX_ERR_NOT_FOUND;
    handle_names[count++] = VX_STR("listen");
  }

  while (st == VX_OK && vx_ndb_next(&r, &rec) == VX_NDB_RECORD && !vx_ndb_has(&rec, "service")) {
    if (vx_ndb_has(&rec, "arg")) {
      vx_ndb_put(&w, "arg", vx_ndb_get(&rec, "arg"));
    } else if (vx_ndb_has(&rec, "mount")) {
      post *p = find_post(vx_ndb_get(&rec, "srv"));
      if (!p || count == VX_CHANNEL_MAX_HANDLES - 1) {
        say(s->name, VX_STR(": cannot mount /srv/"), vx_ndb_get(&rec, "srv"));
        vx_print(VX_STR("\n"));
        st = VX_ERR_NOT_FOUND;
        break;
      }
      char *hn = ns_names[count];
      hn[0] = 'n', hn[1] = 's', hn[2] = '.', hn[3] = (char)('0' + count / 10),
      hn[4] = (char)('0' + count % 10);
      st = vx_handle_dup(p->client, CONNECTOR_RIGHTS, &handles[count]);
      handle_names[count++] = (vx_str){hn, 5};
      char src[40] = "/srv/";
      size_t n = p->name.len < sizeof src - 5 ? p->name.len : sizeof src - 5;
      memcpy(src + 5, p->name.ptr, n);
      vx_ndb_put(&w, "mount", vx_ndb_get(&rec, "mount"));
      vx_ndb_put(&w, "handle", (vx_str){hn, 5});
      if (vx_ndb_has(&rec, "aname")) vx_ndb_put(&w, "aname", vx_ndb_get(&rec, "aname"));
      if (vx_ndb_has(&rec, "flags")) vx_ndb_put(&w, "flags", vx_ndb_get(&rec, "flags"));
      vx_ndb_put(&w, "src", (vx_str){src, 5 + n});
    } else if (vx_ndb_has(&rec, "bind")) {
      vx_ndb_put(&w, "bind", vx_ndb_get(&rec, "bind"));
      vx_ndb_put(&w, "new", vx_ndb_get(&rec, "new"));
      if (vx_ndb_has(&rec, "flags")) vx_ndb_put(&w, "flags", vx_ndb_get(&rec, "flags"));
    } else {
      continue;
    }
    vx_ndb_end(&w);
  }
  if (st == VX_OK && w.failed) st = VX_ERR_RANGE;
  if (st != VX_OK) {
    for (uint32_t i = 0; i < count; i++)
      if (handles[i]) vx_handle_close(handles[i]);
    return st;
  }

  vx_spawn_args a = {.name = s->name,
                     .image = elf.data,
                     .image_size = elf.size,
                     .handles = handles,
                     .handle_names = handle_names,
                     .handle_count = count,
                     .records = {records, w.len}};
  st = vx_spawn_elf(&a, &s->task);
  if (st == VX_OK) st = vx_port_bind(port, s->task, VX_TRIGGER_EXIT, (uint64_t)(s - services), 0);
  if (st != VX_OK) return st;
  vx_task_summary info;
  vx_task_info(s->task, &info);
  say(VX_STR("started "), s->name, VX_STR(" (task "));
  vx_print_u64(info.id);
  vx_print(VX_STR(")\n"));
  return VX_OK;
}

static void exited(service *s, int64_t status) {
  vx_handle_close(s->task);
  s->task = VX_HANDLE_NONE;
  say(s->name, VX_STR(" exited with status "), status < 0 ? VX_STR("-") : VX_STR(""));
  vx_print_u64(status < 0 ? (uint64_t)-status : (uint64_t)status);
  vx_print(VX_STR("\n"));
  if (!s->restart) return;
  vx_instant now = vx_clock_read();
  if (now - s->window_start > RESTART_WINDOW) s->window_start = now, s->restarts = 0;
  if (++s->restarts > MAX_RESTARTS) {
    say(s->name, VX_STR(" keeps exiting; it is not restarted again"), VX_STR("\n"));
    return;
  }
  if (start(s) != VX_OK) say(VX_STR("cannot restart "), s->name, VX_STR("\n"));
}

int vx_main(void) {
  vx_task_summary info;
  vx_task_info(vx_self, &info);
  vx_print(VX_STR("svcd: hello from user space (task "));
  vx_print_u64(info.id);
  vx_print(VX_STR(")\n"));
  if (vx_port_create(0, &port) != VX_OK) fail("port_create");

  vx_ndb_record rec;
  image_vmo = vx_spawn_take("bootimage");
  uint64_t base = 0;
  if (!image_vmo || !vx_spawn_record("bootimage", &rec) || !vx_ndb_get_u64(&rec, "size", &image_size))
    fail("no boot image");
  if (vx_as_map(vx_self, image_vmo, 0, (image_size + 4095) & ~4095ull, 0, &base) != VX_OK)
    fail("cannot map the boot image");
  image = (const uint8_t *)base;

  vx_tar t = vx_tar_open(image, image_size);
  vx_tar_entry e;
  vx_status st;
  while ((st = vx_tar_next(&t, &e)) == VX_OK) {
    static const char dir[] = "boot/svc/";
    if (e.dir || e.path.len < sizeof dir + 4 || memcmp(e.path.ptr, dir, sizeof dir - 1) != 0 ||
        memcmp(e.path.ptr + e.path.len - 4, ".ndb", 4) != 0)
      continue;
    read_manifest(e.path, (vx_str){(const char *)e.data, e.size});
  }
  if (st == VX_ERR_INVALID) fail("the boot image is malformed");

  for (uint32_t i = 0; i < service_count; i++)
    if (start(&services[i]) != VX_OK) say(VX_STR("cannot start "), services[i].name, VX_STR("\n"));

  for (;;) {
    vx_packet pk[8];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 8);
    for (int64_t i = 0; i < n; i++)
      if (pk[i].trigger == VX_TRIGGER_EXIT && pk[i].key < service_count)
        exited(&services[pk[i].key], (int64_t)pk[i].value); // the exit status, signed
  }
}
