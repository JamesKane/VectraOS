# D15. A bring-up link before the board, over SSH (2026-10-15, decided)

The owner asked for a remote shell and file copies to the board during
bring-up, ahead of V4. The roadmap now has V3, the bring-up link,
between V2 and V4. Later milestones are renumbered: Taisce on disk is V5,
the desktop V6, the edge V7, compute V8, Wasm V9. V1 moves off the
critical path and runs alongside.

- **Protocol: SSH, lifted from todhchai's N1** (owner's choice over a 9P
  subset of 9gate). The crypto, network stack, sshd and SFTP are mostly
  built and tested there. Stock OpenSSH on the dev machine needs nothing
  of ours, and the link is encrypted and key-authenticated from the first
  day.
- **This amends D3.** SSH is allowed as a development tool:
  - off unless the image is built with `--ssh`;
  - on-link only;
  - public keys only;
  - never spoken by a local service.

  9gate remains the only namespace protocol on the network, and reuses
  V3's stack and crypto.
- **Links: a serial console plus Ethernet** (owner's choice).
  - A GENI UART driver makes the board's output and hangs visible from the
    first boot. It needs a 1.8 V USB-serial adapter on the header.
  - The TC956x Ethernet carries SSH.
  - Both are developed against QEMU first: virtio-net there, and a
    register-level model for GENI.
- **Warm boot from memory** (owner's choice), so a new kernel needs no
  stick and no walk. The kernel hands off to an image held in memory,
  reusing the loader's ELF, page-table and handoff libraries. It is a
  `SYSTEM_POWERCTL` command, so there is no new syscall. UEFI network boot
  was not chosen (roadmap, open question 7).
- **Files land in Taisce on a RAM-backed block device**, so bring-up has
  no second file system.
- **The shell is todhchai's rc**, since SSH sessions run it. NeoVectra's rc
  is dropped. This settles open question 2.
