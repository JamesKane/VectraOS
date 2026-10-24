// SPDX-License-Identifier: BSD-3-Clause

// USB's descriptors as bin/xhci parses them, and the endpoint and route
// rules it gives the controller (xhci(3)).

import Testing
@testable import USB

// A keyboard with a second interface, a boot mouse, as a wireless
// receiver has them: each interface's HID descriptor (type 0x21) between
// it and its endpoint, an alternate setting skipped.
let receiver: [UInt8] = [
  9, 2, 66, 0, 2, 1, 0, 0xA0, 50,  // configuration 1, 66 bytes, 2 interfaces
  9, 4, 0, 0, 1, 3, 1, 1, 0,  // interface 0: HID, boot, keyboard
  9, 0x21, 0x11, 1, 0, 1, 0x22, 63, 0,  // HID
  7, 5, 0x81, 3, 8, 0, 10,  // endpoint 1 IN, interrupt, 8 bytes, 10 ms
  9, 4, 1, 0, 1, 3, 1, 2, 0,  // interface 1: HID, boot, mouse
  9, 0x21, 0x11, 1, 0, 1, 0x22, 52, 0,
  7, 5, 0x82, 3, 4, 0, 1,  // endpoint 2 IN, 4 bytes, 1 ms
  9, 4, 1, 1, 1, 3, 0, 0, 0,  // interface 1, alternate 1: left out
]

@Test func configurationsListInterfacesAndEndpoints() {
  let head = Configuration(Array(receiver[0..<9]))
  #expect(head?.totalLength == 66 && head?.value == 1 && head?.interfaces.isEmpty == true)
  guard let c = Configuration(receiver) else { Issue.record("not parsed"); return }
  #expect(c.interfaces.count == 2)
  #expect(c.interfaces[0].isBootKeyboard && c.interfaces[1].isBootMouse)
  let k = c.interfaces[0].interruptIn, m = c.interfaces[1].interruptIn
  #expect(k?.contextIndex == 3 && k?.maxPacket == 8 && k?.interval == 10)
  #expect(m?.contextIndex == 5 && m?.isIn == true)
  #expect(Configuration([9, 1, 9, 0, 1, 1, 0, 0, 0]) == nil)  // a device descriptor
  // A truncated one keeps what was whole.
  #expect(Configuration(Array(receiver[0..<36]))?.interfaces.first?.endpoints.count == 1)
}

@Test func deviceDescriptorsGivePacketSizes() {
  let d = DeviceDescriptor([18, 1, 0x00, 0x02, 0, 0, 0, 64, 0x1C, 0x1B, 0x33, 0x01, 0, 1, 1, 2, 0, 1])
  #expect(d?.vendor == 0x1B1C && d?.product == 0x0133 && d?.packetSize0 == 64 && d?.configurations == 1)
  let ss = DeviceDescriptor([18, 1, 0x20, 0x03, 9, 0, 3, 9])  // a USB 3 hub's first 8 bytes
  #expect(ss?.packetSize0 == 512 && ss?.deviceClass == 9 && ss?.vendor == 0)
  #expect(DeviceDescriptor([18, 2, 0, 2, 0, 0, 0]) == nil)
}

@Test func setupPacketsAreLittleEndianWords() {
  #expect(SetupPacket.getDescriptor(1, length: 18).word == 0x0012_0000_0100_0680)
  #expect(SetupPacket.setPortFeature(HubPort.reset, port: 3).word == 0x0000_0003_0004_0323)
  #expect(SetupPacket.getPortStatus(1).deviceToHost && !SetupPacket.setConfiguration(1).deviceToHost)
}

@Test func hubDescriptorsGivePortsAndThinkTime() {
  let h = HubDescriptor([9, 0x29, 4, 0x69, 0, 50, 100, 0, 0xFF])
  #expect(h?.ports == 4 && h?.powerOnToGood == 100 && h?.thinkTime == 3)
  #expect(HubDescriptor([9, 0x2A, 4, 0, 0, 10, 0]) != nil && HubDescriptor([9, 0x21, 4, 0, 0, 1, 0]) == nil)
}

// xHCI's intervals: frames for full and low speed, rounded down to powers
// of two, exponents for the rest.
@Test func endpointIntervalsAreXHCIs() {
  func e(_ interval: UInt8, type: UInt8 = 3) -> Endpoint {
    Endpoint(address: 0x81, type: type, maxPacket: 8, extra: 0, interval: interval)
  }
  #expect(EndpointRules.interval(e(1), speed: .full) == 3)  // 1 ms: 8 microframes
  #expect(EndpointRules.interval(e(10), speed: .low) == 6)  // 10 ms: 8 ms
  #expect(EndpointRules.interval(e(255), speed: .full) == 10)  // capped
  #expect(EndpointRules.interval(e(4), speed: .high) == 3 && EndpointRules.interval(e(0), speed: .high) == 0)
  #expect(EndpointRules.type(e(1)) == 7 && EndpointRules.type(e(0, type: 2)) == 6)
  #expect(EndpointRules.type(Endpoint(address: 0x02, type: 2, maxPacket: 512, extra: 0, interval: 0)) == 2)
  #expect(EndpointRules.esitPayload(Endpoint(address: 0x81, type: 3, maxPacket: 1024, extra: 2, interval: 1)) == 3072)
}

// Routes a nibble a tier; full and low speed take the nearest high-speed
// hub's translator, which a full-speed hub below it passes on.
@Test func placementsGiveRoutesAndTranslators() {
  let root = Placement(rootPort: 2)
  let hub = root.below(port: 3, hubSlot: 0, hubSpeed: .superSpeed, speed: .high)
  #expect(hub.route == 0x3 && hub.depth == 1 && hub.ttSlot == 0)
  let keyboard = hub.below(port: 1, hubSlot: 5, hubSpeed: .high, speed: .full)
  #expect(keyboard.route == 0x13 && keyboard.ttSlot == 5 && keyboard.ttPort == 1 && keyboard.rootPort == 2)
  let fsHub = hub.below(port: 4, hubSlot: 5, hubSpeed: .high, speed: .full)
  let mouse = fsHub.below(port: 2, hubSlot: 6, hubSpeed: .full, speed: .low)
  #expect(mouse.route == 0x243 && mouse.ttSlot == 5 && mouse.ttPort == 4)
  #expect(hub.below(port: 20, hubSlot: 5, hubSpeed: .high, speed: .high).route == 0xF3)
}
