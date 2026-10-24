import CHandoff
import Fmt

/// What a boot tests (D125). Nothing unless the command line's `croi.test=`
/// names it, so a plain boot is a production boot. It takes a
/// comma-separated list: `all`; the groups `boot` (kernel_main's checks
/// before the scheduler), `kernel` (the in-kernel self-tests), `programs`
/// (the test programs' modes) and `suites` (every Swift suite); or a
/// suite by its name (`drivers`, `interrupts`, ...).
enum SelfTests {
    /// Any test at all: also the debugging syscalls and test hooks.
    nonisolated(unsafe) private(set) static var enabled = false
    nonisolated(unsafe) private(set) static var boot = false
    nonisolated(unsafe) private(set) static var kernel = false
    nonisolated(unsafe) private(set) static var programs = false

    static func configure() {
        enabled = BootOptions.listed(in: "croi.test=") { _ in true }
        boot = wants("boot")
        kernel = wants("kernel")
        programs = wants("programs")
    }

    /// Whether `croi.test=` names `name`, or `all`.
    static func wants(_ name: StaticString) -> Bool {
        wants(unsafe Span(_unsafeStart: name.utf8Start, count: name.utf8CodeUnitCount))
    }

    static func wants(_ name: Span<UInt8>) -> Bool {
        BootOptions.listed(in: "croi.test=") { item in same(item, "all") || same(item, name) }
    }

    /// Whether the suite `name` runs: named, `suites`, or `all`.
    static func wantsSuite(_ name: StaticString) -> Bool {
        wantsSuite(unsafe Span(_unsafeStart: name.utf8Start, count: name.utf8CodeUnitCount))
    }

    static func wantsSuite(_ name: Span<UInt8>) -> Bool {
        BootOptions.listed(in: "croi.test=") { item in same(item, "all") || same(item, "suites") || same(item, name) }
    }

    private static func same(_ item: Span<UInt8>, _ text: StaticString) -> Bool {
        same(item, unsafe Span(_unsafeStart: text.utf8Start, count: text.utf8CodeUnitCount))
    }

    private static func same(_ item: Span<UInt8>, _ other: Span<UInt8>) -> Bool {
        guard item.count == other.count else { return false }
        for i in item.indices where item[i] != other[i] { return false }
        return true
    }
}

/// The kernel command line (`\croi\cmdline`), copied out of the handoff
/// before the PMM reclaims it. ASCII; at most `capacity` bytes are kept.
enum BootOptions {
    static var capacity: Int { 1024 }

    nonisolated(unsafe) private static var storage = InlineArray<1024, UInt8>(repeating: 0)
    nonisolated(unsafe) private(set) static var length = 0

    /// Copies the command line from the handoff (still physmap-reachable;
    /// `identity`: through the loader's identity map, before the kernel's
    /// own tables, K14q).
    static func capture(_ handoff: croi_handoff_t, identity: Bool = false) {
        guard handoff.cmdline != 0 else { return }
        let count = min(Int(handoff.cmdline_size), capacity)
        let address = identity ? handoff.cmdline : KernelLayout.physmap(handoff.cmdline)
        let bytes = unsafe UnsafePointer<UInt8>(bitPattern: UInt(address))!
        for i in 0..<count {
            let byte = unsafe bytes[i]
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == 0 { break }
            storage[i] = byte
            length = i + 1
        }
    }

    /// Whether the command line has this space-separated word.
    static func has(_ word: StaticString) -> Bool {
        let wanted = unsafe Span<UInt8>(_unsafeStart: word.utf8Start, count: word.utf8CodeUnitCount)
        var start = 0
        while start < length {
            var end = start
            while end < length, storage[end] != UInt8(ascii: " ") { end += 1 }
            if end - start == wanted.count {
                var same = true
                for i in 0..<wanted.count where storage[start + i] != wanted[i] { same = false }
                if same { return true }
            }
            start = end + 1
        }
        return false
    }

    /// The decimal number in a `prefix<digits>` word (e.g.
    /// "croi.contiguous_pool=" in "croi.contiguous_pool=16"), if present.
    static func number(after prefix: StaticString) -> UInt64? {
        let wanted = unsafe Span<UInt8>(_unsafeStart: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
        var start = 0
        while start < length {
            var end = start
            while end < length, storage[end] != UInt8(ascii: " ") { end += 1 }
            if end - start > wanted.count {
                var same = true
                for i in 0..<wanted.count where storage[start + i] != wanted[i] { same = false }
                if same {
                    var value: UInt64 = 0
                    for i in (start + wanted.count)..<end {
                        let digit = storage[i] &- UInt8(ascii: "0")
                        guard digit < 10 else { return nil }
                        value = value * 10 + UInt64(digit)
                    }
                    return value
                }
            }
            start = end + 1
        }
        return nil
    }

    /// Whether any item of a `prefix<item>,<item>,...` word (every such
    /// word) satisfies `matches`.
    static func listed(in prefix: StaticString, _ matches: (Span<UInt8>) -> Bool) -> Bool {
        let wanted = unsafe Span<UInt8>(_unsafeStart: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
        var start = 0
        while start < length {
            var end = start
            while end < length, storage[end] != UInt8(ascii: " ") { end += 1 }
            var same = end - start > wanted.count
            if same { for i in 0..<wanted.count where storage[start + i] != wanted[i] { same = false } }
            if same {
                var item = start + wanted.count
                while item < end {
                    var itemEnd = item
                    while itemEnd < end, storage[itemEnd] != UInt8(ascii: ",") { itemEnd += 1 }
                    if itemEnd > item, matches(storage.span.extracting(item..<itemEnd)) { return true }
                    item = itemEnd + 1
                }
            }
            start = end + 1
        }
        return false
    }

    /// The command line's words as NUL-terminated strings, one after
    /// another (userboot's environment, K8b).
    static func withEnvironment<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        var words = InlineArray<1025, UInt8>(repeating: 0)
        var count = 0
        var inWord = false
        for i in 0..<length {
            if storage[i] == UInt8(ascii: " ") {
                if inWord { count += 1 }  // the NUL already there
                inWord = false
            } else {
                words[count] = storage[i]
                count += 1
                inWord = true
            }
        }
        if inWord { count += 1 }
        return try body(words.span.extracting(0..<count))
    }

    static func write(to out: some TextOutput) {
        out.write(utf8: storage.span.extracting(0..<length))
    }
}
