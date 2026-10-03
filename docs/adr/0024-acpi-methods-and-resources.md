# ADR-0024: ACPI firmware services: AML methods as a service, ACPI resources turned into grants, and `bus-acpi`'s regions

Status: proposed, 2026-10-02. Its base, ACPICA in `bus-acpi` with resources as grants and the operation regions, is built in M5 on QEMU's tables; the method connections with M9's platform work; the Sky1's own checks when it is promoted from candidate (00 §5). Found by surveying the CIX Sky1 (Radxa Orion O6), from CIX's Linaro Connect 2025 talk "ACPI support on Radxa Orion O6". It applies to every ACPI machine whose firmware services are reached by running AML, x86 laptops with embedded controllers among them. Board-specific checks (the IORT, GTDT, PCCT and `_CPC` of a real board) wait for bring-up.

## Context

`bus-acpi` runs ACPICA in user space (01 §7.2). Until now it only enumerated devices and evaluated a few tables for `svcd` (`_LPI`, `_CST`, `_CPC`, thermal zones). The Sky1 shows that on some machines a driver cannot run its device at all without AML:

- **Clocks** are AML methods on the device (`acpi_clk_enable`, `acpi_clk_set_rate` and the like). They send SCMI messages to CSU_PM, the SoC's power-management processor.
- **Power domains** of the GPU (`CIXH5000`), NPU (`CIXH4000`) and VPU (`CIXH3010`) are ACPI power resources. Their `_ON` and `_OFF` write SoC registers directly through `SystemMemory` operation regions. Devices name them in `_PR0` and `_PR3`.
- **Device frequency** comes from a CIX-specific `DVFS` package of operating points, with `SET_TARGET` and `GET_FREQ` methods that reach CSU_PM over PCC.
- **Pin control** uses ACPI 6.2's `PinFunction`, `PinConfig`, `PinGroup` and `PinGroupFunction` resources.
- **Device properties** are `_DSD` entries that reuse the DT bindings' names.
- **The fan** has vendor methods for its modes (`SFAT`, `SFMT`, `SFPF`), beside the standard fan device `PNP0C0B`.

x86 laptops raise the same need in another form: an embedded controller's operation region behind battery, lid, hotkey and fan methods.

ADR-0023 turned device-tree references into grants. ACPI has the same references in another form, and no translator.

## Decision

1. **AML methods as a service.** `bus-acpi` serves, for each ACPI device it publishes, a method connection limited to that device's own namespace node, its children, and the power resources its `_PRx` name. `devmgr` opens it and hands it to the device's driver, as it hands `clock` vote sets (`docs/proto/clock.md` §3.1).
   - On it, the driver evaluates methods by name (`_PS0`, `_PS3`, `SET_TARGET`, `GET_FREQ`, a fan's mode methods) with integer, buffer and package arguments. It gets the result back as ACPI objects in a flat encoding.
   - A method outside the device's subtree is `not allowed`.
   - The protocol is `docs/proto/acpi.md`, specified with its first user.
2. **Standard ACPI power and clocks through the existing classes:**
   - **ACPI power resources** are `domain` resources of the `clock` class, served by `bus-acpi`. `on` runs `_ON` once nothing else holds the resource on; `off` runs `_OFF` when the last holder releases it.
   - **AML clock methods** (where a platform defines them, as CIX does) are `clock` and `rate` resources served the same way.

   A driver does not know whether its domain is a GDSC behind `drv-qcom-gcc`, a PMU bit behind a Rockchip driver, or an AML method.
3. **ACPI resources become grants.** `bus-acpi` gains one translator per kind of resource, as `bus-dt` has (ADR-0023 item 2):

   | ACPI resource | Grant |
   |---|---|
   | `GpioInt`, `GpioIo` | `Counter`s and `gpio=` names |
   | `PinFunction`, `PinConfig`, `PinGroupFunction`, `PinGroupConfig` | `pinstate=` names (`default` applied before spawn) |
   | `I2cSerialBus`, `SpiSerialBus` | `i2c=` and `spi=` grants (bus and address) |
   | `_PR0`, `_PR3` | `domain=` names on `bus-acpi`'s `clock` server |
   | `_DSD` | device properties in the match record, readable by the driver |
   | the device itself | the method connection of item 1 |

   Where a record says `acpi-gpio=ignore` (the Q8B's reference-design DSDT, 01 §7.2), the GPIO and pin translators are skipped for the devices it names.
4. **`bus-acpi`'s regions are its own.** AML writes hardware through operation regions:
   - `SystemMemory` and `SystemIO`;
   - `PCC` (the PCCT's channels and doorbells);
   - `GenericSerialBus`;
   - the embedded controller's region.

   So `bus-acpi` gets exactly the regions the DSDT, SSDTs and PCCT declare, minted by `svcd`, never RAM and never the kernel's own MMIO. A driver whose MMIO grant overlaps a region `bus-acpi` holds is refused at match, and the overlap is reported, so AML and a driver never fight over a register.

   This makes `bus-acpi` trusted with those registers, as the firmware's own code. It is marked so in its `/proc/N/status`, and its region list is published in `/dev/devmgr/acpi-regions`.
5. **The deep-idle wake timer can come late.** 01 §8 had the kernel find the always-on timer in the GTDT. On the Sky1 it may be CIX's GPT, known only by a private ID in the DSDT (`CIXH1007`). So `cpu_configure` gains `VX_CPU_WAKE_TIMER` (ADR-0020): the platform service hands the kernel a timer's MMIO and interrupt, in one of the formats the kernel knows (the generic timer's memory-mapped frame, or a SoC timer the kernel has a small driver for). Until a wake timer exists, from the GTDT or this call, the idle loop never enters a state that stops the CPU's timer.
6. **CPU tiers are capacities, not two types.** The Sky1 has three tiers (4 big A720, 4 medium A720, 4 little A520), as several phone SoCs do. `/sys/cpu/topology`'s `type=` becomes `tier=` (0 is the fastest) next to `capacity=`. `sched_reserve`'s class becomes a tier or a minimum capacity: `VX_CORE_TIER(n)`, `VX_CORE_MIN_CAPACITY(c)`, `VX_CORE_ANY`. Intents are placed by capacity:
   - `interactive-frame` on the highest tier with spare capacity;
   - `background` on the lowest.

## Consequences

- `bus-acpi` grows from an enumerator into a server of three things: method connections, `clock` resources for ACPI power and clocks, and the grant translators.
- Drivers for ACPI devices stay portable across firmware styles. The same `drv-gpu-mali` asks `clock` for its domain on a DT board and on the Sky1. Only its operating points differ: the DT's OPP table, or a vendor method through item 1.
- x86 laptop support (battery, lid, hotkeys, fans) has its mechanism: the embedded controller's region in `bus-acpi`, and vendor methods through item 1.
- `cpu_configure` gains an operation, and 01 §8's topology and reservations change shape before any program depends on them.
- What waits for bring-up on the Sky1:
  - whether the IORT puts the Mali behind the SMMU (if so, `drv-gpu-mali` needs no `trusted` mark, ADR-0018 item 9);
  - whether the GTDT's GT block survives deep idle (if so, item 5 is not needed there);
  - the PCCT and `_CPC` details;
  - whether panvk supports Mali arch 12.
