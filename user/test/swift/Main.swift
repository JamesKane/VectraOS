import CroiRuntime

/// The K8a boot self-test's Embedded Swift program: runs on the user
/// runtime from an ELF the kernel loads, prints over the debuglog it was
/// handed as stdout, and grows a heap through its root VMAR. The kernel
/// reads its records back through the debuglog ring and checks the exit
/// code (its RELRO must be read only). With `swift.suite=<name>` in its environment it runs that
/// test suite instead (Suite.swift).
@main
struct SwiftTest {
    static func main() {
        if Suite.requested() { Suite.run() }
        print("swift: hello from user mode")

        // The heap: small blocks (size classes), then one too big for them.
        var squares: [Int] = []
        for i in 0..<1000 { squares.append(i * i) }
        var sum = 0
        for square in squares { sum += square }
        print("swift: \(squares.count) squares, sum \(sum)")
        let big = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 4096)
        unsafe big.initializeMemory(as: UInt8.self, repeating: 0xA5)
        let aligned = UInt(bitPattern: big.baseAddress) % 4096 == 0
        let last = unsafe big[64 * 1024 - 1]
        unsafe big.deallocate()

        // The environment from the bootstrap message.
        for i in 0..<croi_environ_count() {
            guard let entry = unsafe croi_environ(i) else { continue }
            print("swift: env \(unsafe String(cString: entry))")
        }

        let handles = croi_process_self() != 0 && croi_vmar_root_self() != 0 && croi_vdso_base() != 0
        // The kernel's loader made PT_GNU_RELRO read only once relocated.
        let relro = croi_relro_read_only() == 1
        croi_exit(sum == 332_833_500 && aligned && last == 0xA5 && handles && relro ? 0x600D : 1)
    }
}
