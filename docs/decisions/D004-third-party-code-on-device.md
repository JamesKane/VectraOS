# D4. Third-party code: first-party on the device, heavy tools only on the host (2026-10-15, decided)

Everything that executes on a VectraOS device is first-party Swift or C23.
That includes the Wasm runtime, the TOSA executor, crypto, codecs and the
network stack.

- **Host tools** may use third-party compilers as build tools. MLIR and
  StableHLO, inside `vxc`, are the expected case. A host tool's output must
  be one of our artifact formats.
- **Firmware blobs** that the hardware requires are listed with their
  provenance in `firmware/README.md`. The Q8B's ADSP, CDSP and GPU firmware
  are examples.
- **Rejected:** vendoring pinned libraries onto the device (NeoVectra's
  model), and zero third-party code even on the host.
