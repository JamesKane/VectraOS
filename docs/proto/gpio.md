# The `gpio` class protocol

Status: draft. Written for the Q8B's platform step (ADR-0019 §9, step 1; M9), and frozen when its first users land: SD card detect, then the audio codec's reset and wake.

A GPIO controller's pins are shared by many devices, so the controller has one owner, a driver that serves this protocol. On the Q8B that driver is `drv-qcom-tlmm`, for Qualcomm's TLMM: 228 pins at `0xf100000`, with every pin's interrupt behind one summary SPI.

Other drivers never touch the controller's registers. They hold named pins, which `devmgr` grants them from the records. A pin's interrupt reaches its consumer as a `Counter` with the kernel `Irq`'s semantics (01 §7.1).

The protocol has the same shape as `clock` (`docs/proto/clock.md`): a 9Px tree, one-line text commands, and a connection that `devmgr` opens, limits and hands to the driver.

## 1. The client code that uses it

| Client | Pins | Uses |
|---|---|---|
| the SD driver | `sd2.cd` (TLMM 131, active low, pull-up) | reads it, and its interrupt on both edges for card detect |
| the audio driver | `codec.reset` (TLMM 106, active low) | drives it to take the codec out of reset |
| the audio driver | `codec.wake` | the codec's wake interrupt, if it is routed through the TLMM (on the Q8B it is a GIC SPI, not a pin) |

The names come from the records (§4). Drivers use `lib/vx-driver/gpio.c`:
- `vx_gpio_get(g, name)` and `vx_gpio_set(g, name, v)`;
- `vx_gpio_ack(g, name)`.

Each is one `Twrite` or `Tread` on the connection's `pins` file. A pin's interrupt `Counter` comes in the spawn message, not through the protocol (§3.3).

## 2. The tree

```
/dev/gpio/tlmm/
    info       controller=tlmm soc=sc8280xp pins=228 reserved=74-79,83-86,125,126,128,129 version=1
    list       one line per named pin:
               sd2.cd 131 in pull=up active=low value=1 irq=both holder=drv-sdhci:1
               codec.reset 106 out active=low value=0 holder=drv-audio:1
               fan.pwm - owner=adsp
    pins       the holder's file: commands and reads (§3)
```

`info` and `list` can be read by anyone with `/dev/gpio` in their namespace. Reserved pins never appear in `list`. Pins a remote processor owns appear with `owner=` and no number, so the list shows they exist and that they are not the OS's.

## 3. Pins

### 3.1 Who opens `pins`

As for `clock` (`clock.md` §3.1), a driver never opens `pins` itself. When `devmgr` spawns a driver whose match record names `gpio=` pins, it opens `pins`, writes `limit` with those names, and passes the connection in the spawn message with the file open as fid 1. A pin is held by one driver at a time: a second `limit` that names a held pin fails with `gpio: NAME: held`. So two drivers can never fight over a line.

### 3.2 Commands

Each write is one or more lines, applied in order. A failing line ends the write with an `Rerror` naming it, and the lines before it stay applied. A read of `pins` returns one line per held pin, with its value (`sd2.cd 1`). Values are **logical**: 1 means active, and the record's `active=low` is applied by the server, so no driver inverts a pin by hand.

| Command | Does |
|---|---|
| `in NAME [pull=up\|down\|none]` | Makes NAME an input |
| `out NAME V [drive=MA]` | Makes NAME an output at logical value V. The drive strength in mA defaults to the record's |
| `set NAME V` | Sets an output |
| `irq NAME rising\|falling\|both\|high\|low` | Arms NAME's interrupt with that trigger. The pin's `Counter` (§3.3) counts from then on |
| `irq NAME off` | Disarms it |
| `ack NAME` | Unmasks a level-triggered pin after its consumer has handled it. An edge-triggered pin needs no ack (§3.3) |
| `state NAME` | Applies a named pin state: a set of pins with their functions, pulls and drive strengths, from the DT's `pinctrl-N` and `pinctrl-names` (`sdmmc.default`, `sdmmc.sleep`). A state is applied whole or not at all |
| `limit NAME…` | Narrows the names this connection may use. `devmgr` writes it |

A pin's function (GPIO or a peripheral) changes only through a named state, never a raw command. On a device-tree machine, `devmgr` applies a device's `default` state before it spawns the driver, and the driver may switch among the states its grant names (`pinstate=`, ADR-0023), as Fuchsia's `PinStates.SelectState` does. The protocol drives only pins in the GPIO function. The SD controller's data pins, for example, are its own. Errors are 9P2000 `Rerror` strings:
- `gpio: NAME: no such pin`
- `gpio: NAME: not allowed`
- `gpio: NAME: held`
- `gpio: NAME: not an output`
- `gpio: NAME: not in gpio function`
- `gpio: NAME: no such state`

### 3.3 Interrupts

For each pin with `irq=` in the records, `devmgr` creates a `Counter` when it spawns the consumer:
- the consumer gets the handle with only the right to wait on it;
- the GPIO driver gets one that can signal it, through its `devmgr` channel, keyed by the pin.

So the consumer binds `COUNTER_GE` on its port exactly as it would bind an `Irq` (01 §4.4), and the packet's value is the pin's interrupt count.

The GPIO driver takes the summary interrupt, reads which pins fired, and signals each pin's `Counter` with its new count. It follows the kernel `Irq`'s rules:
- **level-triggered** (`high`, `low`): the driver masks the pin when it fires and unmasks it on `ack`;
- **edge-triggered**: never masked. The consumer handles everything the device has pending before binding again, so no edge is lost.

A cascaded interrupt costs one more process hop than a GIC line. A source with a tight deadline is not wired through a GPIO (01 §7.1).

On the Q8B, the firmware leaves every pin's interrupt disabled and routed nowhere (`intr_cfg` `0xe2`, target 7). The driver routes a pin to the summary interrupt (SPI 208) only when `irq` arms it. There is no PDC, so a GPIO cannot wake the SoC from sleep.

### 3.4 The firmware's settings

Before its first command, the driver leaves every pin as the firmware set it. ACPI's GPIO consumers are not applied where the records say `acpi-gpio=ignore` (01 §7.2), so on the Q8B no pin changes until a driver that holds it asks. A pin that the records name but no driver holds keeps the firmware's setting.

## 4. The records' part

The SoC record gives the controller:
- its pins and their register layout;
- the reserved pins;
- the summary interrupt.

The board record names the pins and gives each:
- its number, `active=`, default pull and drive;
- its function;
- `irq=` if it has one;
- `owner=` if a remote processor owns it.

A driver's match record names the pins it may hold (`gpio=sd2.cd`).

## 5. Not in this protocol

- **Raw pin multiplexing.** Functions change only through named states (§3.2).
- **Several pins as one value** (a bus). No first user. When one comes, `set` takes a list.
- **Waking from sleep** through a GPIO, which needs the PDC on Qualcomm SoCs, and suspend first.
- **PMIC GPIOs.** They sit behind the PMIC's SPMI bus, a different controller. They get their own `gpio` server when a driver needs one, and the fan's PMIC GPIO 8 is `owner=adsp` (ADR-0022).

## 6. Conformance

A fake server in `tests/host/` keeps pins in memory. The suite checks:
- logical values against `active=low`;
- `limit` narrowing and one holder per pin;
- the edge and level rules, and that an edge while unbound is counted, not lost;
- that reserved and owned pins can never be named.

`lib/vx-driver/gpio.c` runs against the same fake.
