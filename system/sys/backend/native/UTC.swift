// SPDX-License-Identifier: BSD-3-Clause

// The UTC page's writer, natively (D48): the launcher makes the page and
// publishes its backstop before any process maps it; from then on the
// time service is its one writer. Readers are every process's floor
// (td_utc_now, under td_utc.h's seqlock).

import TDFloor

@safe public struct UTCPage: ~Copyable {
  let mapping: Mapping

  /// Maps `page` (a VMO of at least a page, writable) to publish to.
  public init(_ page: borrowing Handle) throws(Status) {
    mapping = try VMO.map(page, length: Kernel.pageSize)
  }

  /// A new page, reading `backstop` now (and later the monotonic clock's
  /// advance on it), its error unknown: what UTC says until the time
  /// service sets it.
  public static func create(backstop: Int64) throws(Status) -> Handle {
    let page = try VMO.create(size: Kernel.pageSize)
    try UTCPage(page).publish(utc: backstop, error: .max)
    return page
  }

  /// A copy every process may be given: read and map only.
  public static func readOnly(_ page: borrowing Handle) throws(Status) -> Handle {
    try page.duplicate([.read, .map, .transfer, .duplicate])
  }

  /// UTC is `utc` now, within `error` ns.
  public func publish(utc: Int64, error: UInt64) {
    let now = Clock.monotonic()
    unsafe td_utc_publish(mapping.address.assumingMemoryBound(to: td_utc_page_t.self), utc &- now, error, now)
  }

  /// What the page says: UTC now, and its error.
  public func read() -> (utc: Int64, error: UInt64) {
    var offset: Int64 = 0, error: UInt64 = 0
    unsafe td_utc_read(mapping.address.assumingMemoryBound(to: td_utc_page_t.self), &offset, &error)
    return (Clock.monotonic() &+ offset, error)
  }
}
