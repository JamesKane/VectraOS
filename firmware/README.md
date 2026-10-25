# Firmware

Code that the hardware itself runs, which VectraOS loads into a device but
didn't write (D4). Each is listed here with where it came from, its
licence, and what loads it. Nothing else third-party goes on a device.

| What | Where in the tree | Source | Licence | Loaded by |
|---|---|---|---|---|
| Realtek RTL8126_2: the MAC microcontroller's breakpoints (339 register writes) and the PHY's RAM code (2449 writes, version 0x0060) | `drivers/net/rge/lib/RTL8126Code.swift`, generated, not edited | FreeBSD `sys/dev/rge/if_rge_microcode.h` at `b9585475ee62` (`rtl8126_2_mac_bps_regs`, `rtl8126_2_mac_bps_vals`, `mac_r26_2_mcu`), OpenBSD's Kevin Lo, "hardware programming portions from Realtek Semiconductor" | BSD-2-Clause (OpenBSD's ISC-style text), kept in the file's header | rge(3), each time it starts a chip that doesn't already hold that version |

Without the RTL8126_2's code a gigabit link partner took 16 s to link,
the 2.5 and 5 Gb/s training stalling, as the Orange Pi 6 Plus showed;
FreeBSD, which loads it, links in about a second.
