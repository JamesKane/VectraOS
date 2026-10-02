# ADR-0021: Thermal policy: `thermd`, zones from the firmware or the SoC record, and actions through the limits that already exist

Status: proposed, 2026-10-02. Found by looking at the Radxa Dragon Q8B (ADR-0019).

## Context

02 §5.2 publishes temperatures as files (`/dev/sensors/temp/*`), but nothing acts on them. Someone has to:
- power the machine off before it is damaged;
- slow the CPU or GPU before the silicon has to;
- report all of it, since rule 6 says nothing degrades silently.

What the hardware does by itself differs:
- **x86_64:** the CPU throttles itself (PROCHOT) and shuts down at its own critical temperature. ACPI describes thermal zones in AML: `_TMP`, `_CRT`, `_HOT`, `_PSV`, and `_ACx` for fans.
- **The Q8B:** ACPI says nothing (no `_TMP`, `_CPC` or `_PSS`). AbyssBSD's notes give:
  - four TSENS v2 controllers with 46 sensors. Thresholds are unprogrammed and interrupts are off, so the sensors are polled;
  - trips from Radxa's devicetree: CPU and SoC 110 °C, GPU 85 °C, memory 90 °C;
  - LMh, which clips the big cores to 2.8–2.9 GHz by itself near 95 °C;
  - the fan, which belongs to Radxa's service on the ADSP (ADR-0022). Without the ADSP the fan runs at full speed, a hardware fail-safe, and the OS must never drive the PMIC's PWM, or it fights the ADSP.

  AbyssBSD's critical power-off was tested: two readings in a row over the limit, a clean shutdown, then PSCI power-off.

The levers exist already:
- `cpu_configure`'s `VX_CPU_LIMITS` keeps each caller's limits separately and applies the tightest (ADR-0020);
- `drv-gpu-adreno` takes `freq max` in its `ctl` (ADR-0019 §5);
- `svcd` shuts the system down.

What is missing is the policy that joins them.

## Decision

- **`thermd`**, a service `svcd` starts early and restarts always. It reads sensors through `/dev/sensors/temp/` and acts. It holds a CPU-configuration `Resource` for its own limits, and a `ctl` connection to each GPU.
- **Zones** group sensors and carry trips. They come from one of two places:
  - ACPI thermal zones, which `bus-acpi` evaluates (`_TMP`, `_CRT`, `_HOT`, `_PSV`, `_TSP`);
  - the SoC record (01 §7.2), where ACPI has none. For the Q8B, `sc8280xp.ndb` names the zones and their sensors (`cpu`, `gpu`, `mem`, and the rest by AbyssBSD's controller and channel map) and their trips.
- **Three kinds of trip:**
  - **critical:** two readings in a row at or over the trip start an orderly shutdown through `svcd`. If the system is not off 10 s later, `svcd` makes the PSCI `SYSTEM_OFF` (or ACPI S5) call itself. The critical trip can be lowered by the user, never raised.
  - **passive:** over the trip, `thermd` lowers the zone's devices' highest allowed level one step every polling period until the temperature falls. Below the trip minus a hysteresis (5 °C by default), it raises them a step at a time. CPU zones act through `VX_CPU_LIMITS`, GPU zones through `freq max`.
  - **active:** fans, only where the OS owns the fan (ACPI `_ACx` and fan devices). Where the firmware owns it, the SoC record says `fan=firmware`, and `thermd` never touches it. On the Q8B the fan is the ADSP's.
- **Polling.** A sensor without interrupts is read every second, and every 250 ms in a zone within 10 °C of any trip. A sensor driver that can program thresholds (TSENS can) arms them at the next trip up and down, and `thermd` then waits on a `Counter` instead of polling.
- **The hardware's own protection stays on.** LMh, PROCHOT and the CPU's own shutdown are below `thermd`, never replaced by it. `thermd` exists to act before them.
- **Real time is told, not overruled silently.** A passive limit below what a `realtime` or `interactive-frame` admission assumed (01 §8) wins, because physics does. But it is published: an event on `/sys/thermal/events`, and the admitted context's owner sees the limit in `/proc/N/threads/T/sched` (05 §3). `audiod` and `winsrv` read the event and report it.
- **The tree:**

```
/sys/thermal/
    zones/cpu/
        info     sensors=tsens0.1,tsens0.2,… source=soc-record
        temp     the zone's hottest sensor, "61.5 C"
        trips    passive 95 C · critical 110 C
        state    normal | passive level=3 | critical
        ctl      (write) critical 100 C · passive 90 C   (lower only; the source's trips are the ceiling)
    events       one line per transition: time zone from to temp
```

## Consequences

- A machine's thermal behaviour is published, and the user can lower it.
- `thermd` is the second user of `VX_CPU_LIMITS` (ADR-0020), after the power profile. Neither overrides the other: the kernel applies the tightest.
- `drv-gpu-adreno` (ADR-0019) and every later GPU driver take `freq max` in their `ctl`. ADR-0018's vendor ADRs say what level steps their GPU has.
- The Q8B's thermal facts live in `sc8280xp.ndb`, beside the rest of the SoC's, and AbyssBSD's map of TSENS channels to zones is cited there.
- Tests:
  - on T0, a fake sensor driven by a script checks hysteresis, the two-reading rule, and that a critical trip shuts the system down within its deadline;
  - on the Q8B, a critical trip lowered to 30 °C at idle shuts the board down cleanly, as AbyssBSD's test did.
