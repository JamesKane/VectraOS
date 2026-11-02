# D160. A devicetree's thermal zones are devmgr's, beside ACPI's: each read from its sensor's driver, and power(8) keeps their trips (2026-11-02, the owner asked for the K1's sensor; extends D130 and D154)

D130 gave the machine's thermal limits one keeper: power(8) reads
devmgr's `thermal`, a line a zone, and powers the machine off at a
critical trip (and steps CPUs down at a passive one). Its zones were
ACPI's alone, whose `_TMP` devmgr evaluates. On the Orange Pi RV2 the
loader makes ACPI tables from the devicetree (D154) and makes no
thermal zones, so power(8) ran there with none, and nothing watched
the K1's eight harts at 1.6 GHz. The K1's tree describes five zones
(`thermal-zones`, upstream's `k1.dtsi`), each on one of the thermal
sensor's five points, each with a critical trip at 115 °C.

## The decision

1. **A tree's zones are lines in devmgr's `thermal`,** after ACPI's and
   in their form: `/thermal-zones/<name>`, the temperature in tenths
   of a kelvin, the zone's first `passive` and first `critical` trip
   as `_PSV` and `_CRT`, and its `polling-delay` as `_TZP`.
   `DeviceTreeBus.thermalZones` reads them (`drivers/bus/dt`).
2. **Their temperatures are their sensors' drivers':** the node a
   zone's `thermal-sensors` names is a device, and its driver serves
   `temperatures`, a line a sensor, `<n> <C|-> <name>`, the number the
   specifier's cell. devmgr reads it when `thermal` is read, once a
   sensor for all its zones. k1-tsensor(3) is the first.
3. **power(8) is unchanged:** it keeps every zone's trips, wherever it
   came from. No second policy is made for a devicetree machine, and
   no thermal framework of zones, cooling devices and governors.

## Consequences

- On the RV2 a die at 115 °C turns the board off through power(8),
  devmgr's `/dev/reboot` and p1(3); a passive trip throttles nothing
  until the K1's CPU clocks have a driver power(8) can step.
- The sensor's interrupts, which a tree's zones expect (`polling-delay
  = <0>`), aren't used: power(8) reads the zones at most a second apart.
