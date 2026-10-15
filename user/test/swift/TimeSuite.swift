import CroiRuntime

/// Time: the vDSO's monotonic clock, the one way to read it once V1 cut
/// the clock syscall (D26). Moved here from usertest.c's mode 2, which
/// compared it with the syscall's; the kernel's own reading now comes
/// from a packet's timestamp.
enum TimeSuite {
    static func run() {
        rising()
        agreeing()
        print("swift: time passed")
    }

    /// It never goes back.
    static func rising() {
        var last = Sys.now()
        var back = false
        for _ in 0..<1000 {
            let now = Sys.now()
            if now < last { back = true }
            last = now
        }
        check(!back, "the vDSO clock never goes back")
    }

    /// It agrees with the kernel's: the time a counter's CHANGE packet
    /// carries, taken in the kernel at the add, falls between a reading
    /// before the add and one after it.
    static func agreeing() {
        let port = Port()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(port.bind(counter, UInt32(CROI_BIND_CHANGE) | UInt32(CROI_BIND_PERSISTENT), key: 1) == 0,
              "a doorbell to stamp the time")
        let before = Sys.now()
        check(croi_counter_add(counter.raw, 1) == 0, "counter_add")
        let after = Sys.now()
        guard let rung = port.next() else { return check(false, "the doorbell rings") }
        check(rung.payload.3 >= before && rung.payload.3 <= after, "the kernel's time is between the vDSO's readings")
    }
}
