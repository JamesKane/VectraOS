// SPDX-License-Identifier: BSD-3-Clause

// The pages a USB host controller shares with its driver (xhci's rings
// and contexts, ehci's schedules and transfer descriptors): 4 KiB each,
// through its BTI, given back when a device leaves and handed to the
// next.

import DriverHost
import Sys

/// A page the controller reaches: its address here and the controller's.
struct Page {
  let address: UInt
  let bus: UInt64

  func load32(_ o: Int) -> UInt32 { unsafe UnsafeRawPointer(bitPattern: address + UInt(o))!.load(as: UInt32.self) }
  func load64(_ o: Int) -> UInt64 { unsafe UnsafeRawPointer(bitPattern: address + UInt(o))!.load(as: UInt64.self) }
  func store32(_ o: Int, _ v: UInt32) {
    unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(o))!.storeBytes(of: v, as: UInt32.self)
  }
  func store64(_ o: Int, _ v: UInt64) {
    unsafe UnsafeMutableRawPointer(bitPattern: address + UInt(o))!.storeBytes(of: v, as: UInt64.self)
  }
  func bytes(_ o: Int, _ n: Int) -> [UInt8] {
    let p = unsafe UnsafeRawPointer(bitPattern: address + UInt(o))!
    return (0..<n).map { unsafe p.load(fromByteOffset: $0, as: UInt8.self) }
  }
  func zero() { unsafe UnsafeMutableRawPointer(bitPattern: address)!.initializeMemory(as: UInt8.self, repeating: 0, count: 4096) }
}

/// Pages handed out and taken back, so a device that leaves gives its
/// pages to the next.
final class Pages {
  let memory: DMAMemory
  var free: [Page] = []
  private(set) var count = 0

  init(_ memory: DMAMemory) { self.memory = memory }

  func take() throws(Status) -> Page {
    if let p = free.popLast() {
      p.zero()
      return p
    }
    let a = try unsafe memory.allocate(bytes: 4096)
    count += 1
    return unsafe Page(address: UInt(bitPattern: a.pointer), bus: a.bus)
  }

  func give(_ p: Page) { free.append(p) }
}
