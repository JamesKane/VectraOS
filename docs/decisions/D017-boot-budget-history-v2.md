# D17. Boot budget history starts at V2 (2026-10-15, decided)

V1 trims and changes the kernel, so a baseline recorded at V0 would only
measure code that is about to change. `vx bench` still runs and reports
in the meantime, as advisory. The first `--record` happens at V2's exit,
on the kernel as V1 left it. The existing history in
`bench/history/brimstone.tsv` (croi's, converted to seconds) is kept for
reference, but it is not a VectraOS baseline.
