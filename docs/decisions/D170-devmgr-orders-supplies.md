# D170. devmgr's side of supply leases: it grants register windows as bound VMOs, powers a device up in its provider graph's order before its driver starts, and ends its supplies before any provider cuts (2026-11-20, the owner asked for B2's second half; extends D169, narrows its §5)

D169's kernel half binds a supply to a physical VMO, an interrupt object
or a BTI. devmgr grants a driver host its registers as MMIO resources,
from which the driver makes its own VMOs, so nothing devmgr grants can be
bound. And a device's power-up order is still each driver's: mali(3)
turns on its power domain, clocks, power resource and reset itself,
through scmi(3), devmgr's `/dev/acpi/power` and sky1-reset(3).

## The decision

1. **Register windows are granted as bound VMOs.** For each MMIO range
   it grants (a device's own and its linked ones), devmgr makes the
   physical VMO itself from its exclusive resource (D167), binds it to
   the device's supplies, and gives the host the VMO in place of the
   resource. DriverHost's `map(bar:)` maps either, so a driver doesn't
   change. Interrupt objects and the BTI devmgr makes are bound too.
2. **One supply per provider link,** made by devmgr from the device's
   resource: a power domain or clock (scmi(3)), its ACPI power resources
   (devmgr's own `_ON`), a reset (sky1-reset(3)). devmgr holds them: it
   is where the provider graph is (D163), and the ordering is the
   graph's. This narrows D169 §5, which had each provider's driver hold
   what it feeds; a provider still cuts nothing devmgr hasn't ended,
   since devmgr is the only one that asks it to cut.
3. **devmgr powers a device up before starting its driver,** in the
   graph's order (domains, then clocks, then power resources, then
   resets released): the order a driver keeps today moves into the
   graph, and the driver starts with its device on. A driver that needs
   a step mid-bring-up (mali's Q-channel gating, in its own registers)
   keeps that step.
4. **Powering a device down** (devmgr's `ctl`: `power DEVICE off`):
   devmgr ends the device's supplies with a deadline (500 ms), each
   bound object signalled; the driver host releases them (DriverHost's
   default on `SUPPLY_ENDING`: it ends, so every handle and mapping
   goes), or the kernel takes them at the deadline; only after every
   supply ended does devmgr ask each provider, in the reverse of the
   graph's order, to cut (reset asserted, `_OFF`, clock off, domain
   off). `power DEVICE on` powers it up again as in §3, with new
   supplies and windows, and restarts its driver host.
5. **The provider's deadline** (D169 §3): a provider that doesn't
   confirm its cut within 500 ms is reported in devmgr's status; the
   device stays down.
6. **The check:** board-test powers the GPU off and on and reads its
   GPU_ID again (`board-test: ok: the GPU powered off and on`), with the
   console on the display all the while; boot-board runs the same
   through QEMU where it has such a device, else skips it. D169's exit
   (the G720 off and on under a running desktop) follows on the desktop
   image.

## Not chosen

- **Supplies handed to each provider's driver** (D169 §5 as written).
  It needs every provider to learn the graph's order and every
  consumer it feeds; devmgr already has both.
- **Drivers quiescing in place on `SUPPLY_ENDING`** (keeping the host,
  remapping later). A driver host ending is the release, needs no code
  in each driver, and restarting it is what binding does.

## As built (§1, §2 and the host's default, 2026-11-20)

- **Windows:** only an ACPI platform device's driver gets VMOs
  (`Supplies.lease`, `drivers/devmgr/lib/Supplies.swift`); PCI and
  devicetree devices keep their resources (the smaller change; DriverHost
  maps either, so they can follow). A BAR's resource is replaced in the
  same startup slot by a physical VMO named `m<base>:<size>` in hex
  (`DeviceHandle.windowName`), since a VMO has no physical address to ask
  for; DriverHost tells it from a resource by the handle's object type, then
  that name, and `bar(_:)`, `map(bar:)` and `Registers.physical` answer as
  before. I/O port BARs and the SMC resource stay resources.
- **Interrupts aren't bound:** devmgr grants an IRQ resource and the driver
  makes the interrupt object, so only the VMOs and the BTI are bound.
- **One supply per link, per range:** the kernel binds a VMO only to a
  supply made from a resource that covers it, so each link has one kernel
  supply for each distinct range among the device's windows (its own and its
  linked ones), the first range's carrying the BTI. Firmware memory (the SMC's
  page) can't be bound and is left out.
- **Links** come from the device's `power-domains` (_DSD), CLKT, `powered`
  and RSTL, in that order (`Supplies.links(of:)`); `status` ends the line
  with `supplies N` for a device given window VMOs.
- **Renewal** is the host's start: `launcher.extraStartup` makes the VMOs and
  supplies each time, so `power DEVICE on` needs no call of its own.
- **DriverHost:** a `DeviceResources` given a window VMO starts a thread that
  waits for `SUPPLY_ENDING` on a duplicate of the first one, prints
  `<driver>: supply ending: releasing` and ends the process;
  `releasesOnSupplyEnd: false` opts out.
