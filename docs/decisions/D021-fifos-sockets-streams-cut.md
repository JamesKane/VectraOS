# D21. FIFOs, sockets and streams are cut (2026-10-15, decided)

The first family of V1's cuts (`docs/syscall-audit.md` §2): fifteen
calls, 150 → 135.
- **FIFOs and sockets** (87–89, 190–193). The one ring format replaces
  both: a record ring for FIFOs, the byte-stream mode for sockets. Their
  info topic, threshold properties, policy conditions (NEW_SOCKET,
  NEW_FIFO) and the MANAGE_SOCKET right went with them.
- **Streams and the stream-size calls** (194–201). A mapping replaces a
  stream. A VMO's content size stays, as the property
  ZX_PROP_VMO_CONTENT_SIZE: Taisce's mapped files need a byte length. It
  is now the one way to read or set it, and it keeps Zircon's per-VMO
  size lock (`ContentSize.swift`).
- **Tests move to Swift as they are touched.** A `usertest.c` test of a
  cut call is deleted. Checks of what survives move to a Swift suite,
  here `VmoSuite` (content size, the size lock, executable VMOs). A C test
  that only needed the same kernel path through another call (a
  stream-size read becoming the property) is edited in place, and moves
  with its function when the waits are cut.
- **Lost:** the WRONG_TYPE refusal of a name on an unnamed type. Sockets
  were the last user-creatable unnamed type with SET_PROPERTY, so the
  check has no caller to test it with.
