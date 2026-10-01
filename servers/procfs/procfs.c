// procfs: /proc, the tasks (docs/02 §5.1), minimal for M2.
//
// svcd gives it a handle to svcd's own task ("tasks"), so it sees svcd and
// every task svcd's tree has made (abi.h, task_info), and nothing else; and
// the listen channel it posts as /srv/proc.
//
//   /proc/N/status   one ndb record: name=svcd state=waiting threads=1 mem=412K
//   /proc/N/ctl      write "kill" to kill the task
//
// A task's state reads "waiting" when every thread it has is blocked. The tree
// is made as it is read: a task that has gone is simply not there.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"

static vx_handle tasks;               // the root of what procfs shows
static uint64_t root_id;              // its task id
static constexpr int64_t KILLED = -9; // the exit status a kill through ctl gives, as Unix's SIGKILL reads

// Node numbers: 1 is /proc; a task's directory, status and ctl are its id
// shifted left two, plus 0, 1 or 2.
enum : uint64_t { ROOT = 1, DIR = 0, STATUS = 1, CTL = 2 };

static uint64_t task_of(uint64_t node) { return node >> 2; }

static bool task_exists(uint64_t id, vx_task_summary *info) {
  return vx_task_info_of(tasks, id, 0, info) == VX_OK && info->state != VX_TASK_EXITED;
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  vx_task_summary info;
  if (dir == ROOT) {
    uint64_t id = 0;
    if (!name.len || name.len > 19 || name.ptr[0] == '0') return VX_ERR_NOT_FOUND;
    for (size_t i = 0; i < name.len; i++) {
      if (name.ptr[i] < '0' || name.ptr[i] > '9') return VX_ERR_NOT_FOUND;
      id = id * 10 + (uint64_t)(name.ptr[i] - '0');
    }
    if (!task_exists(id, &info)) return VX_ERR_NOT_FOUND;
    *child = id << 2 | DIR;
    return VX_OK;
  }
  if ((dir & 3) != DIR || !task_exists(task_of(dir), &info)) return VX_ERR_NOT_FOUND;
  if (name.len == 6 && memcmp(name.ptr, "status", 6) == 0)
    *child = dir | STATUS;
  else if (name.len == 3 && memcmp(name.ptr, "ctl", 3) == 0)
    *child = dir | CTL;
  else
    return VX_ERR_NOT_FOUND;
  return VX_OK;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  *parent = (node & 3) == DIR ? ROOT : (node & ~3ull);
  return VX_OK;
}

static char name_buf[24];

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  if (node == ROOT) {
    *out = (p9_stat){.qid = {P9_QTDIR, 0, ROOT}, .mode = P9_DMDIR | 0555, .name = VX_STR("/")};
  } else {
    // The name of a task's directory is its id, in decimal.
    uint64_t id = task_of(node);
    size_t n = sizeof name_buf;
    do name_buf[--n] = (char)('0' + id % 10);
    while (id /= 10);
    static const struct {
      uint32_t mode;
      vx_str name;
    } FILES[] = {[STATUS] = {0444, VX_STR("status")}, [CTL] = {0222, VX_STR("ctl")}};
    uint64_t kind = node & 3;
    if (kind == DIR)
      *out = (p9_stat){
          .qid = {P9_QTDIR, 0, node}, .mode = P9_DMDIR | 0555, .name = {name_buf + n, sizeof name_buf - n}};
    else
      *out = (p9_stat){.qid = {P9_QTFILE, 0, node}, .mode = FILES[kind].mode, .name = FILES[kind].name};
  }
  out->uid = out->gid = out->muid = VX_STR("proc");
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  bool writes = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR;
  if ((node & 3) == STATUS && writes) return VX_ERR_ACCESS;
  if ((node & 3) == CTL && (mode & 3) != P9_OWRITE) return VX_ERR_ACCESS;
  return mode & (P9_OTRUNC | P9_ORCLOSE) ? VX_ERR_ACCESS : VX_OK;
}

// A task's status record, as it is now.
static size_t status_text(uint64_t id, char *buf, size_t cap) {
  vx_task_summary info;
  if (!task_exists(id, &info)) return 0;
  size_t name_len = 0;
  while (name_len < sizeof info.name && info.name[name_len]) name_len++;
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_ndb_put(&w, "name", (vx_str){info.name, name_len});
  vx_str state = VX_STR("running");
  if (info.state == VX_TASK_NEW)
    state = VX_STR("new");
  else if (info.threads && info.blocked == info.threads)
    state = VX_STR("waiting");
  vx_ndb_put(&w, "state", state);
  vx_ndb_put_u64(&w, "threads", info.threads);
  char mem[24];
  uint64_t kib = info.mapped / 1024, n = sizeof mem;
  mem[--n] = 'K';
  do mem[--n] = (char)('0' + kib % 10);
  while (kib /= 10);
  vx_ndb_put(&w, "mem", (vx_str){mem + n, sizeof mem - n});
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  char text[256];
  size_t len = (node & 3) == STATUS ? status_text(task_of(node), text, sizeof text) : 0;
  uint64_t left = offset < len ? len - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  if ((node & 3) != CTL) return VX_ERR_ACCESS;
  uint32_t len = *count, n = len;
  while (n && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) n--;
  if (n != 4 || memcmp(buf, "kill", 4) != 0) return VX_ERR_INVALID;
  if (task_of(node) == root_id) return VX_ERR_ACCESS; // not the root of the tree: the system needs it
  if (vx_task_kill_id(tasks, task_of(node), KILLED) != VX_OK) return VX_ERR_NOT_FOUND;
  *count = len; // the whole message was the command
  return VX_OK;
}

// The root's entries are the tasks in id order; entry i is the i-th.
static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT) { // a task's directory: status, ctl
    if (index > 1) return VX_ERR_NOT_FOUND;
    *child = dir | (index ? CTL : STATUS);
    return VX_OK;
  }
  uint64_t id = 0;
  vx_task_summary info;
  for (uint32_t seen = 0;;) {
    if (vx_task_info_of(tasks, id, VX_TASK_NEXT, &info) != VX_OK) return VX_ERR_NOT_FOUND;
    id = info.id;
    if (info.state == VX_TASK_EXITED) continue; // gone, but not yet freed: not listed
    if (seen++ == index) break;
  }
  *child = id << 2 | DIR;
  return VX_OK;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .read = fs_read,
           .readdir = fs_readdir,
           .write = fs_write},
    .name = VX_STR("procfs"),
};

int vx_main(void) {
  tasks = vx_spawn_take("tasks");
  server.listen = vx_spawn_take("listen");
  vx_task_summary info;
  if (!tasks || !server.listen || vx_task_info(tasks, &info) != VX_OK) {
    vx_print(VX_STR("procfs: FAILED: no task tree or listen channel\n"));
    return 1;
  }
  root_id = info.id;
  return p9_ring_serve(&server);
}
