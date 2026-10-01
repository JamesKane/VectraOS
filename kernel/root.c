// root.c: starts the root task from the boot module of that name (01 §10):
// svcd, or whatever `vx.root=NAME` on the kernel command line names (ktest, for
// the kernel's own tests). It gets a handle to itself as its one argument, and
// the debug-write capability.

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
} root_module;

static void find_root_module(void) {
  vx_str name = cmdline_value(VX_STR("vx.root"));
  if (!name.len || name.len > 23) name = VX_STR("svcd");
  const struct limine_file *module = find_module(name);
  if (!module) panic(VX_STR("no module for the root task"));
  root_module.image = module->address;
  root_module.size = module->size;
  memcpy(root_module.name, name.ptr, name.len);
}

static void start_root_task(void) {
  const char *task_name = root_module.name;
  task *t;
  if (task_create(task_name, &t) != VX_OK) panic(VX_STR("cannot create the root task"));
  t->may_debug_write = true;

  uint64_t entry;
  vx_status st = elf_load(t, root_module.image, root_module.size, &entry);
  if (st != VX_OK) panic(VX_STR("cannot load the root task"));

  vmo *stack;
  uint64_t stack_va = USER_STACK_TOP - USER_STACK_SIZE; // the page below stays unmapped
  if (vmo_create(USER_STACK_SIZE, &stack) != VX_OK ||
      task_map(t, stack, 0, stack->size, VX_MAP_WRITE, &stack_va) != VX_OK)
    panic(VX_STR("cannot give the root task a stack"));
  object_release(&stack->obj);

  vx_handle self;
  thread *th;
  if (handle_add(t, &t->obj, ALL_RIGHTS, &self) != VX_OK || thread_create(t, &th) != VX_OK ||
      thread_start(th, entry, USER_STACK_TOP, self, 0) != VX_OK)
    panic(VX_STR("cannot start the root task"));
  object_release(&th->obj); // running, it holds its own reference
  object_release(&t->obj);  // its handle to itself and its thread keep it
}
