import CroiRuntime
import Synchronization

// LibcSuite.c: what only C can do (variadic calls, `_Thread_local`).
@_extern(c, "libc_suite_format") func libcSuiteFormat(_ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32
@_extern(c, "libc_suite_truncated") func libcSuiteTruncated(_ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int32
@_extern(c, "libc_suite_long_double") func libcSuiteLongDouble(_ buffer: UnsafeMutablePointer<CChar>, _ size: Int)
    -> Int32
@_extern(c, "libc_suite_tls_image") func libcSuiteTlsImage() -> Int32
@_extern(c, "libc_suite_tls_mark") func libcSuiteTlsMark()
@_extern(c, "libc_suite_tls_marked") func libcSuiteTlsMarked() -> Int32
@_extern(c, "libc_suite_tls_thread") func libcSuiteTlsThread(_ arg: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

/// The libc natively (system/libc, V2): its functions under their C
/// names, as C and the toolchains' runtimes call them; printf's family and
/// long double through C (LibcSuite.c); its pthreads over the floor's
/// threads and futexes (after todhchai's pthread-test.c); and ELF TLS.
/// Correctness, function by function, is the hosted LibCTests' and
/// PThreadTests' (compared with glibc's); this checks the native build:
/// the exports, the C ABI, each arch's long double, threads and TLS.
enum LibcSuite {
    static func run() {
        strings()
        conversions()
        formatting()
        threads()
        locks()
        keysAndExits()
        timeouts()
        tls()
        print("swift: libc passed")
    }

    /// A C string's bytes equal `text`'s.
    static func same(_ c: UnsafePointer<CChar>, _ text: StaticString) -> Bool {
        guard unsafe strlen(c) == text.utf8CodeUnitCount else { return false }
        return unsafe memcmp(c, text.utf8Start, text.utf8CodeUnitCount) == 0
    }

    static func cString(_ text: StaticString) -> UnsafePointer<CChar> {
        unsafe UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    static func strings() {
        check(unsafe strlen(cString("croi\0")) == 4, "strlen")
        check(unsafe strcmp(cString("abc\0"), cString("abd\0")) < 0, "strcmp")
        check(unsafe strncasecmp(cString("VECTRA\0"), cString("vectraos\0"), 6) == 0, "strncasecmp")
        check(unsafe strchr(cString("a/b/c\0"), 0x2F) == cString("a/b/c\0") + 1, "strchr")
        let b = unsafe UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { unsafe b.deallocate() }
        _ = unsafe memset(b, 0x55, 64)
        _ = unsafe memset(b, 0, 64)
        var zeroed = true
        for i in 0..<64 where unsafe b[i] != 0 { zeroed = false }
        check(zeroed, "memset")
        _ = unsafe memcpy(b, cString("overlap\0"), 8)
        _ = unsafe memmove(b + 2, b, 8)
        check(unsafe same(b, "ovoverlap"), "memmove overlapping")
        check(unsafe strerror_r(EINVAL, b, 64) == 0 && b[0] != 0, "strerror_r")
        check(isalpha(0x41) != 0 && isdigit(0x41) == 0 && toupper(0x61) == 0x41, "ctype")
    }

    static func conversions() {
        var end: UnsafeMutablePointer<CChar>? = nil
        let text = unsafe cString("  -0x7fz\0")
        check(unsafe strtol(text, &end, 0) == -127 && end == UnsafeMutablePointer(mutating: text) + 7,
              "strtol: base from the prefix, the end")
        check(unsafe strtoull(cString("0b1011\0"), nil, 0) == 11, "strtoull: C23's 0b")
        check(unsafe strtod(cString("0x1.8p1\0"), nil) == 3, "strtod: hex")
        check(unsafe strtod(cString("1e400\0"), nil) == .infinity, "strtod: overflow")
        check(unsafe strtod(cString("0.1\0"), nil) == 0.1, "strtod: correctly rounded")
        check(sqrt(2.0) * sqrt(2.0) - 2 < 1e-15 && floor(-1.5) == -2 && fmod(7, 3) == 1, "libm")
        let values = unsafe UnsafeMutablePointer<Int32>.allocate(capacity: 6)
        defer { unsafe values.deallocate() }
        let unsorted: InlineArray<6, Int32> = [5, -3, 9, 0, 2, -8]
        for i in 0..<6 { unsafe values[i] = unsorted[i] }
        unsafe qsort(values, 6, 4) { a, b in
            let x = unsafe a!.load(as: Int32.self), y = unsafe b!.load(as: Int32.self)
            return x < y ? -1 : x > y ? 1 : 0
        }
        check(unsafe values[0] == -8 && values[1] == -3 && values[5] == 9, "qsort")
    }

    static func formatting() {
        let b = unsafe UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { unsafe b.deallocate() }
        let n = unsafe libcSuiteFormat(b, 64)
        check(unsafe Int(n) == strlen(b) && same(b, "-42|   ab|ff  |3.142|1.000000e-300|z|-9007199254740993|%"),
              "snprintf: integers, strings, widths, floats, %%")
        check(unsafe libcSuiteTruncated(b, 6) == 15 && same(b, "trunc"), "snprintf: truncated, the length it wanted")
        _ = unsafe libcSuiteLongDouble(b, 64)
        #if arch(x86_64)
        check(unsafe same(b, "0.1000000000000000000013553"), "long double: x87's")
        #else
        check(unsafe same(b, "0.1"), "long double: binary128's")
        #endif
    }

    typealias Body = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    /// Starts `n` threads running `body`, then joins them.
    static func spawn(_ n: Int, _ body: Body) {
        var threads = InlineArray<8, pthread_t>(repeating: 0)
        for i in 0..<n { check(unsafe pthread_create(&threads[i], nil, body, nil) == 0, "pthread_create") }
        for i in 0..<n { check(unsafe pthread_join(threads[i], nil) == 0, "pthread_join") }
    }

    /// Results through join, and a contended mutex.
    static func threads() {
        var threads = InlineArray<8, pthread_t>(repeating: 0)
        for i in 0..<8 {
            check(unsafe pthread_create(&threads[i], nil, { arg in unsafe arg! + 1 },
                                        UnsafeMutableRawPointer(bitPattern: (i + 1) * 16)) == 0, "pthread_create")
        }
        for i in 0..<8 {
            var result: UnsafeMutableRawPointer? = nil
            check(unsafe pthread_join(threads[i], &result) == 0 && result == UnsafeMutableRawPointer(bitPattern: (i + 1) * 16 + 1),
                  "join's result")
        }
        check(pthread_join(pthread_self(), nil) == EDEADLK, "joining oneself")
        unsafe spawn(8) { _ in
            for _ in 0..<20000 {
                unsafe pthread_mutex_lock(&shared.pointee.mutex)
                unsafe shared.pointee.counter += 1
                unsafe pthread_mutex_unlock(&shared.pointee.mutex)
            }
            return nil
        }
        check(unsafe shared.pointee.counter == 160_000, "a mutex's counter")
    }

    /// A condition handing items over, a read-write lock, once.
    static func locks() {
        var producers = InlineArray<4, pthread_t>(repeating: 0), consumers = InlineArray<4, pthread_t>(repeating: 0)
        for i in 0..<4 {
            _ = unsafe pthread_create(&producers[i], nil, { _ in
                for _ in 0..<items {
                    unsafe pthread_mutex_lock(&shared.pointee.mutex)
                    unsafe shared.pointee.queue += 1
                    unsafe pthread_cond_signal(&shared.pointee.cond)
                    unsafe pthread_mutex_unlock(&shared.pointee.mutex)
                }
                return nil
            }, nil)
            _ = unsafe pthread_create(&consumers[i], nil, { _ in
                for _ in 0..<items {
                    unsafe pthread_mutex_lock(&shared.pointee.mutex)
                    while unsafe shared.pointee.queue == 0 {
                        unsafe pthread_cond_wait(&shared.pointee.cond, &shared.pointee.mutex)
                    }
                    unsafe shared.pointee.queue -= 1
                    unsafe shared.pointee.taken += 1
                    unsafe pthread_mutex_unlock(&shared.pointee.mutex)
                }
                return nil
            }, nil)
        }
        for i in 0..<4 {
            _ = pthread_join(producers[i], nil)
            _ = pthread_join(consumers[i], nil)
        }
        check(unsafe shared.pointee.taken == 4 * items && shared.pointee.queue == 0, "a condition's items")

        unsafe spawn(8) { _ in
            for i in 0..<2000 {
                if i % 4 == 0 {
                    unsafe pthread_rwlock_wrlock(&shared.pointee.rwlock)
                    unsafe shared.pointee.writers += 1
                    if unsafe shared.pointee.writers != 1 || readers.load(ordering: .sequentiallyConsistent) != 0 {
                        bad.add(1, ordering: .relaxed)
                    }
                    unsafe shared.pointee.writers -= 1
                } else {
                    unsafe pthread_rwlock_rdlock(&shared.pointee.rwlock)
                    readers.add(1, ordering: .sequentiallyConsistent)
                    if unsafe shared.pointee.writers != 0 { bad.add(1, ordering: .relaxed) }
                    readers.subtract(1, ordering: .sequentiallyConsistent)
                }
                unsafe pthread_rwlock_unlock(&shared.pointee.rwlock)
            }
            return nil
        }
        check(bad.load(ordering: .relaxed) == 0, "a read-write lock")

        unsafe spawn(8) { _ in
            unsafe pthread_once(&shared.pointee.once) { onceRuns.add(1, ordering: .relaxed) }
            return nil
        }
        check(onceRuns.load(ordering: .relaxed) == 1, "once")
    }

    /// A key's destructor runs at pthread_exit, deep in a call, and at a
    /// detached thread's end.
    static func keysAndExits() {
        check(unsafe pthread_key_create(&shared.pointee.key) { value in
            if unsafe value != nil { destroyed.add(1, ordering: .relaxed) }
        } == 0, "a key")
        let exits: Body = { _ in
            unsafe pthread_setspecific(shared.pointee.key, UnsafeRawPointer(bitPattern: 1))
            deeper()
        }
        var thread: pthread_t = 0
        var result: UnsafeMutableRawPointer? = nil
        _ = unsafe pthread_create(&thread, nil, exits, nil)
        check(unsafe pthread_join(thread, &result) == 0 && result == UnsafeMutableRawPointer(bitPattern: 0x77)
                  && destroyed.load(ordering: .relaxed) == 1, "pthread_exit and a destructor")
        var attributes = pthread_attr_t()
        _ = unsafe pthread_attr_init(&attributes)
        _ = unsafe pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED)
        check(unsafe pthread_create(&thread, &attributes, exits, nil) == 0, "a detached thread")
        let deadline = td_monotonic() + 5_000_000_000
        while destroyed.load(ordering: .relaxed) < 2 && td_monotonic() < deadline { td_sleep(td_monotonic() + 1_000_000) }
        check(destroyed.load(ordering: .relaxed) == 2, "a detached thread's end")
    }


    /// An error-checking mutex refuses a relock; a timed wait times out;
    /// a held mutex refuses trylock.
    static func timeouts() {
        var mutexAttributes = pthread_mutexattr_t()
        _ = unsafe pthread_mutexattr_init(&mutexAttributes)
        _ = unsafe pthread_mutexattr_settype(&mutexAttributes, PTHREAD_MUTEX_ERRORCHECK)
        var mutex = pthread_mutex_t()
        _ = unsafe pthread_mutex_init(&mutex, &mutexAttributes)
        check(unsafe pthread_mutex_lock(&mutex) == 0, "lock")
        check(unsafe pthread_mutex_lock(&mutex) == EDEADLK, "an error-checking relock")
        var condAttributes = pthread_condattr_t()
        _ = unsafe pthread_condattr_init(&condAttributes)
        _ = unsafe pthread_condattr_setclock(&condAttributes, CLOCK_MONOTONIC)
        var cond = pthread_cond_t()
        _ = unsafe pthread_cond_init(&cond, &condAttributes)
        var past = timespec()  // long past
        check(unsafe pthread_cond_timedwait(&cond, &mutex, &past) == ETIMEDOUT, "a timed wait")
        check(unsafe pthread_mutex_unlock(&mutex) == 0, "the mutex back after a timed wait")
        var plain = pthread_mutex_t()
        _ = unsafe pthread_mutex_lock(&plain)
        var other: pthread_t = 0
        var result: UnsafeMutableRawPointer? = nil
        _ = unsafe pthread_create(&other, nil, { arg in
            unsafe UnsafeMutableRawPointer(bitPattern: Int(pthread_mutex_trylock(arg!.assumingMemoryBound(to: pthread_mutex_t.self))))
        }, &plain)
        _ = unsafe pthread_join(other, &result)
        check(unsafe result == UnsafeMutableRawPointer(bitPattern: Int(EBUSY)), "trylock of a held mutex")
        _ = unsafe pthread_mutex_unlock(&plain)
    }

    /// ELF TLS through C: each thread starts with the program's image and
    /// keeps its own (errno included); the main thread's is untouched.
    static func tls() {
        check(unsafe libcSuiteTlsImage() != 0, "the main thread's TLS image")
        unsafe libcSuiteTlsMark()
        var threads = InlineArray<8, pthread_t>(repeating: 0)
        for i in 0..<8 {
            _ = unsafe pthread_create(&threads[i], nil, { arg in unsafe libcSuiteTlsThread(arg) },
                                      UnsafeMutableRawPointer(bitPattern: i + 10))
        }
        for i in 0..<8 {
            var ok: UnsafeMutableRawPointer? = nil
            _ = unsafe pthread_join(threads[i], &ok)
            check(unsafe ok != nil, "a thread's own TLS")
        }
        check(unsafe libcSuiteTlsMarked() != 0, "the main thread's TLS, after")
    }
}

// The threads' shared state, at file scope: a C function pointer can't
// capture, and a closure in a static method that names a static member
// captures the type.
private struct Shared {
    var mutex = pthread_mutex_t()
    var cond = pthread_cond_t()
    var rwlock = pthread_rwlock_t()
    var once = pthread_once_t()
    var key = pthread_key_t()
    var counter = 0
    var queue = 0
    var taken = 0
    var writers = 0
}
nonisolated(unsafe) private let shared: UnsafeMutablePointer<Shared> = {
    let p = unsafe UnsafeMutablePointer<Shared>.allocate(capacity: 1)
    unsafe p.initialize(to: Shared())
    return unsafe p
}()
private let readers = Atomic<Int>(0)
private let bad = Atomic<Int>(0)
private let onceRuns = Atomic<Int>(0)
private let destroyed = Atomic<Int>(0)
private let items = 4000

private func deeper() -> Never { unsafe pthread_exit(UnsafeMutableRawPointer(bitPattern: 0x77)) }
