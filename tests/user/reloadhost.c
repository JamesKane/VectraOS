// reloadhost: the hot-reload host (03 §6.1, M7 step 7g2b; tests/qemu/reload.ndb),
// vxui(2)'s template as an SDK app on libvxui.so. The memory is one lazy
// VMO mapped at MEMORY_AT, the same address every run; the code is
// /tmp/app.so, loaded with vx_image_open. A thread watches /tmp (9Px
// notify) and wakes the app when a new app.so is renamed into place, so a
// build that writes app.so.new and renames it is seen whole; the host loads
// it between two events and calls the new vx_app_update from the next.
// F9 is looped playback's (7g2c): it records, plays the recording in a loop,
// then goes live again. While playing, the app is given the recording alone.

#include <vxui.h>

static constexpr uint64_t MEMORY_AT = 0x2000'0000'0000, MEMORY_SIZE = 64ull << 20;
static constexpr uint32_t KEY_REPLAY = 0x07u << 16 | 0x42; // F9
static const char *const DIR = "/tmp", *const NAME = "app.so", *const PATH = "/tmp/app.so";

// One wake for each app.so renamed or made in DIR.
static const char *watcher(void *arg) {
  vx_app *app = arg;
  vx_loop *l = vx_loop_new();
  vx_fd fd = vx_open(vx_cstr(DIR), VX_OREAD);
  if (!l || fd < 0 || vx_watch(l, fd, 1) != VX_OK) {
    vx_printf("reloadhost: cannot watch %s: %.*s\n", DIR, VX_FMT(vx_errstr()));
    return "cannot watch";
  }
  vx_event evs[8];
  for (;;) {
    int64_t n = vx_loop_wait(l, VX_INFINITE, 0, evs, 8);
    for (int64_t i = 0; i < n; i++)
      if (evs[i].kind == VX_EV_CHANGED && evs[i].changed.what & (VX_CHANGED_MOVED_TO | VX_CHANGED_CREATE) &&
          vx_str_eq(evs[i].changed.name, vx_cstr(NAME)))
        vx_app_wake(app);
  }
}

// The image at PATH's vx_app_update, or null (said why).
static vx_app_update_fn *load(void) {
  vx_image *image = nullptr;
  if (vx_image_open(vx_cstr(PATH), &image) != VX_OK) {
    vx_printf("reloadhost: %.*s\n", VX_FMT(vx_errstr()));
    return nullptr;
  }
  vx_app_update_fn *update = (vx_app_update_fn *)vx_image_symbol(image, "vx_app_update");
  if (!update) vx_printf("reloadhost: %s has no vx_app_update\n", PATH);
  return update;
}

int main(void) {
  uint64_t at = MEMORY_AT;
  vx_handle vmo = VX_HANDLE_NONE;
  if (vx_as_reserve(vx_task_self(), MEMORY_SIZE, 0, VX_AS_FIXED, &at) != VX_OK ||
      vx_vmo_create(MEMORY_SIZE, VX_VMO_LAZY, &vmo) != VX_OK ||
      vx_as_map(vx_task_self(), vmo, 0, MEMORY_SIZE, VX_MAP_WRITE, &at) != VX_OK) { // there, or not at all
    vx_printf("reloadhost: no memory at %#llx\n", (unsigned long long)MEMORY_AT);
    return 1;
  }
  vx_app_memory *mem = (vx_app_memory *)at;
  *mem = (vx_app_memory){.app = vx_app_open("org.example.reload"),
                         .size = MEMORY_SIZE - 4096,
                         .storage = (uint8_t *)at + 4096, // the page after this one: whole pages, for replay
                         .vmo = vmo,
                         .offset = 4096};
  mem->window = vx_window_open(mem->app, "Reload", 320, 240);
  if (!vx_thread_spawn(watcher, mem->app, 0, 0)) return 1;
  vx_app_update_fn *update = nullptr;
  vx_fd there = vx_open(vx_cstr(PATH), VX_OREAD); // built already: else the first rename loads it
  if (there >= 0) vx_close(there), update = load();
  if (!update) vx_printf("reloadhost: waiting for %s\n", PATH);
  enum { LIVE, RECORDING, PLAYING } replay = LIVE;
  static const char *const SAID[] = {"live", "recording", "playing"};
  vx_event ev;
  while (vx_wait(mem->app, &ev, VX_INFINITE)) {
    if (ev.kind == VX_KEY && ev.keyboard.usage == KEY_REPLAY) { // the host's, never the app's
      if (!ev.keyboard.down || ev.keyboard.repeat || ev.flags & VX_REPLAYED) continue;
      if (replay == LIVE)
        replay = vx_replay_start(mem->app, mem) ? RECORDING : LIVE;
      else if (replay == RECORDING)
        replay = vx_replay_play(mem->app) ? PLAYING : LIVE;
      else
        vx_replay_stop(mem->app), replay = LIVE;
      vx_printf("reloadhost: %s\n", SAID[replay]);
      continue;
    }
    if (ev.kind == VX_WAKE) { // a new image: from the next event on
      vx_app_update_fn *next = load();
      if (next && update) mem->reloads++;
      if (next) update = next;
      vx_window_redraw(mem->window);
      continue;
    }
    if (replay == PLAYING && !(ev.flags & VX_REPLAYED) && ev.kind != VX_CLOSE) continue; // live input
    if (update) update(mem, &ev);
    if (ev.kind == VX_CLOSE) return 0;
  }
  vx_printf("reloadhost: %s\n", vx_app_error(mem->app) ? vx_app_error(mem->app) : "the wait ended");
  return 1;
}
