# The `regulator` class protocol

Status: draft (ADR-0023). Frozen when the first device-tree SoC's platform step lands.

A voltage regulator feeds devices that several drivers run: a CPU cluster, the GPU and its power domain, the NPU and its SRAM, I/O banks. So a regulator has one owner, the driver for its PMIC or regulator chip, which serves this protocol. On the RK3588 boards those are:
- the RK806 PMIC on SPI;
- the RK8602 and RK8603 regulators on I²C (`vdd_cpu_big0_s0`, `vdd_npu_s0`).

Other drivers vote. They ask for a regulator to be on and for a voltage range, and the server sets the lowest voltage inside every holder's range. This is Linux's consumer model, and Fuchsia's `fuchsia.hardware.vreg` in our file shape.

The protocol has `clock`'s shape (`docs/proto/clock.md`): a 9Px tree, one-line commands, and vote sets that `devmgr` opens, limits and hands to drivers. A vote lasts as long as its connection, with the same lingering after loss.

## 1. The client code that uses it

| Client | Regulators | Uses |
|---|---|---|
| the clock server | `vdd_gpu_s0`, `vdd_npu_s0` | the GPU's and NPU's power domains need them on first (`domain-supply`; `clock.md` §3.3) |
| the CPU platform driver | `vdd_cpu_lit_s0`, `vdd_cpu_big0_s0`, `vdd_cpu_big1_s0` | voltage before frequency, for a delegated domain (ADR-0020, ADR-0023 item 7) |
| `drv-gpu-mali` | `vdd_gpu_s0` | voltage for each GPU operating point |
| `drv-npu-rocket` | `vdd_npu_s0` | the NPU's operating points; `sram-supply` is the same rail on these boards |
| the SD driver | the card's I/O rail | 3.3 V, then 1.8 V for UHS |

Drivers use `lib/vx-driver/regulator.c`: `vx_reg_on`, `vx_reg_off` and `vx_reg_range(r, name, min_uv, max_uv)`.

## 2. The tree

```
/dev/regulator/
    info     server=drv-rk806 bus=spi2 version=1
    list     one line per regulator:
             vdd_gpu_s0 on 750000 range=550000-950000 step=6250 holders=(gpu.pd),drv-gpu-mali:1
             vdd_cpu_lit_s0 on 850000 holders=drv-cpufreq-rk3588:1 always-on
             vcc_3v3_s3 on 3300000 holders=firmware always-on
    vote     each open is a separate vote set
```

Several regulator servers can be running (one per PMIC or chip). Each posts its own directory, and the names are unique across the board, as the DT's `regulator-name` values are.

## 3. Votes

| Command | Does |
|---|---|
| `on NAME` | Holds NAME on. Answered once the regulator reports it is up, or after its ramp time from the DT (`regulator-enable-ramp-delay`) |
| `off NAME` | Releases this set's hold. The regulator goes off when nothing holds it, unless it is `always-on` |
| `range NAME MIN MAX` | Microvolts. The server sets the lowest voltage that lies in every holder's range and is a step the regulator can make, then answers once it has settled (the ramp rate from the DT). If the ranges do not overlap: `regulator: NAME: no voltage fits` |
| `range NAME -` | Releases this set's range |
| `limit NAME…` | Narrows the names this connection may use. `devmgr` writes it |

A read of `vote` returns this set's holdings (`vdd_gpu_s0 on 700000-950000`). No command ever sets a voltage outside the regulator's own limits (`regulator-min-microvolt`, `regulator-max-microvolt`).

The server keeps:
- **Firmware state.** It adopts what it finds on, held by `firmware`, as `clock` does.
- **`always-on` and `boot-on`** from the DT. An `always-on` regulator is never turned off; a `boot-on` one is adopted.
- **Order between a regulator and its supply.** A regulator fed by another (`vin-supply`) holds a vote on its supply for as long as it is on.

## 4. Raising voltage before frequency

A device's operating points pair a frequency with a voltage. The client sequences them:
- **going up:** `range` to the new voltage first, then `clock` `rate`;
- **going down:** `rate` first, then `range`.

The protocol does not couple them, because one regulator often feeds several clocks. Each completion means the hardware has settled, so the client never waits by guessing.

## 5. Not in this protocol

- **Voltages the firmware sets.** RPMh rails on Qualcomm, and a GMU's own votes, never appear here.
- **Battery and charger** control, which is a `power` device class of its own when a board needs it.
- **Coupled regulators** that must move together (Linux's `regulator-coupled-with`). None of the first boards needs them.

## 6. Conformance

A fake server in `tests/host/` checks:
- range intersection and the lowest-fit rule;
- `always-on` and adoption;
- supply ordering;
- lingering after a dropped connection;
- that `limit` only narrows.
