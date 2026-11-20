// SPDX-License-Identifier: BSD-3-Clause

// The MMIO pages devmgr grants (Pages.swift): the pages a range touches,
// which grants are refused for sharing one, and the pages `status` lists
// as in two hosts.

import DevMgr
import Testing

@Test func aRangeTouchesWholePages() {
  #expect(Pages.span(0x1000, 0x1000) == (0x1000, 0x2000))
  #expect(Pages.span(0x1FFF, 2) == (0x1000, 0x3000))
  #expect(Pages.span(0x1800, 0x10) == (0x1000, 0x2000))
  #expect(Pages.span(0x1000, 0) == (0x1000, 0x2000))
}

@Test func exclusiveGrantsRefuseASharedPage() {
  let ledger = PageLedger()
  // The Sky1's RST0 page and a device with registers in its other half.
  #expect(ledger.claim(host: "a", [(0x1600_0000, 0x400, true)]) == nil)
  let refused = ledger.claim(host: "b", [(0x1600_0800, 0x100, true)])
  #expect(refused?.page == 0x1600_0000 && refused?.host == "a")
  #expect(ledger.refusal(of: "b") == "page 0x16000000 is a's")
  // Neither is held for the refused host; a disjoint page is fine.
  #expect(ledger.claim(host: "b", [(0x1600_1000, 0x100, true)]) == nil)
  #expect(ledger.refusal(of: "b") == nil)
  // A host never conflicts with itself.
  #expect(ledger.claim(host: "a", [(0x1600_0400, 0x400, true)]) == nil)
  #expect(ledger.shared.isEmpty && ledger.sharedText.isEmpty)
}

@Test func aSharedPageIsRefusedWhicheverIsExclusive() {
  let ledger = PageLedger()
  #expect(ledger.claim(host: "a", [(0x4000, 0x1000, false)]) == nil)
  #expect(ledger.claim(host: "b", [(0x4800, 0x100, true)])?.host == "a")
  #expect(ledger.claim(host: "c", [(0x8000, 0x1000, true)]) == nil)
  #expect(ledger.claim(host: "d", [(0x8000, 0x10, false)])?.host == "c")
  // All or none: d's first range is free, its second isn't.
  #expect(ledger.claim(host: "d", [(0xA000, 0x1000, true), (0x8000, 0x10, true)]) != nil)
  #expect(ledger.claim(host: "e", [(0xA000, 0x1000, true)]) == nil)
}

@Test func releasingAHostFreesItsPages() {
  let ledger = PageLedger()
  #expect(ledger.claim(host: "a", [(0x4000, 0x1000, true)]) == nil)
  ledger.release(host: "a")
  #expect(ledger.claim(host: "b", [(0x4000, 0x1000, true)]) == nil)
}

@Test func statusListsPagesInTwoHosts() {
  // Shared registers as the Sky1 grants them today: RST0 linked to three
  // devices, mailbox 6's page in scmi and in power.
  let rst = (base: UInt64(0x1600_0000), size: UInt64(0x1000))
  let grants = [
    PageGrant(host: "mali", base: rst.base, size: rst.size, exclusive: false),
    PageGrant(host: "mali", base: 0x1500_0000, size: 0x1_0000, exclusive: true),
    PageGrant(host: "linlon", base: rst.base, size: rst.size, exclusive: false),
    PageGrant(host: "dptx", base: rst.base, size: rst.size, exclusive: false),
    PageGrant(host: "scmi", base: 0x0A00_0000, size: 0x800, exclusive: false),
    PageGrant(host: "power", base: 0x0A00_0400, size: 0x100, exclusive: false),
  ]
  let shared = PageLedger.shared(grants)
  #expect(shared == [
    SharedPages(first: 0x0A00_0000, end: 0x0A00_1000, hosts: ["scmi", "power"]),
    SharedPages(first: 0x1600_0000, end: 0x1600_1000, hosts: ["mali", "linlon", "dptx"]),
  ])
  let ledger = PageLedger()
  for g in grants { _ = ledger.claim(host: g.host, [(g.base, g.size, g.exclusive)]) }
  #expect(ledger.sharedText == "shared 0xa000000-0xa000fff scmi power\nshared 0x16000000-0x16000fff mali linlon dptx\n")
  #expect(PageLedger.shared(Array(grants.prefix(2))).isEmpty)
}

@Test func theLinkedRangesFollowThePolicy() {
  var gpu = Device.ACPIDevice(path: "\\_SB_.GPU_", hid: "CIXH5000", cids: [], status: 0x0B,
                              resources: [.mmio(base: 0x1500_0000, size: 0x1_0000), .interrupt(0x10D, .levelHigh)])
  gpu.linked = [Device.LinkedRange(role: "reset", base: 0x1600_0000, size: 0x1000)]
  let claims = PageLedger.claims(gpu)
  #expect(claims.count == 2)
  #expect(claims[0].exclusive)
  #expect(claims[1].base == 0x1600_0000 && claims[1].exclusive == GrantPolicy.linkedRangesExclusive)
}
