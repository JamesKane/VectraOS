// poweroff: the machine off (M5 step 7c), by asking bus-acpi on /srv/acpi,
// which enters S5 through ACPICA, or has devmgr make the PSCI call where the
// firmware's ACPI cannot. Its connector is the spawn message's srv:acpi (a
// manifest's connect=acpi), else /srv/acpi in its namespace. It returns only
// if the machine is still on.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"
#include "../lib/vx-acpi/mint.h"

const char *vx_main(void) {
  vx_handle c = vx_spawn_take("srv:acpi");
  static vx_ns ns;
  if (!c && vx_ns_from_spawn(&ns) == VX_OK) c = vx_ns_connector(&ns, VX_STR("/srv/acpi"));
  if (!c) return "no /srv/acpi";
  vx_print(VX_STR("poweroff: asking bus-acpi\n"));
  vx_msg_header req = {.ordinal = VX_ACPI_POWER_OFF}, rep = {};
  vx_call call = {.wr_bytes = &req, .wr_len = sizeof req, .rd_bytes = &rep, .rd_cap = sizeof rep};
  vx_status st = vx_channel_call(c, &call, vx_clock_read() + 10'000'000'000);
  if (st == VX_OK && rep.flags) st = (vx_status)(int32_t)rep.flags;
  vx_print(VX_STR("poweroff: the machine is still on\n"));
  return st == VX_OK ? "the machine is still on" : "bus-acpi could not power off";
}
