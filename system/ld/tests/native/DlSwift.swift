// SPDX-License-Identifier: BSD-3-Clause

// An Embedded Swift shared object for dl-test (M5k): classes, arrays and a
// global initialized lazily, a Sys lock and the clock. Embedded Swift
// compiles what it uses of Sys into it; the futexes, the clock and the
// heap are the program's (the floor's, exported).

import Sys

final class Counter {
  var total = 0
}

let lock = Lock()
let squares = (0..<10).map { $0 * $0 }

@c public func dl_swift_sum(_ n: Int) -> Int {
  let c = Counter()
  var values: [Int] = []
  for i in 0..<n { values.append(i) }
  lock.withLock { for v in values { c.total += v } }
  return c.total + squares[3] + (Clock.monotonic() > 0 ? 1 : 0)
}
