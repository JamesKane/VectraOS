# The `clock` class protocol

Status: draft. Written for the Q8B's platform step (ADR-0019 §9, step 1), and frozen when that step lands.

A clock controller that several devices share has one owner, a driver that serves this protocol (01 §7.2). On the Q8B that owner is `drv-qcom-gcc`, for Qualcomm's global clock controller (GCC) and the GPU's clock controller. Other drivers never touch the controller's registers. They **vote**: they ask for a power domain or a clock to be on, or for a rate, and the server turns a resource off only when no vote holds it.

A vote lives exactly as long as the open file that made it. A driver that exits or crashes loses its votes with its connection, without a cleanup path that could be skipped.

The protocol is a 9Px file tree (02 §5) with one-line text commands, as Plan 9's device files are. Votes change at device start, suspend and resume, a few times a second at most, so there is no ring.

## 1. The client code that uses it

| Client | Votes for | When |
|---|---|---|
| `drv-gpu-adreno` | `gpu.cx`: the GPU's CX power domain with its clocks, in `qcom_gpucc`'s order (ADR-0019 §5) | at start, held while it runs; GX is the GMU's |
| the SD driver | `sd2.core` | at start. UEFI left it on, so it is adopted (§3.3) |
| the I²C driver | `i2c13.se` | the same |
| the USB driver | `usb0.master`, `usb1.master` and their PHY clocks | at start, and around suspend |

The names are examples. The SoC record defines them (§4). Drivers use `lib/vx-driver/clock.c`:
- `vx_clock_on(c, name)` and `vx_clock_off(c, name)`;
- `vx_clock_rate(c, name, hz)` and `vx_clock_min(c, name, hz)`.

Each is one `Twrite` on the vote file. No first user takes a rate yet: the GPU's frequency is the GMU's, and the display's pixel clock belongs to `disp-msm` (§5).

## 2. The tree

```
/dev/clock/
    info     soc=sc8280xp server=drv-qcom-gcc version=1
    list     one line per resource:
             gpu.cx domain on holders=drv-gpu-adreno:1
             sd2.core clock on holders=firmware
             gcc.gpu-gpll0 clock on holders=(gpu.cx)
             qup1.se4 rate 19200000 holders=drv-i2c-geni:1 min=19200000
    vote     each open is a separate vote set (§3)
```

`info` and `list` are read-only and readable by anyone with `/dev/clock` in their namespace. `list` names each holder by its driver and instance. A hold that comes from another resource that depends on it is shown in parentheses, and one adopted from the firmware as `firmware`.

## 3. Votes

### 3.1 Who opens `vote`

A driver never opens `vote` itself. When `devmgr` spawns a driver whose match record names `clock=` resources, it dials the clock server's post and opens `vote`. It writes `limit` with those names (§3.2) and hands the driver the connection, as a channel handle in the spawn message, with the vote file open as fid 1. So a driver can vote only for the resources its manifest names, and the limit cannot be widened. Scripts and debugging tools read `list`; they have no vote file.

### 3.2 Commands

Each write is one or more lines, applied in order. If a line fails, the write ends with an `Rerror` naming that line, and the lines before it stay applied. A read of `vote` returns this vote set's holdings, one line each (`gpu.cx on`, `qup1.se4 min 19200000`).

| Command | Does |
|---|---|
| `on NAME` | Holds NAME on. Answered once the hardware says it is on: a domain's power status bit set, or a branch clock's `CLK_OFF` clear. The record gives each a deadline; a resource that misses it is turned off again and the error is `clock: NAME: timed out`. A second `on` from the same vote set is a no-op |
| `off NAME` | Releases this set's hold. The resource goes off once nothing holds it |
| `min NAME HZ` | Holds a rate resource at HZ or more. The server sets the highest minimum any vote set holds, rounded up to a rate the record lists. `min NAME 0` releases |
| `rate NAME HZ` | Holds a rate resource at exactly HZ, which must be one the record lists. A rate is exclusive: while one vote set holds it, another's `rate` or a `min` above it is `clock: NAME: rate held`. `rate NAME 0` releases |
| `limit NAME…` | From now on this vote set may name only these resources. A later `limit` can only narrow it. `devmgr` writes it (§3.1) |

