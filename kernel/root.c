// root.c: starts the root task from the boot module of that name (01 §10):
// svcd, or whatever `vx.root=NAME` on the kernel command line names (ktest, for
// the kernel's own tests). It gets the debug-write capability, and starts like
// every task, with a bootstrap channel holding its spawn message (abi.h): a
// handle to itself, the boot image (the bootfs.tar module, copied into a VMO),
// the store image when there is one (the store.tar module, likewise: an
// install medium's objects, docs/06 §8), the ACPI tables (acpi.c), the root
// Resource (device.c) and the kernel command line.

LIMINE_REQUEST struct limine_module_request module_request = {.id = LIMINE_MODULE_REQUEST_ID};

static const struct limine_file *find_module(vx_str want) {
  struct limine_module_response *r = module_request.response;
  const char *name = want.ptr;
  size_t n = want.len;
  for (uint64_t i = 0; r && i < r->module_count; i++) {
    const char *path = r->modules[i]->path;
    size_t len = 0;
    while (path[len]) len++;
    if (len > n && path[len - n - 1] == '/' && memcmp(path + len - n, name, n) == 0) return r->modules[i];
  }
  return nullptr;
}

// The root task's image, found while Limine's module records are still there
// (they are in memory reclaim_boot_memory frees; the image itself is not).
static struct {
  const uint8_t *image;
  uint64_t size;
  char name[24];
  size_t name_len;
  const uint8_t *bootfs; // nullptr if the image has no bootfs.tar
  uint64_t bootfs_size;
  const uint8_t *store; // nullptr if it has no store.tar
  uint64_t store_size;
} root_module;

static void find_root_module(void) {
  vx_str name = cmdline_value(VX_STR("vx.root"));
  if (!name.len || name.len > 23) name = VX_STR("svcd");
  const struct limine_file *module = find_module(name);
  if (!module) panic(VX_STR("no module for the root task"));
  root_module.image = module->address;
  root_module.size = module->size;
  memcpy(root_module.name, name.ptr, name.len);
  root_module.name_len = name.len;
  const struct limine_file *bootfs = find_module(VX_STR("bootfs.tar"));
  if (bootfs) root_module.bootfs = bootfs->address, root_module.bootfs_size = bootfs->size;
  const struct limine_file *store = find_module(VX_STR("store.tar"));
  if (store) root_module.store = store->address, root_module.store_size = store->size;
}

static constexpr uint32_t ROOT_RESOURCE_RIGHTS = VX_RIGHT_MANAGE | VX_RIGHT_PAGER | VX_RIGHT_TRACE |
                                                 VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;
static constexpr uint32_t READ_ONLY_RIGHTS = // the boot image and the ACPI tables
    VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;

