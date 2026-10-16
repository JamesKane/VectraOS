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
        var index = 0
        while let entry = unsafe environ[index] {
            index += 1
            print("swift: env \(unsafe String(cString: entry))")
        }

        let handles = td_runtime_process_self != 0 && td_runtime_vmar_root != 0 && td_runtime_vdso_base != 0
        // The kernel's loader made PT_GNU_RELRO read only once relocated.
        let relro = Image.relroReadOnly() == 1
        td_exit(sum == 332_833_500 && aligned && last == 0xA5 && handles && relro ? 0x600D : 1)
    }
}
