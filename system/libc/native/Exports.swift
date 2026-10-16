// SPDX-License-Identifier: BSD-3-Clause

// The functions under their C names, for native processes (M3): the Swift
// runtime and compiled code call memcpy and friends by symbol. Built only
// for croi's targets, with LLVM's loop-idiom recognition off (CMakeLists),
// so the loops behind these can't become calls to themselves. The hosted
// build keeps the host's libc.

@c(memcpy) public func exportedMemcpy(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt)
  -> UnsafeMutableRawPointer
{ unsafe memcpy(d, s, n) }

@c(memmove) public func exportedMemmove(_ d: UnsafeMutableRawPointer, _ s: UnsafeRawPointer, _ n: UInt)
  -> UnsafeMutableRawPointer
{ unsafe memmove(d, s, n) }

@c(memset) public func exportedMemset(_ s: UnsafeMutableRawPointer, _ c: Int32, _ n: UInt) -> UnsafeMutableRawPointer {
  unsafe memset(s, c, n)
}

@c(memcmp) public func exportedMemcmp(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ n: UInt) -> Int32 {
  unsafe memcmp(a, b, n)
}

@c(bcmp) public func exportedBcmp(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ n: UInt) -> Int32 {
  unsafe bcmp(a, b, n)
}

@c(memchr) public func exportedMemchr(_ s: UnsafeRawPointer, _ c: Int32, _ n: UInt) -> UnsafeRawPointer? {
  unsafe memchr(s, c, n)
}

@c(strlen) public func exportedStrlen(_ s: UnsafePointer<CChar>) -> UInt { unsafe strlen(s) }

@c(strnlen) public func exportedStrnlen(_ s: UnsafePointer<CChar>, _ n: UInt) -> UInt { unsafe strnlen(s, n) }

@c(strcmp) public func exportedStrcmp(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 {
  unsafe strcmp(a, b)
}

@c(strncmp) public func exportedStrncmp(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>, _ n: UInt) -> Int32 {
  unsafe strncmp(a, b, n)
}

@c(strcasecmp) public func exportedStrcasecmp(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>) -> Int32 {
  unsafe strcasecmp(a, b)
}

@c(strncasecmp) public func exportedStrncasecmp(_ a: UnsafePointer<CChar>, _ b: UnsafePointer<CChar>, _ n: UInt) -> Int32 {
  unsafe strncasecmp(a, b, n)
}

@c(strtol) public func exportedStrtol(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                      _ base: Int32) -> Int
{ unsafe strtol(s, end, base) }

@c(atol) public func exportedAtol(_ s: UnsafePointer<CChar>) -> Int { unsafe atol(s) }

@c(atoi) public func exportedAtoi(_ s: UnsafePointer<CChar>) -> Int32 { unsafe atoi(s) }

// MARK: stdio's formatting and strtod (M6c)

import TDStdioShim

/// printf's arguments from a C va_list (its address), through stdio.c.
@safe struct VaArguments: FormatArguments {
  let ap: UnsafeMutableRawPointer
  mutating func integer(_ size: Int) -> UInt64 { unsafe td_va_integer(ap, Int32(size)) }
  mutating func double() -> Double { unsafe td_va_double(ap) }
  mutating func longDouble() -> FloatValue {
    var words = InlineArray<2, UInt64>(repeating: 0)
    withUnsafeMutablePointer(to: &words) { p in
      unsafe td_va_long_double(ap, UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt64.self))
    }
    #if arch(x86_64)
    return FloatValue(x87: words[0], UInt16(truncatingIfNeeded: words[1]))
    #else
    return FloatValue(binary128: UInt128(words[1]) << 64 | UInt128(words[0]))
    #endif
  }
  mutating func pointer() -> UInt { unsafe UInt(td_va_pointer(ap)) }
  mutating func string() -> UnsafePointer<UInt8>? { unsafe UnsafePointer(bitPattern: UInt(td_va_pointer(ap))) }
}

