# D158. Devices on an I2C bus: each is a devmgr device linked to its controller, whose driver serves the bus's transfers as an IPC library (2026-11-01, decided by the owner; extends D154)

D154 made a devicetree's devices devmgr's: an enabled node with a
`compatible` on the root or a `simple-bus`. Any other node's children
were left to their parent's driver to read, as an Ethernet MAC reads its
PHY's. The Orange Pi RV2's PMIC, the SpacemiT P1 (`spacemit,p1` at
address `0x41` on the K1's `i2c8`), is such a child: its regulators feed
the SD card (`vmmc-supply`, `vqmmc-supply`), and it has the board's
real-time clock and its power-off switch. The owner chose it as the
next driver (2026-11-01, "I2C + P1 PMIC"). Nothing in VectraOS reached a
device through another device's bus.

## The decision

1. **An I2C controller's children are devices.** A child of an enabled
   device whose node is named `i2c` or `i2c@...` (the name the I2C
   controller binding requires), with a `compatible` and a `reg`, is a
   device of its own, as a `simple-bus`'s child is: its interrupts and
   links read as any device's, no `reg` range granted (its `reg` is its
   address on the bus), and a link `i2c - <controller> <address>` that
   names the controller as its provider. devmgr starts the controller's
   driver first, as it starts any provider first, and mounts its tree at
   `/dev/provider/<service>` in the child's driver.
2. **A controller's driver serves `vectraos.i2c.bus`**, an IPC library,
   at `bus` in its tree: `transfer(address, write, read)`, the bytes
   written and then, after a repeated start, the count read; one
   transfer at a time, in its order. Errors name what the bus did: no
   device answered its address, a byte wasn't acknowledged, a bus error,
   arbitration lost, a timeout. The library's API baseline is committed
   beside it, as the display link's is.
3. **A device's driver talks to its chip through that call only.** The
   PMIC's driver (`p1`) reads and writes its registers as transfers to
   its address.

## Not chosen

- **The controller's driver as its children's driver host.** One
  mechanism per job: devmgr is where devices are matched and granted
  (D156 said the same of PCIe hosts).
- **Text files for transfers** (a `ctl` written and a `result` read).
  A transfer is a request with a reply; two files would let two clients'
  requests and replies cross. The display link already crosses
  processes as an IPC library.
- **The controller's registers granted to the child's driver too.** Two
  processes would drive one controller with nothing ordering them.
