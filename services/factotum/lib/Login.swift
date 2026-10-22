// SPDX-License-Identifier: BSD-3-Clause

// The lock screen's check (D118): D80's one user is the login key's,
// `proto=pass role=server service=login user=NAME !password=SECRET`, and
// what is typed on Radharc's lock is compared with its password here, so
// the password never leaves factotum.

extension FactotumState {
  /// The login key's pattern.
  public static let loginPattern = "proto=pass role=server service=login"

  /// The one user's name, if there is a login key.
  public var loginUser: String? {
    guard let p = try? KeyPattern(Self.loginPattern) else { return nil }
    let user = try? locked { () throws(AuthFailure) -> String? in factotum.store.matching(p).first?["user"] }
    return user ?? nil
  }

  /// Whether `typed` is the login key's password.
  public func checkLogin(_ typed: String) -> Bool {
    guard let p = try? KeyPattern(Self.loginPattern) else { return false }
    let password = (try? locked { () throws(AuthFailure) -> [UInt8]? in
      factotum.store.matching(p).first?["password"].map { Array($0.utf8) }
    }) ?? nil
    guard let password else { return false }
    return samePassword(Array(typed.utf8), password)
  }
}

/// `a` and `b` equal, in a time that depends only on their lengths.
public func samePassword(_ a: [UInt8], _ b: [UInt8]) -> Bool {
  var diff = UInt8(a.count == b.count ? 0 : 1)
  for i in 0..<max(a.count, b.count) {
    diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
  }
  return diff == 0
}
