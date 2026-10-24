// SPDX-License-Identifier: BSD-3-Clause

// What bin/mali makes of a probe's reads.

import Mali
import Testing

@Test func theSky1sGPUReadsAsAG720() {
  // As FreeBSD's panthor read the Orange Pi 6 Plus's (AbyssBSD's notes).
  let id = GPUID(0xC870_0008)
  #expect(id.archMajor == 12 && id.archMinor == 8 && id.archRevision == 7 && id.productMajor == 0)
  #expect(id.versionMajor == 0 && id.versionMinor == 0 && id.versionStatus == 8)
  #expect(id.isPlausible)
  var p = Probe(id: id, l2Features: 0x0813_0306, tilerFeatures: 0x809, memFeatures: 0x301, mmuFeatures: 0x2830,
                asPresent: 0xFF, csfID: 0x0420_0412, shaderPresent: 0x55_0555, tilerPresent: 1, l2Present: 1)
  #expect(p.shaderCores == 10)
  #expect(p.name == "Mali-G720")
  p.features = 0x4
  #expect(p.name == "Mali-G720-Immortalis")
  #expect(p.lines[0] == "Mali-G720-Immortalis, GPU_ID 0xc8700008: architecture 12.8.7, r0p0 status 8")
  #expect(p.lines[1] == "shader cores 10 (0x00550555), tiler 0x00000001, L2 0x00000001")
}

@Test func whatNoGPUReadsAsIsntOne() {
  #expect(!GPUID(0).isPlausible)
  #expect(!GPUID(UInt32.max).isPlausible)
  #expect(!GPUID(0x6000_0000).isPlausible)  // Bifrost, before CSF
  #expect(Probe(id: GPUID(0xC871_0000), shaderPresent: 0x3).name == "Mali-G620")
  #expect(Probe(id: GPUID(0xF000_0000)).name == "an unknown Mali")
}
