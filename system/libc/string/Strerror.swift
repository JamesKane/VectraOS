// SPDX-License-Identifier: BSD-3-Clause

// strerror (C23 §7.26.6.3) and POSIX's strerror_r, the XSI form (M6d): the
// message for each number <errno.h> defines, in the words of POSIX's XBD
// <errno.h> descriptions, and "Unknown error N" for the rest.

/// The message for `errnum`, or nil if <errno.h> doesn't define it.
func errorMessage(_ errnum: Int32) -> StaticString? {
  switch errnum {
  case 0: "Success"
  case 1: "Operation not permitted"
  case 2: "No such file or directory"
  case 3: "No such process"
  case 4: "Interrupted function call"
  case 5: "Input/output error"
  case 6: "No such device or address"
  case 7: "Argument list too long"
  case 8: "Executable file format error"
  case 9: "Bad file descriptor"
  case 10: "No child processes"
  case 11: "Resource temporarily unavailable"
  case 12: "Not enough space"
  case 13: "Permission denied"
  case 14: "Bad address"
  case 16: "Resource busy"
  case 17: "File exists"
  case 18: "Cross-device link"
  case 19: "No such device"
  case 20: "Not a directory"
  case 21: "Is a directory"
  case 22: "Invalid argument"
  case 23: "Too many files open in system"
  case 24: "Too many open files"
  case 25: "Inappropriate I/O control operation"
  case 26: "Text file busy"
  case 27: "File too large"
  case 28: "No space left on device"
  case 29: "Invalid seek"
  case 30: "Read-only file system"
  case 31: "Too many links"
  case 32: "Broken pipe"
  case 33: "Mathematics argument out of domain of function"
  case 34: "Result too large"
  case 35: "Resource deadlock would occur"
  case 36: "Filename too long"
  case 37: "No locks available"
  case 38: "Function not implemented"
  case 39: "Directory not empty"
  case 40: "Too many levels of symbolic links"
  case 42: "No message of the desired type"
  case 43: "Identifier removed"
  case 60: "Not a STREAM"
  case 61: "No message available"
  case 62: "Stream ioctl() timeout"
  case 63: "No STREAM resources"
  case 67: "Reserved"
  case 71: "Protocol error"
  case 72: "Reserved"
  case 74: "Bad message"
  case 75: "Value too large to be stored in data type"
  case 84: "Illegal byte sequence"
  case 88: "Not a socket"
  case 89: "Destination address required"
  case 90: "Message too large"
  case 91: "Protocol wrong type for socket"
  case 92: "Protocol not available"
  case 93: "Protocol not supported"
  case 95: "Not supported"
  case 97: "Address family not supported"
  case 98: "Address in use"
  case 99: "Address not available"
  case 100: "Network is down"
  case 101: "Network unreachable"
  case 102: "Connection aborted by network"
  case 103: "Connection aborted"
  case 104: "Connection reset"
  case 105: "No buffer space available"
  case 106: "Socket is connected"
  case 107: "The socket is not connected"
  case 110: "Connection timed out"
  case 111: "Connection refused"
  case 113: "Host is unreachable"
  case 114: "Connection already in progress"
  case 115: "Operation in progress"
  case 116: "Reserved"
  case 122: "Reserved"
  case 125: "Operation canceled"
  case 130: "Previous owner died"
  case 131: "State not recoverable"
  default: nil
  }
}

/// Writes `errnum`'s message into `buffer` of `size` bytes (truncated,
/// terminated) and returns 0, ERANGE if it didn't fit, or EINVAL (with
/// "Unknown error N" written, as far as it fits) for an unknown number.
public func strerror_r(_ errnum: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int) -> Int32 {
  var text = InlineArray<64, UInt8>(repeating: 0)  // the longest message, or "Unknown error -N"
  var n = 0
  var result: Int32 = 0
  if let message = errorMessage(errnum) {
    for i in 0..<message.utf8CodeUnitCount { text[i] = unsafe message.utf8Start[i] }
    n = message.utf8CodeUnitCount
  } else {
    let prefix: StaticString = "Unknown error "
    for i in 0..<prefix.utf8CodeUnitCount { text[i] = unsafe prefix.utf8Start[i] }
    n = prefix.utf8CodeUnitCount
    if errnum < 0 {
      text[n] = 0x2D
      n += 1
    }
    var v = errnum < 0 ? 0 &- UInt32(bitPattern: errnum) : UInt32(errnum)
    var digits = InlineArray<10, UInt8>(repeating: 0)
    var k = 0
    repeat {
      digits[k] = 0x30 + UInt8(v % 10)
      v /= 10
      k += 1
    } while v > 0
    while k > 0 {
      k -= 1
      text[n] = digits[k]
      n += 1
    }
    result = Errno.invalid
  }
  guard let buffer = unsafe buffer, size > 0 else { return result != 0 ? result : Errno.range }
  let fits = n < size
  let copied = fits ? n : size - 1
  for i in 0..<copied { unsafe buffer[i] = CChar(bitPattern: text[i]) }
  unsafe buffer[copied] = 0
  return result != 0 || fits ? result : Errno.range
}
