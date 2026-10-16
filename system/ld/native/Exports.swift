// SPDX-License-Identifier: BSD-3-Clause

// <dlfcn.h> under its C names, natively (M5k). A handle is a library's
// index plus one; the program's own (dlopen(NULL)) is all ones.

let programHandle = UInt.max

@c(dlopen) public func exportedDlopen(_ file: UnsafePointer<CChar>?, _ mode: Int32) -> UnsafeMutableRawPointer? {
  guard let file = unsafe file else { return unsafe UnsafeMutableRawPointer(bitPattern: programHandle) }
  guard let index = unsafe DynamicLinker.open(String(cString: file)) else { return nil }
  return unsafe UnsafeMutableRawPointer(bitPattern: UInt(index) + 1)
}

@c(dlsym) public func exportedDlsym(_ handle: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>)
  -> UnsafeMutableRawPointer?
{
  let h = UInt(bitPattern: handle)
  let index: Int? = h == 0 || h == programHandle ? nil : Int(h - 1)
  return unsafe DynamicLinker.symbol(String(cString: name), in: index).flatMap { unsafe UnsafeMutableRawPointer(bitPattern: $0) }
}

@c(dlclose) public func exportedDlclose(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  let h = UInt(bitPattern: handle)
  if h == programHandle { return 0 }
  return h != 0 && DynamicLinker.close(Int(h - 1)) ? 0 : -1
}

/// dlerror's message lives here until the next call.
nonisolated(unsafe) var dlerrorBuffer = InlineArray<256, CChar>(repeating: 0)

@c(dlerror) public func exportedDlerror() -> UnsafeMutablePointer<CChar>? {
  guard let message = DynamicLinker.takeFailure() else { return nil }
  return withUnsafeMutablePointer(to: &dlerrorBuffer) { p in
    let b = unsafe UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
    var n = 0
    for c in message.utf8 where n < 255 {
      unsafe b[n] = CChar(bitPattern: c)
      n += 1
    }
    unsafe b[n] = 0
    return unsafe b
  }
}
