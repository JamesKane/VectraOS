# D11. One front door: `vx` (2026-10-15, proposed)

todhchai's `td` becomes `vx`: build, boot, test, bench, trace and ci. There
is one build graph, CMake and Ninja with presets (from croi). Whether host
tests also run under SwiftPM, as in todhchai, or only under CTest is decided
in V0.