/// snprintf's sink: the bytes that fit before the NUL.
@safe struct BufferSink: FormatSink {
  let buffer: UnsafeMutablePointer<UInt8>?
  let size: Int
  var n = 0
  mutating func put(_ byte: UInt8) {
    if let buffer = unsafe buffer, n + 1 < size { unsafe buffer[n] = byte }
    n += 1
  }
}

/// A stream's sink: gathered a little, then written to stdout.
struct StreamSink: FormatSink {
  var chunk = InlineArray<128, UInt8>(repeating: 0)
  var n = 0
  mutating func put(_ byte: UInt8) {
    chunk[n] = byte
    n += 1
    if n == 128 { flush() }
  }
  mutating func flush() {
    guard n > 0 else { return }
    withUnsafePointer(to: &chunk) { p in unsafe td_stdout_write(UnsafeRawPointer(p), n) }
    n = 0
  }
}

@c public func td_format_buffer(_ buffer: UnsafeMutablePointer<CChar>?, _ size: Int, _ fmt: UnsafePointer<CChar>,
                                _ ap: UnsafeMutableRawPointer) -> Int32
{
  var args = unsafe VaArguments(ap: ap)
  var sink = unsafe BufferSink(buffer: UnsafeMutableRawPointer(buffer)?.assumingMemoryBound(to: UInt8.self), size: size)
  let n = unsafe format(UnsafeRawPointer(fmt).assumingMemoryBound(to: UInt8.self), &args, &sink)
  if let buffer = unsafe buffer, size > 0 { unsafe buffer[min(sink.n, size - 1)] = 0 }
  return Int32(truncatingIfNeeded: n)
}

@c public func td_format_stream(_ fd: Int32, _ fmt: UnsafePointer<CChar>, _ ap: UnsafeMutableRawPointer) -> Int32 {
  var args = unsafe VaArguments(ap: ap)
  var sink = StreamSink()
  let n = unsafe format(UnsafeRawPointer(fmt).assumingMemoryBound(to: UInt8.self), &args, &sink)
  sink.flush()
  return Int32(truncatingIfNeeded: n)
}

