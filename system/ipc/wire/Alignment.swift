// SPDX-License-Identifier: BSD-3-Clause

/// The wire format's alignment: every object in a message starts on an
/// 8-byte boundary (architecture §4, after FIDL's encoding rules).
public let wireAlignment = 8

/// `size` rounded up to the wire alignment.
public func wireAligned(_ size: Int) -> Int {
  (size + wireAlignment - 1) & ~(wireAlignment - 1)
}