// Writes the root task's spawn message into a new channel and returns the end
// it reads from: a handle to itself, the boot image, the ACPI tables, the root
// Resource, and the command line. The message holds the references.
static channel *root_spawn_message(task *t) {
  static char text[1024];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_ndb_put(&w, "spawn", (vx_str){root_module.name, root_module.name_len});
  vx_ndb_end(&w);
  moved_handle given[5];
  uint32_t count = 0;
  object_ref(&t->obj);
  given[count] = (moved_handle){&t->obj, ALL_RIGHTS};
  vx_ndb_put(&w, "handle", VX_STR("self"));
  vx_ndb_put_u64(&w, "index", count++);
  vx_ndb_end(&w);
  if (root_module.bootfs) {
    vmo *image;
    if (vmo_create(root_module.bootfs_size, &image) != VX_OK) panic(VX_STR("no memory for the boot image"));
    vmo_write(image, 0, root_module.bootfs, root_module.bootfs_size);
    given[count] = (moved_handle){&image->obj, READ_ONLY_RIGHTS};
    vx_ndb_put(&w, "handle", VX_STR("bootimage"));
    vx_ndb_put_u64(&w, "index", count++);
    vx_ndb_end(&w);
    vx_ndb_flag(&w, "bootimage");
    vx_ndb_put_u64(&w, "size", root_module.bootfs_size);
    vx_ndb_end(&w);
  }
  if (root_module.store) {
    vmo *image;
    if (vmo_create(root_module.store_size, &image) != VX_OK) panic(VX_STR("no memory for the store image"));
    vmo_write(image, 0, root_module.store, root_module.store_size);
    given[count] = (moved_handle){&image->obj, READ_ONLY_RIGHTS};
    vx_ndb_put(&w, "handle", VX_STR("storeimage"));
    vx_ndb_put_u64(&w, "index", count++);
    vx_ndb_end(&w);
    vx_ndb_flag(&w, "storeimage");
    vx_ndb_put_u64(&w, "size", root_module.store_size);
    vx_ndb_end(&w);
  }
  uint64_t acpi_size;
  vmo *acpi = acpi_export(&acpi_size);
  if (acpi) {
    given[count] = (moved_handle){&acpi->obj, READ_ONLY_RIGHTS};
    vx_ndb_put(&w, "handle", VX_STR("acpi"));
    vx_ndb_put_u64(&w, "index", count++);
    vx_ndb_end(&w);
    vx_ndb_flag(&w, "acpi");
    vx_ndb_put_u64(&w, "size", acpi_size);
    vx_ndb_end(&w);
  }
  given[count] = (moved_handle){&root_resource()->obj, ROOT_RESOURCE_RIGHTS};
  vx_ndb_put(&w, "handle", VX_STR("resource"));
  vx_ndb_put_u64(&w, "index", count++);
  vx_ndb_end(&w);
  vx_ndb_put(&w, "cmdline", boot.cmdline);
  vx_ndb_end(&w);
  if (boot.seeded) { // the root task seeds everything after it from this (lib/vx-rand)
    vx_ndb_put(&w, "entropy", (vx_str){(const char *)boot.seed, sizeof boot.seed});
    vx_ndb_end(&w);
  }
  if (w.failed) panic(VX_STR("the root task's spawn message does not fit"));

  channel_msg *m = msg_alloc((uint32_t)(sizeof(vx_msg_header) + w.len), count);
  channel *ours, *theirs;
  if (!m || channel_create(&ours, &theirs) != VX_OK) panic(VX_STR("cannot make the root task's channel"));
  *(vx_msg_header *)msg_body(m) = (vx_msg_header){.ordinal = VX_SPAWN};
  memcpy(msg_body(m) + sizeof(vx_msg_header), text, w.len);
  for (uint32_t i = 0; i < count; i++) m->handles[i] = given[i]; // the message takes our references
  if (channel_write(ours, m) != VX_OK) panic(VX_STR("cannot send the root task's spawn message"));
  object_release(&ours->obj); // the message stays queued; then the root task sees PEER_CLOSED
  return theirs;
}

static void start_root_task(void) {
  const char *task_name = root_module.name;
  task *t;
  if (task_create(task_name, 0, &t) != VX_OK) panic(VX_STR("cannot create the root task"));
  t->may_debug_write = true;

  uint64_t entry;
  vx_status st = elf_load(t, root_module.image, root_module.size, &entry);
  if (st != VX_OK) panic(VX_STR("cannot load the root task"));

  vmo *stack;
  uint64_t stack_va = USER_STACK_TOP - USER_STACK_SIZE; // the page below stays unmapped
  if (vmo_create(USER_STACK_SIZE, &stack) != VX_OK ||
      task_map(t, stack, 0, stack->size, VX_MAP_WRITE, VX_MAP_WRITE, &stack_va) != VX_OK)
    panic(VX_STR("cannot give the root task a stack"));
  object_release(&stack->obj);

  channel *bootstrap = root_spawn_message(t);
  vx_handle start;
  thread *th;
  if (handle_add(t, &bootstrap->obj, CHANNEL_END_RIGHTS, &start) != VX_OK || thread_create(t, &th) != VX_OK ||
      thread_start(th, entry, USER_STACK_TOP, start, 0) != VX_OK)
    panic(VX_STR("cannot start the root task"));
  object_release(&bootstrap->obj); // its handle holds it
  object_release(&th->obj);        // running, it holds its own reference
  object_release(&t->obj);         // its handle to itself and its thread keep it
}
