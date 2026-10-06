# ADR-0031: `system_power` and `clock_set`, the machine's power and its wall clock

Status: accepted, 2026-10-06 (proposed 2026-10-03). Two new syscalls (01 §3), added in M5 steps 7c and 7d. `system_power` went in with step 7c before this ADR was written; this ADR records it after the fact.

## Context

Step 7c needed the machine powered off, and step 7d needed a wall clock.

**Power off.** On x86_64, power off is ACPI's S5. Entering it runs AML (`_PTS`, `_S5`) and writes the fixed hardware's sleep registers. All of that is `bus-acpi`'s, through the grants `devmgr` mints, so x86_64 needs nothing from the kernel. QEMU's aarch64 firmware is hardware-reduced ACPI with no sleep registers. There, power off is a firmware call: PSCI `SYSTEM_OFF`, by `hvc` or `smc` as the FADT's ARM boot flags say. Those instructions trap to EL2 or EL3 and only the kernel at EL1 can execute them. No existing call reaches them. The kernel already makes PSCI calls, or will (`CPU_ON`; `CPU_SUSPEND` in ADR-0020).

**The wall clock.** Until now every clock was the kernel's monotonic one, counted from boot: `CLOCK_REALTIME` started in 1970, and fsd's and tmpfs's file times did too. Three designs were weighed:
1. A UTC offset kept by the kernel: one number, read with the `clock_read` call everything already makes.
2. A user-space time service, Plan 9's `/dev/time` in spirit. Every reader then needs an IPC round trip, or a shared page that spawn hands to every task.
3. A kernel UTC clock object, Fuchsia's `zx_clock`. It allows a narrower setting right, but means a new object type and more kernel surface.

The user chose design 1.

## Decision

1. **`system_power(resource, op)`** takes the root Resource with `MANAGE`. `VX_POWER_OFF` makes the PSCI `SYSTEM_OFF` call by the FADT's conduit, or returns `UNSUPPORTED` where powering off is ACPI's (x86_64) or the FADT says there is no PSCI. It returns only if the machine is still on.
   - `devmgr` holds the root Resource and makes the call when `bus-acpi` asks (`VX_ACPI_OFF` on their channel), because ACPICA found no way to power off. Clients ask `bus-acpi` on `/srv/acpi` (`cmd/poweroff`).
   - Reboot (PSCI `SYSTEM_RESET`, ACPI's reset register) is a later `op` with its first user.
2. **`clock_set(resource, utc)`** takes the root Resource with `MANAGE`. It sets the wall clock to `utc`, in nanoseconds since 1970: the kernel keeps UTC's offset from the monotonic clock. `clock_read(&info)` reports it in `vx_clock_info.utc_offset`, with `VX_CLOCK_UTC` once it has been set.
   - musl's realtime clocks add the offset, and so do fsd's and tmpfs's file times and `/sys/clock/now`'s `realtime`. Until a clock driver sets it, the offset is 0 and they count from boot, as before.
   - A clock driver does not hold the root Resource. `devmgr` gives a driver whose record says `clock` a channel. The driver writes the time its hardware keeps (`lib/vx-driver/clockproto.h`), and `devmgr` makes the call. A network-time service, when there is one, reports the same way.
   - The monotonic clock is never changed. Deadlines stay on it, and an absolute `clock_nanosleep` on a realtime clock is converted to it once, when it is made.

## Consequences

- Both calls are gated on the root Resource, the coarsest right there is. Only `devmgr` holds it today, and both calls are narrow, so that is acceptable. If a third whole-machine call appears, a narrower Resource kind for whole-machine control is the better shape.
- Moving the power-off call to `svcd`'s platform service, as step 7's plan first said, is a change of holder, not of call. That service does not exist yet.
- The offset changes in one step. A sleep already armed against the wall clock keeps its old monotonic deadline, which is POSIX's rule for relative sleeps but not for absolute ones. Slewing the offset, and re-arming absolute realtime sleeps when it moves, come with network time.
- Nothing orders services after the clock is set. A service that starts before `devmgr` hears from the clock driver stamps 1970 times.
