# D7. Wasm as a process, not a unikernel (2026-10-15, proposed)

The paper compiles WASI apps into unikernels to avoid OS overhead. On this
kernel a process with ring-mapped I/O already has that property. So `wasmd`
runs each Wasm app as an ordinary process, with WASI imports mapped onto
nodes and rings. There is no second kernel image format.
