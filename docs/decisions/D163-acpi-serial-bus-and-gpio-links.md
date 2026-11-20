# D163. ACPI's I2C devices and GPIO connections are links, as a devicetree's are: devmgr reads them from _CRS, starts each provider first and mounts its tree, and a real-time clock is any driver whose tree has an `rtc` (2026-11-20, the owner asked for I2C and the RTC; extends D158 and D154)

The Orange Pi 6 Plus's real-time clock is an Epson RX8900 at address
0x32 on the Sky1's fourth Cadence I2C controller: `\_SB_.I2C3.RTC0`,
`_HID` `RX008900`, read from the board under FreeBSD (2026-11-20). The
seven controllers are `CIXH200B`, `\_SB_.I2C0` to `I2C7` (`I2C6`
disabled), and other devices hang from them: audio codecs, the USB-C
PD controllers, the DIMMs' SPD hubs. The Sky1's GPIO controllers
(`CIXH1002`, `CIXH1003`) are the providers of `GpioInt` and `GpioIo`
connections in the same way.

D158 made a devicetree's I2C children devices linked to their
controller, and D154 gave a devicetree device's driver its links at
`/dev/dt/links` and each provider's tree at `/dev/provider/SERVICE`.
ACPI says the same thing differently: the device is wherever the
namespace puts it (here a child of its controller), and its `_CRS`
names its controller in an `I2cSerialBus` connection's resource source.
devmgr already parses that descriptor (`SerialBusConnection`) and
`GpioInt`/`GpioIo` (`GPIOConnection`) and does nothing with them. An
ACPI device's links today are only CIX's CLKT and RSTL entries, and no
provider is started for an ACPI device or mounted in its driver.

The time service reads a clock where devmgr mounts one at
`dev/rtc<n>`, but only from a driver of the power class (p1(3)'s), and
arm64's bootfs has no time service at all: time(4) says arm64's
machines have no clock it reads.

## The decision

1. **An `I2cSerialBus` connection is an `i2c` link.** For each I2C
   connection (type 1) in a present device's `_CRS`, devmgr adds the
   link `i2c - <controller> <address>`, the controller the device its
   resource source names, by its namespace path as devmgr writes paths
   (`\_SB_.I2C3`, each segment four characters), the cell the
   connection's 7-bit or 10-bit slave address. The connection's speed
   isn't a cell: a controller runs its bus at its own speed (below).
   A resource source that names no present device gives a link with no
   provider (`-`), as a devicetree's does.
2. **A `GpioInt` or `GpioIo` connection is a `gpio` link,** named
   `int` or `io`, its provider the controller its resource source
   names, its cells the connection's pins, one cell a pin, then its
   flags word as the descriptor gives it: the 16-bit field at offset 4
   (a GpioInt's interrupt flags: bit 0 edge, bits 1-2 polarity, 0 high,
   1 low, 2 both, bit 3 shared, bit 4 wake; a GpioIo's I/O flags: bits
   0-1 restriction, bit 3 shared), so `gpio int PROVIDER 12 3` is pin
   12, edge, active low (PlatformTests fixes the encoding). No
   consumer needs one yet; the GPIO controllers' driver is written with
   them.
3. **One provider mechanism.** An ACPI device's links are served at
   `/dev/acpi/links`, a line a link in `/dev/dt/links`'s format
   (Links.text), and devmgr starts each provider's driver before its
   consumers' and mounts its tree at `/dev/provider/SERVICE`, as for a
   devicetree device: `Links.order` over both kinds of device, and the
   provider found by its path whichever bus it came from. The CLKT and
   RSTL links keep their meaning (CLKT's provider is empty: the SCMI
   agent's tree is still `/dev/scmi`).
4. **A controller's speed** is its `_DSD` `clock-frequency` (the
   Sky1's published tables give 400000), else 100 kHz; its driver reads
   its `_DSD` through `/dev/acpi/properties`, which devmgr serves for
   every ACPI device as `name value` lines: an integer in decimal, a
   string as it is, a reference as its namespace path, a package of
   those as its elements, space apart; a buffer, or a package holding
   anything else, is left out. A reset link from RSTL now also makes its
   controller a provider (started first, mounted), as the one mechanism
   says.
5. **A real-time clock is any driver whose tree has an `rtc`,** of
   whatever class, mounted at `dev/rtc<n>` (p1(3) is power's, rx8900(3)
   the new `rtc` class's). arm64's bootfs takes the time service with
   devmgr's manifest, as rv64's does; on QEMU's `virt`, which has no
   clock we drive, it says `no rtc` after its wait, as now.

## Not chosen

- **The connection's speed as the bus's speed,** or the lowest of
  its children's. A bus has one speed, and its controller's tables say
  it; a child asking for less would slow every other device on it.
  If a board needs it, the controller's driver can read its children's
  connections then.
- **A second link mechanism for ACPI** (resource sources resolved by
  each driver, or the controller's registers granted to its children).
  D158 already chose links and an IPC library for the bus; ACPI
  describes the same graph.
- **UEFI's runtime clock.** FreeBSD reads time through it on this
  board, but nothing calls firmware after ExitBootServices (the kernel's
  rules), and the RX8900 is the clock UEFI itself reads.
