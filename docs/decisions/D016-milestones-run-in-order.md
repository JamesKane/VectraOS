# D16. Milestones run in order (2026-10-15, decided; corrects D15)

D15 moved V1 off a "critical path" to run alongside V2–V4. That framing
was wrong. The aim is to have the board's dependencies in place before
bring-up is attempted, not to reach the board as fast as possible. The
milestones run in order, V0 → V1 → V2 → V3 → V4 → …. V3 (the bring-up
link) stays ahead of V4 because the board work depends on it.
