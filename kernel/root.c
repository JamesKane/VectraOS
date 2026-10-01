// root.c: starts the root task, svcd, from the boot module of that name (01 §10).
// It gets a handle to itself as its one argument, and the debug-write capability.

LIMINE_REQUEST struct limine_module_request module_request = {.id = LIMINE_MODULE_REQUEST_ID};

static const struct limine_file *find_module(const char *name) {
  struct limine_module_response *r = module_request.response;
  size_t n = 0;
  while (name[n]) n++;
  for (uint64_t i = 0; r && i < r->module_count; i++) {
    const char *path = r->modules[i]->path;
    size_t len = 0;
    while (path[len]) len++;
    if (len > n && path[len - n - 1] == '/' && memcmp(path + len - n, name, n) == 0) return r->modules[i];
  }
  return nullptr;
}

static void start_root_task(void) {
  const struct limine_file *module = find_module("svcd");
  if (!module) panic(VX_STR("no svcd module"));

  task *t;
  if (task_create("svcd", &t) != VX_OK) panic(VX_STR("cannot create the root task"));
  t->may_debug_write = true;

  uint64_t entry;
  vx_status st = elf_load(t, module->address, module->size, &entry);
  if (st != VX_OK) panic(VX_STR("cannot load svcd"));

  vmo *stack;
  uint64_t stack_va = USER_STACK_TOP - USER_STACK_SIZE; // the page below stays unmapped
  if (vmo_create(USER_STACK_SIZE, &stack) != VX_OK || task_map(t, stack, VX_MAP_WRITE, &stack_va) != VX_OK)
    panic(VX_STR("cannot give svcd a stack"));
  object_release(&stack->obj);

  vx_handle self;
  thread *th;
  if (handle_add(t->handles, &t->obj, ALL_RIGHTS, &self) != VX_OK ||
      thread_create(t, entry, USER_STACK_TOP, self, &th) != VX_OK)
    panic(VX_STR("cannot start svcd"));
  sched_start_thread(th);
}