Errors are 9P2000 `Rerror` strings:
- `clock: NAME: no such resource`
- `clock: NAME: not allowed` (outside the limit)
- `clock: NAME: rate held`
- `clock: NAME: timed out`
- `clock: NAME: not a rate`

### 3.3 What the server keeps

- **Dependencies.** A resource names what it needs, such as `gpu.cx needs=gcc.gpu-gpll0,gcc.gpu-cfg-ahb`. Those are turned on first, held for as long as it is, and released after it is off. Order within a resource (the GPU's memory NoC clock only once the CX domain is up) is the record's sequence, not the client's business.
- **Firmware state is adopted.** At start the server reads every resource's state from the hardware. Whatever is on is held by `firmware`. The firmware's hold ends at the first client `on` for that resource, and from then on it follows the votes. So a clock that UEFI left running for a device with no driver yet stays on, and the server never turns off what it did not turn on.
- **Lingering after loss.** When a vote set's connection is lost, rather than closed by `off`, its holds linger for the record's `linger` time (5 s by default) before they are released. A driver that `svcd` restarts (01 §7.4) votes again within that time, so its device is not power-cycled under it. On the Q8B that matters for `gpu.cx`, whose loss would also lose the GPU SMMU's state. An explicit `off` takes effect at once.
- **Server restart.** A restarted server adopts the hardware's state again (everything on is held by `firmware`), so nothing goes off in the gap. Clients see their connection close, and `lib/vx-driver/clock.c` asks `devmgr` for a new vote connection and replays the holdings it kept.

## 4. The SoC record's part

The resources come from the SoC record (01 §7.2), not from the protocol. For the Q8B that is `/boot/soc/sc8280xp.ndb`. Each resource is a record with:
- its name and kind (`domain`, `clock`, `rate`);
- its controller and register offsets;
- `needs=`, and for a rate the rates it allows;
- `deadline=` and `linger=`;
- for a domain, its sequence of steps, in order.

The server is generic code for each kind of register block (a GDSC, a branch clock, an RCG, a PLL vote). The record says which blocks and in what order. A new SoC is a new record, and a new code path only for a kind of block the server has never seen.

## 5. Not in this protocol

- **Controllers one device owns alone** stay with that device's driver: the display clock controller's pixel RCG is `disp-msm`'s (ADR-0019 §6). The rule in 01 §7.2 is about sharing: a controller that one driver uses is not a reason for a server.
- **RPMh votes** for bus bandwidth and rail levels. The a690 makes no bandwidth votes, and the GMU votes its own `gfx.lvl`. When a device needs one, RPMh gets its own protocol or joins this one by amendment.
- **The GPU's frequency**, which the GMU sets (ADR-0019 §5).
- **SoCs with many clocks that drivers set at run time** (Rockchip's CRU, if the RK3588 stays): version 2, if `rate` and `min` over listed rates prove too coarse.

## 6. Conformance

A fake server in `tests/host/` keeps resources and dependencies in memory, with a record of its own. The suite checks:
- dependency order;
- adoption, and no off for an adopted resource with no client vote;
- lingering after a dropped connection, against an immediate `off`;
- rate exclusivity, and minimums combining to the highest;
- that `limit` only narrows.

`lib/vx-driver/clock.c` runs against the same fake.

## 7. Open questions

1. **`linger`'s default.** It must cover `svcd`'s first restart and the driver's start-up, but not keep a device powered long after a driver that `svcd` has given up on.
2. **Passing a 9Px connection in a spawn message** (§3.1) is a channel handle, which works today. Whether `devmgr` should instead pass a `Tshare` token for an open file (the `posix` extension, `docs/proto/posix.md`) is a question for every class that limits what a driver may do. `clock` is the first such class.
