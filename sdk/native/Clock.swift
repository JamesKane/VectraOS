// SPDX-License-Identifier: BSD-3-Clause

// The clock: the kernel's monotonic clock, which starts at kernel entry.

import Sys

extension Deadline {
  /// Now, on the monotonic clock.
  public static var now: Deadline { Deadline(ns: UInt64(max(0, Sys.Clock.monotonic()))) }
}

/// Sleeps until `deadline`: the thread's port's deadline (D25). The leeway
/// is not passed on.
public func sleep(until deadline: Deadline, leeway: Duration = .zero) {
  Sys.sleep(until: Int64(min(deadline.ns, UInt64(Int64.max))))
}
