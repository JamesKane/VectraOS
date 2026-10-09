# ADR-0051: a physical VMO's cache policy

Status: proposed, 2026-10-09 (M7 step 7b1c). Design: docs/21 §4.

## Context

A physical VMO (device memory, minted from a Resource) is mapped uncached, as a device's registers must be. A framebuffer mapped so draws at the speed of single uncached stores; write-combining gathers them into bursts, which is how every display stack maps scanout memory. Fuchsia keeps a cache policy on its physical VMOs, uncached by default (`zircon/kernel/vm/vm_object_physical.cc:161`), set by `zx_vmo_set_cache_policy` only while nothing maps the VMO (`vm_object_physical.cc:269`; `zircon/kernel/lib/syscalls/vmo.rs:275`).

## Decision

1. **`vmo_op(vmo, VX_VMO_CACHE, policy, 0)`**, an operation of the call that resizes and decommits, not a new syscall. Policies: `VX_CACHE_DEVICE` (uncached, the default) and `VX_CACHE_WC` (write-combining). It needs `WRITE` on the VMO.
2. **Before the first mapping only**, as Fuchsia's: a VMO once mapped keeps its policy (`BAD_STATE`), so no two mappings of it ever disagree, and nothing need be remapped. A VMO of RAM is cached always (`UNSUPPORTED`).
3. **x86_64:** IA32_PAT's entry 1 is write-combining, in place of write-through, which nothing maps (Linux's layout: write-back, write-combining, uncached-minus, uncached); a write-combining page has PWT alone. Every CPU's PAT is the same, set as it starts.
4. **aarch64:** MAIR attribute 3 is Normal Non-cacheable, outer shareable in the page's entry; device pages keep attribute 2 (Device-nGnRnE).
5. **The boot framebuffer** is handed to user space as such a VMO: Limine's first 32-bit RGB framebuffer, as `framebuffer` to the root task with its geometry and channels, and by svcd to a manifest that asks (`framebuffer`, svc(6)). Limine marks it framebuffer memory, which the kernel never counts as RAM.

## Consequences

- `displayd`'s simplefb back end (7b3) maps the firmware's framebuffer write-combining; a later GPU driver's scanout buffers would be RAM, cached, and flushed as its device needs.
- The ABI grows an operation and two constants; libvx does not export the wrapper yet (vx-rt's `vx_vmo_cache`).
- virtio-gpu's framebuffer is the firmware's driver's to scan out: once it lets go at ExitBootServices nothing shows it, so the harness tests the boot framebuffer on x86's VGA and aarch64's ramfb (`display=fb`), and virtio-gpu waits for its own driver (7b4).
