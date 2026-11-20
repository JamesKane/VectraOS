// Supply leases (D169): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it).
//
// A supply stands for what powers a device: a power domain, a clock, a
// reset. The provider that controls it (scmi, devmgr, a reset controller's
// driver) holds the supply object; the device's register window (a physical
// VMO made from its MMIO resource), its interrupts and its BTI are bound to
// it. A bound object is usable only while every supply it is bound to is
// live. supply_end takes them away from their holder before the provider
// cuts the supply.
//
// supply_create(MMIO resource, uint32_t *out): a supply for the device whose
// registers the resource covers. The resource must be a range (not a ranged
// root); the VMOs bound to the supply must lie inside it. The handle has the
// basic rights and WRITE, which ends and binds.
//
// supply_bind(supply, object): binds a physical VMO (inside the supply's
// resource, with no children), an interrupt object or a BTI. BAD_STATE if the
// supply is no longer live, or the object is bound to a supply that ended;
// ALREADY_BOUND if it is bound to this one.
//
// supply_end(supply, deadline): ends the supply, in order:
//   1. every bound object asserts CROI_SIGNAL_SUPPLY_ENDING;
//   2. the call waits until every holder has released its object (no
//      handle to it, no mapping of it, no pin through it) or until
//      `deadline` (absolute, monotonic ns; 0 or past: at once);
//   3. then every mapping of each bound VMO is removed, each bound
//      interrupt is masked for good and each bound BTI's domain is
//      aborted: a device's DMA faults in its IOMMU; a BTI with no IOMMU
//      is recorded as untranslated, and its pins stay pinned until
//      bti_release_quarantine;
//   4. the supply asserts CROI_SIGNAL_SUPPLY_ENDED and the call returns.
// Only then may the provider cut. A stray access by the holder after step
// 3 is a page fault in its process; an interrupt object's ack is CANCELED;
// bti_pin is refused.
#pragma once
#include <stdint.h>

enum : uint32_t {
  // On each bound object (VMO, interrupt, BTI): its supply is ending; the
  // holder quiesces, unmaps and closes its handles. Never cleared.
  CROI_SIGNAL_SUPPLY_ENDING = 1u << 6,
  // On the supply: the end is done, nothing bound is usable.
  CROI_SIGNAL_SUPPLY_ENDED = 1u << 7,
};