@c(strtod) public func exportedStrtod(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
  -> Double
{ unsafe strtod(s, end) }

@c(strtof) public func exportedStrtof(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
  -> Float
{ unsafe strtof(s, end) }

@c(atof) public func exportedAtof(_ s: UnsafePointer<CChar>) -> Double { unsafe atof(s) }

/// strtold's bits, for native/stdlib.c's strtold (M6d).
@c public func td_strtold(_ s: UnsafePointer<CChar>, _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                          _ out: UnsafeMutablePointer<UInt64>)
{
  let bits = unsafe strtoldBits(s, end)
  unsafe out[0] = UInt64(truncatingIfNeeded: bits)
  unsafe out[1] = UInt64(truncatingIfNeeded: bits >> 64)
}

// MARK: The rest of <string.h>, <stdlib.h>, <inttypes.h> and <ctype.h> (M6d)

@c(strchr) public func exportedStrchr(_ s: UnsafePointer<CChar>, _ c: Int32) -> UnsafePointer<CChar>? {
  unsafe strchr(s, c)
}
@c(strrchr) public func exportedStrrchr(_ s: UnsafePointer<CChar>, _ c: Int32) -> UnsafePointer<CChar>? {
  unsafe strrchr(s, c)
}
@c(strcat) public func exportedStrcat(_ d: UnsafeMutablePointer<CChar>, _ s: UnsafePointer<CChar>)
  -> UnsafeMutablePointer<CChar>
{ unsafe strcat(d, s) }
@c(strncpy) public func exportedStrncpy(_ d: UnsafeMutablePointer<CChar>, _ s: UnsafePointer<CChar>, _ n: UInt)
  -> UnsafeMutablePointer<CChar>
{ unsafe strncpy(d, s, n) }
@c(strdup) public func exportedStrdup(_ s: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? { unsafe strdup(s) }
@c(strndup) public func exportedStrndup(_ s: UnsafePointer<CChar>, _ n: UInt) -> UnsafeMutablePointer<CChar>? {
  unsafe strndup(s, n)
}
@c(strerror_r) public func exportedStrerror_r(_ errnum: Int32, _ buffer: UnsafeMutablePointer<CChar>?, _ size: Int)
  -> Int32
{ unsafe strerror_r(errnum, buffer, size) }

@c(strtoll) public func exportedStrtoll(_ s: UnsafePointer<CChar>,
                                        _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ base: Int32) -> Int64
{ unsafe strtoll(s, end, base) }
@c(strtoul) public func exportedStrtoul(_ s: UnsafePointer<CChar>,
                                        _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ base: Int32) -> UInt
{ unsafe strtoul(s, end, base) }
@c(strtoull) public func exportedStrtoull(_ s: UnsafePointer<CChar>,
                                          _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ base: Int32)
  -> UInt64
{ unsafe strtoull(s, end, base) }
@c(strtoimax) public func exportedStrtoimax(_ s: UnsafePointer<CChar>,
                                            _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ base: Int32)
  -> Int64
{ unsafe strtoll(s, end, base) }
@c(strtoumax) public func exportedStrtoumax(_ s: UnsafePointer<CChar>,
                                            _ end: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ base: Int32)
  -> UInt64
{ unsafe strtoull(s, end, base) }
@c(atoll) public func exportedAtoll(_ s: UnsafePointer<CChar>) -> Int64 { unsafe atoll(s) }
@c(abs) public func exportedAbs(_ j: Int32) -> Int32 { j < 0 ? 0 &- j : j }
@c(labs) public func exportedLabs(_ j: Int) -> Int { labs(j) }
@c(llabs) public func exportedLlabs(_ j: Int64) -> Int64 { Int64(labs(Int(j))) }
@c(imaxabs) public func exportedImaxabs(_ j: Int64) -> Int64 { Int64(labs(Int(j))) }
@c(qsort) public func exportedQsort(_ base: UnsafeMutableRawPointer?, _ n: Int, _ size: Int, _ compare: Compare) {
  unsafe qsort(base, n, size, compare)
}
@c(bsearch) public func exportedBsearch(_ key: UnsafeRawPointer?, _ base: UnsafeRawPointer?, _ n: Int, _ size: Int,
                                        _ compare: Compare) -> UnsafeRawPointer?
{ unsafe bsearch(key, base, n, size, compare) }

@c(isalnum) public func exportedIsalnum(_ c: Int32) -> Int32 { isalnum(c) }
@c(isalpha) public func exportedIsalpha(_ c: Int32) -> Int32 { isalpha(c) }
@c(isblank) public func exportedIsblank(_ c: Int32) -> Int32 { isblank(c) }
@c(iscntrl) public func exportedIscntrl(_ c: Int32) -> Int32 { iscntrl(c) }
@c(isdigit) public func exportedIsdigit(_ c: Int32) -> Int32 { isdigit(c) }
@c(isgraph) public func exportedIsgraph(_ c: Int32) -> Int32 { isgraph(c) }
@c(islower) public func exportedIslower(_ c: Int32) -> Int32 { islower(c) }
@c(isprint) public func exportedIsprint(_ c: Int32) -> Int32 { isprint(c) }
@c(ispunct) public func exportedIspunct(_ c: Int32) -> Int32 { ispunct(c) }
@c(isspace) public func exportedIsspace(_ c: Int32) -> Int32 { isspace(c) }
@c(isupper) public func exportedIsupper(_ c: Int32) -> Int32 { isupper(c) }
@c(isxdigit) public func exportedIsxdigit(_ c: Int32) -> Int32 { isxdigit(c) }
@c(tolower) public func exportedTolower(_ c: Int32) -> Int32 { tolower(c) }
@c(toupper) public func exportedToupper(_ c: Int32) -> Int32 { toupper(c) }

// MARK: <math.h> (M6c)

@c(floor) public func exported_floor(_ x: Double) -> Double { floor(x) }
@c(ceil) public func exported_ceil(_ x: Double) -> Double { ceil(x) }
@c(trunc) public func exported_trunc(_ x: Double) -> Double { trunc(x) }
@c(round) public func exported_round(_ x: Double) -> Double { round(x) }
@c(roundeven) public func exported_roundeven(_ x: Double) -> Double { roundeven(x) }
@c(rint) public func exported_rint(_ x: Double) -> Double { rint(x) }
@c(nearbyint) public func exported_nearbyint(_ x: Double) -> Double { nearbyint(x) }
@c(fabs) public func exported_fabs(_ x: Double) -> Double { fabs(x) }
@c(sqrt) public func exported_sqrt(_ x: Double) -> Double { sqrt(x) }
@c(exp) public func exported_exp(_ x: Double) -> Double { exp(x) }
@c(exp2) public func exported_exp2(_ x: Double) -> Double { exp2(x) }
@c(log) public func exported_log(_ x: Double) -> Double { log(x) }
@c(log2) public func exported_log2(_ x: Double) -> Double { log2(x) }
@c(log10) public func exported_log10(_ x: Double) -> Double { log10(x) }
@c(sin) public func exported_sin(_ x: Double) -> Double { sin(x) }
@c(cos) public func exported_cos(_ x: Double) -> Double { cos(x) }
@c(floorf) public func exported_floorf(_ x: Float) -> Float { floorf(x) }
@c(ceilf) public func exported_ceilf(_ x: Float) -> Float { ceilf(x) }
@c(truncf) public func exported_truncf(_ x: Float) -> Float { truncf(x) }
@c(roundf) public func exported_roundf(_ x: Float) -> Float { roundf(x) }
@c(roundevenf) public func exported_roundevenf(_ x: Float) -> Float { roundevenf(x) }
@c(rintf) public func exported_rintf(_ x: Float) -> Float { rintf(x) }
@c(nearbyintf) public func exported_nearbyintf(_ x: Float) -> Float { nearbyintf(x) }
@c(fabsf) public func exported_fabsf(_ x: Float) -> Float { fabsf(x) }
@c(sqrtf) public func exported_sqrtf(_ x: Float) -> Float { sqrtf(x) }
@c(expf) public func exported_expf(_ x: Float) -> Float { expf(x) }
@c(exp2f) public func exported_exp2f(_ x: Float) -> Float { exp2f(x) }
@c(logf) public func exported_logf(_ x: Float) -> Float { logf(x) }
@c(log2f) public func exported_log2f(_ x: Float) -> Float { log2f(x) }
@c(log10f) public func exported_log10f(_ x: Float) -> Float { log10f(x) }
@c(sinf) public func exported_sinf(_ x: Float) -> Float { sinf(x) }
@c(cosf) public func exported_cosf(_ x: Float) -> Float { cosf(x) }
@c(copysign) public func exported_copysign(_ x: Double, _ y: Double) -> Double { copysign(x, y) }
@c(fmod) public func exported_fmod(_ x: Double, _ y: Double) -> Double { fmod(x, y) }
@c(remainder) public func exported_remainder(_ x: Double, _ y: Double) -> Double { remainder(x, y) }
@c(copysignf) public func exported_copysignf(_ x: Float, _ y: Float) -> Float { copysignf(x, y) }
@c(fmodf) public func exported_fmodf(_ x: Float, _ y: Float) -> Float { fmodf(x, y) }
@c(remainderf) public func exported_remainderf(_ x: Float, _ y: Float) -> Float { remainderf(x, y) }
@c(fma) public func exported_fma(_ x: Double, _ y: Double, _ z: Double) -> Double { fma(x, y, z) }
@c(fmaf) public func exported_fmaf(_ x: Float, _ y: Float, _ z: Float) -> Float { fmaf(x, y, z) }
@c(ldexp) public func exported_ldexp(_ x: Double, _ n: Int32) -> Double { ldexp(x, n) }
@c(scalbn) public func exported_scalbn(_ x: Double, _ n: Int32) -> Double { ldexp(x, n) }
@c(frexp) public func exported_frexp(_ x: Double, _ e: UnsafeMutablePointer<Int32>) -> Double { unsafe frexp(x, e) }
@c(modf) public func exported_modf(_ x: Double, _ i: UnsafeMutablePointer<Double>) -> Double { unsafe modf(x, i) }
