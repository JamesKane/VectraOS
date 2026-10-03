# The `registers` class protocol

Status: draft (ADR-0023); parked with it, until a tiered board needs a device tree. Frozen when the first device-tree SoC's platform step lands.

Some register blocks are written by many drivers. Rockchip's GRF ("general register files") and IOC hold, side by side:
- USB PHY settings;
- PCIe and SATA mode selection;
- display output muxing;
- I/O-domain voltages;
- bits for most other blocks.

Giving every such driver the block's MMIO would let any of them change any other's settings. So the block has one owner, a driver that serves this protocol. Each client is granted **named fields**, an offset and a mask, and can read and write those only. This is Fuchsia's `fuchsia.hardware.registers` in our file shape.

## 1. The client code that uses it

| Client | Fields (examples) |
|---|---|
| the USB2 PHY driver | its port's suspend, VBUS and line-state bits in `usb2phy0_grf` |
| the PCIe driver | its controller's mode and link bits in `pcie3_phy_grf` |
| the display driver | VOP2's output routing in `vo1_grf` |
| the SD driver | the I/O-domain voltage select for its bank in `pmu1_ioc` |

Linux's drivers hard-code their GRF offsets, and the DT only names the syscon. So the fields come from the **board record** (01 §7.2), not the DT: `registers=grf field=usb2phy0.vbus offset=0x0008 mask=0x0003 width=32`. A driver's match record names the fields it may use.

## 2. The tree

```
/dev/registers/usb_grf/
    info     block=usb_grf base=0xfd5ac000 size=0x1000 write=hiword version=1
    list     usb2phy0.vbus 0x0008 0x0003 holder=drv-rk-usb2phy:1
    fields   the holder's file (§3)
```

There is one directory per register block, all served by one driver per SoC.

## 3. Commands

| Command | Does |
|---|---|
| `read NAME` | The next read of `fields` answers `NAME VALUE`, the field's bits shifted down to bit 0 |
| `write NAME VALUE` | Writes VALUE into the field and leaves every other bit as it is |
| `limit NAME…` | Narrows the fields this connection may use. `devmgr` writes it |

How a write leaves other bits alone depends on the block:
- **`write=hiword`** (Rockchip): the upper 16 bits of each 32-bit register enable writes to the lower 16. The server writes the field's mask into the upper half and the value into the lower, in one store. No read, no lock, and no other field touched, even by hardware that updates its own bits.
- **`write=rmw`:** the server reads, modifies and writes under its own lock. Fields that hardware also changes are not grantable in this mode.

## 4. What the server checks

- **When the record loads,** the grants of all clients on one block must not overlap. A record with overlapping grants is refused whole, as Fuchsia's overlap check does, so two drivers can never own one bit.
- **Each field has one holder.**
- A field the record names but no driver holds keeps the firmware's value.

## 5. Not in this protocol

- **Registers only one driver uses** stay in that driver's own MMIO grant.
- **Clock and reset registers** are the `clock` server's, even where they sit in a shared block.
- **Pin multiplexing** is the `gpio` server's (`docs/proto/gpio.md`), even though on Rockchip it lives in the IOC and GRF too. The `gpio` server is then a client of this one for the iomux fields.

## 6. Conformance

A fake server in `tests/host/` over an in-memory block checks:
- that hiword writes touch only their field;
- read-modify-write under contention;
- refusal of overlapping grants;
- that `limit` only narrows.
