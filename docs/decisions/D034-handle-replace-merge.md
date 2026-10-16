# D34. handle_replace merges into handle_duplicate (2026-10-15, decided)

The third of V1's merges: one call, 98 → 97.
- **handle_duplicate(handle, rights, out, options)** (11) with
  CROI_HANDLE_DUPLICATE_CONSUME is what handle_replace (12) was: the
  handle goes, even when the rights asked for are refused, and needs no
  DUPLICATE right. Any other option is INVALID_ARGS.
- **Callers keep working:** options is the fourth argument, which every
  existing caller already passed as 0. Nothing called handle_replace.
- **Tests:** the Swift `objects` suite gains `consume`: a replace with
  fewer rights, the old handle gone, a refusal still consuming, an
  unknown option refused. handle_replace had no test before.
