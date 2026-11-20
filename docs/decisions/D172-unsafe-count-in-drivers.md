# D172. A driver's `unsafe` is counted: lines with the keyword outside DriverHost are held per driver to a recorded number that only falls (2026-11-20, the owner scheduled the backlog's B8)

Drivers build with `-strict-memory-safety`, so every use of raw memory
is marked `unsafe`, but nothing bounds how many there are. At the count
(`drivers/block` 83 lines, `drivers/net` 49) a driver's marks are most
of its lines that touch a ring, a descriptor or a register page, and a
new driver can copy the habit without anyone seeing it grow. The
reference design forbids the keyword in drivers and keeps raw access in
one audited runtime; ours keeps DriverHost (`drivers/host`) as that
runtime, and says how far the drivers are from not needing more.

## The decision

1. **The count.** `vx loc` counts, per unit, the lines of Swift that
   have the identifier `unsafe` on them: the expression keyword
   (`unsafe f()`), the attribute (`@unsafe`) and the modifier
   (`nonisolated(unsafe)`). A line is counted once however many it has.
   Comments and string literals (and their interpolations) are skipped.
   `unsafeBitCast`, `withUnsafeBytes` and a member `.unsafe` are other
   names. `@safe(unchecked)` is not counted: it declares a type safe,
   it isn't a use of anything unsafe.
2. **The units.** A unit is a directory `drivers/<class>/<name>`: each
   driver (the directories with a `driver.manifest`), and likewise a
   class's shared `lib` or `client`, a bus library (`drivers/bus/acpi`),
   and `drivers/devmgr`. A driver's own `lib/` counts with it. Not
   counted: `drivers/host`, which is the audited runtime, and anything
   under a `tests` directory (host and native test code, which is not
   the driver).
3. **The record.** `docs/unsafe.tsv` holds a count per unit, beside the
   other size budgets. A unit over its row fails; a unit under it fails
   too, saying to lower the row, so that the record only falls; a unit
   with no row has zero, so a new driver starts at zero and its first
   `unsafe` needs a row, in a change that says why. Raising a row is
   the same kind of change as raising a ceiling: a decision entry.
4. **Where it runs.** `vx loc --check`, which `vx ci` runs, and
   `docs/risk.tsv` maps `drivers/`, `docs/unsafe.tsv` and the counter's
   own directory to the `loc` check. The counter is the `UnsafeCount`
   library (`tools/unsafe/lib`), with a test that includes the control:
   one more line than recorded fails.
5. **DriverHost grows the safe forms** when a pattern is worth it, and
   the change that does lowers the rows it frees. The patterns found
   when the record was made are in the roadmap's B8; none was done with
   it.

## Not chosen

- **Counting occurrences.** Two marks on a line are one decision to
  read it for; lines are what the roadmap quoted and what review sees.
- **Forbidding `unsafe` outside DriverHost.** The drivers need it today
  (the DMA regions' addresses, the descriptors); a ban would be a
  budget no driver meets. The record is the ratchet toward one.
- **Counting tests.** Their raw access is host code over fakes and the
  native test programs, not the device's driver.
