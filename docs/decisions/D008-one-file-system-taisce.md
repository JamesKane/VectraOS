# D8. One file system: Taisce (2026-10-15, decided)

When two projects solved the same problem, we keep the one that gives
BeOS-style database abilities. Taisce has typed attributes, indices, live
queries and a change journal. NeoVectra's Bε-tree FS has none of these, so it
is not carried forward. FAT stays read-only for the ESP.
