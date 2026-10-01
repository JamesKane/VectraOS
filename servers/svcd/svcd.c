// svcd: the first process (docs/01 §7, §10). In M1 it is a stub that proves
// user space works, as the milestone's exit test (04 §5): it prints which task
// it is, waits on a port with a deadline, posts a packet to itself, and maps a
// VMO. Then it sleeps on its port for good, and the CPU idles.

#include "../../lib/vx-rt/rt.c"

[[noreturn]] static void fail(vx_str what, int64_t status) {
  vx_print(VX_STR("svcd: FAILED: "));
  vx_print(what);
  vx_print(VX_STR(", status "));
  if (status < 0) {
    vx_print(VX_STR("-"));
    status = -status;
  }
  vx_print_u64((uint64_t)status);
  vx_print(VX_STR("\n"));
  __builtin_trap();
}

int vx_main(vx_handle self) {
  vx_task_summary info;
  vx_status st = vx_task_info(self, &info);
  if (st != VX_OK) fail(VX_STR("task_info"), st);
  vx_print(VX_STR("svcd: hello from user space (task "));
  vx_print_u64(info.id);
  vx_print(VX_STR(")\n"));

  // A wait with nothing to wake it ends at its deadline, and not before.
  vx_handle port;
  if ((st = vx_port_create(0, &port)) != VX_OK) fail(VX_STR("port_create"), st);
  vx_packet got[4];
  vx_instant start = vx_clock_read(), deadline = start + 10'000'000;
  int64_t n = vx_port_wait(port, deadline, 0, got, 4);
  vx_instant woke = vx_clock_read();
  if (n != VX_ERR_TIMED_OUT) fail(VX_STR("port_wait with a deadline"), n);
  if (woke < deadline) fail(VX_STR("port_wait woke before its deadline"), woke - deadline);
  vx_print(VX_STR("svcd: port deadline wait ok: requested 10.000 ms, woke after "));
  vx_print_millis((uint64_t)(woke - start));
  vx_print(VX_STR(" ms\n"));

  // A packet posted to the port is the next thing the wait returns.
  vx_packet post = {.key = 42, .value = 7};
  if ((st = vx_port_post(port, &post)) != VX_OK) fail(VX_STR("port_post"), st);
  n = vx_port_wait(port, VX_INFINITE, 0, got, 4);
  if (n != 1 || got[0].key != 42 || got[0].value != 7 || got[0].trigger != VX_TRIGGER_USER)
    fail(VX_STR("port_wait after port_post"), n);
  vx_print(VX_STR("svcd: self-post ok\n"));

  // A VMO mapped where the kernel chooses is zeroed, writable and all there.
  vx_handle vmo;
  uint64_t addr = 0;
  if ((st = vx_vmo_create(64ull * 1024, 0, &vmo)) != VX_OK) fail(VX_STR("vmo_create"), st);
  if ((st = vx_as_map(self, vmo, 0, 64ull * 1024, VX_MAP_WRITE, &addr)) != VX_OK) fail(VX_STR("as_map"), st);
  volatile uint64_t *words = (volatile uint64_t *)addr;
  if (words[0] != 0 || words[8191] != 0) fail(VX_STR("a new VMO is not zeroed"), 0);
  words[0] = 0x5678;
  words[8191] = 0x1234;
  if (words[0] != 0x5678 || words[8191] != 0x1234) fail(VX_STR("VMO contents"), 0);
  if ((st = vx_handle_close(vmo)) != VX_OK) fail(VX_STR("handle_close"), st); // the mapping keeps it
  if (words[8191] != 0x1234) fail(VX_STR("VMO contents after closing its handle"), 0);
  vx_print(VX_STR("svcd: vmo map ok\n"));

  for (;;) vx_port_wait(port, VX_INFINITE, 0, got, 4);
}
