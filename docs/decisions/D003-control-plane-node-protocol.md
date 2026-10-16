# D3. The control plane: todhchai's Node protocol locally, 9P2000.L only at the network edge (2026-10-15, decided)

On the machine, services speak the Node protocol and typed `@IPCLibrary`
interfaces over croi channels, using the IPC wire format. `9gate` is the only
component that speaks 9P2000.L. It exports subtrees to the network and
imports remote servers.

- **Principle 1:** the gateway is a translator at a boundary, not a second
  local mechanism. No local service may speak 9P.
- **Rejected:** 9P2000.L everywhere, and NeoVectra's 9Px.
