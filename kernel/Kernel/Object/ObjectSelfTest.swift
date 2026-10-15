import CKernel
import Fmt
import Synchronization

/// Boot self-test for K5a: handles and rights, koids and lifetimes.
/// object_wait_one/many and object_signal went in V1 (D23): ports are the
/// one wait, and PortSelfTest checks bindings. Panics on failure.
enum ObjectSelfTest {
    static func run(_ console: Uart) {
        let liveBefore = Objects.live.load(ordering: .relaxed)
        do throws(Status) {
            let table = HandleTable()
            let event = try table.add(try EventObject.create(), rights: EventObject.defaultRights)

            // Errors in Zircon's order: bad handle, wrong type, access denied.
            guard status({ () throws(Status) in _ = try table.get(event, type: .port) }) == .wrongType,
                  status({ () throws(Status) in _ = try table.get(event, rights: .write) }) == .accessDenied,
                  status({ () throws(Status) in _ = try table.get(0x7FF) }) == .badHandle,
                  status({ () throws(Status) in _ = try table.get(event &+ 4) }) == .badHandle else {
                panic("object self-test: handle errors")
            }
            // Duplicate (subset), replace (old gone), stale handles.
            let readOnly = try table.duplicate(event, rights: .wait | .inspect | .transfer)
            guard try table.rights(of: readOnly) == .wait | .inspect | .transfer,
                  status({ () throws(Status) in _ = try table.duplicate(readOnly, rights: .sameRights) }) == .accessDenied,
                  status({ () throws(Status) in _ = try table.duplicate(event, rights: .write) }) == .invalidArgs else {
                panic("object self-test: duplicate")
            }
            let replaced = try table.replace(readOnly, rights: .wait)
            guard status({ () throws(Status) in _ = try table.get(readOnly) }) == .badHandle else { panic("object self-test: replace") }
            try table.close(replaced)
            let reused = try table.add(try EventObject.create(), rights: EventObject.defaultRights)
            guard reused != replaced, status({ () throws(Status) in _ = try table.get(replaced) }) == .badHandle else {
                panic("object self-test: stale handle accepted")
            }
            let first = try table.get(event).koid, second = try table.get(reused).koid
            guard second > first, first >= 1024 else { panic("object self-test: koids") }
        } catch {
            panic("object self-test: unexpected status")
        }
        guard Objects.live.load(ordering: .relaxed) == liveBefore else { panic("object self-test: objects leaked") }
        console.write("  object: handles (rights, generations, duplicate, replace), koids, lifetimes ok\n")
    }

    private static func status(_ body: () throws(Status) -> Void) -> Status? {
        do throws(Status) {
            try body()
            return nil
        } catch {
            return error
        }
    }
}
