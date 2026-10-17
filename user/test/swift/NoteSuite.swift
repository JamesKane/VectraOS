import CroiRuntime

/// Notes (D87): a process that set CROI_PROP_NOTIFY queues them, five at
/// most, the signal up while any wait, and takes them oldest first; notes
/// are checked as text; posting needs the NOTE right, and NOTIFY is a
/// process's own. One that didn't set it dies of the first, and the note
/// reads from its handle after.
enum NoteSuite {
    static func run() {
        queue()
        refusals()
        kill()
        print("swift: notes passed")
    }

    static var me: UInt64 { UInt64(td_runtime_process_self) }
    static var signal: UInt32 { UInt32(CROI_SIGNAL_PROCESS_NOTE) }

    static func post(_ process: UInt64, _ text: StaticString) -> Int64 {
        unsafe Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, process, UInt64(CROI_PROP_NOTE),
                        UInt64(UInt(bitPattern: text.utf8Start)), UInt64(text.utf8CodeUnitCount))
    }

    static func setNotify(_ process: UInt64, _ on: UInt32) -> Int64 {
        var value = on
        return Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, process, UInt64(CROI_PROP_NOTIFY), Sys.address(&value), 4)
    }

    /// The next note `process` gives (its own next, or the one it died of),
    /// and the call's status.
    static func take(_ process: UInt64) -> (status: Int64, text: InlineArray<128, UInt8>) {
        var text = InlineArray<128, UInt8>(repeating: 0)
        let status = Sys.call(CROI_SYS_OBJECT_GET_PROPERTY, process, UInt64(CROI_PROP_NOTE), Sys.address(&text), 128)
        return (status, text)
    }

    static func same(_ text: InlineArray<128, UInt8>, _ expected: StaticString) -> Bool {
        for i in 0..<expected.utf8CodeUnitCount where unsafe text[i] != expected.utf8Start[i] { return false }
        return text[expected.utf8CodeUnitCount] == 0
    }

    /// Whether NOTE is up on this process now.
    static func pending() -> Bool {
        var raw: UInt32 = 0
        guard Sys.duplicate(me, UInt64(CROI_RIGHT_SAME_RIGHTS), &raw) == 0 else { return false }
        let process = Handle(adopting: raw)
        return Port.signals(of: process, signal, deadline: Sys.now()) & signal != 0
    }

    static func queue() {
        check(take(me).status == Status.shouldWait, "nothing to take")
        check(setNotify(me, 1) == 0, "this process takes its notes")
        check(!pending(), "no note waits")
        check(post(me, "one") == 0 && pending(), "a note posted waits")
        for _ in 0..<4 { _ = post(me, "more") }
        check(post(me, "sixth") == Status.shouldWait, "five at most")
        let first = take(me)
        check(first.status == 0 && same(first.text, "one"), "the oldest first")
        for _ in 0..<4 { _ = take(me) }
        check(!pending() && take(me).status == Status.shouldWait, "taken, none wait")
        check(setNotify(me, 0) == 0, "and stops taking them")
    }

    static func refusals() {
        check(post(me, "") == Status.invalidArgs, "an empty note is refused")
        let nul: StaticString = "a\0b"
        check(post(me, nul) == Status.invalidArgs, "and one with a NUL in it")
        var long = InlineArray<128, UInt8>(repeating: 0x61)
        check(Sys.call(CROI_SYS_OBJECT_SET_PROPERTY, me, UInt64(CROI_PROP_NOTE), Sys.address(&long), 128)
                  == Status.invalidArgs, "and one of 128 bytes")
        var raw: UInt32 = 0
        let rights = UInt64(CROI_RIGHTS_BASIC | CROI_RIGHT_GET_PROPERTY | CROI_RIGHT_SET_PROPERTY)
        check(Sys.duplicate(me, rights, &raw) == 0, "a handle without NOTE")
        let without = Handle(adopting: raw)
        check(post(without.arg, "x") == Status.accessDenied, "can't post")
        check(take(me).status == Status.shouldWait, "nothing was queued")
        check(take(without.arg).status == Status.shouldWait, "the process's own, by any handle with GET_PROPERTY")
    }

    /// A process held at its start by a job debugger: running, not taking
    /// notes, so the first kills it.
    static func kill() {
        let root = Handle(adopting: td_startup_take(croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0)))
        var raw: UInt32 = 0
        check(Sys.call(CROI_SYS_JOB_CREATE, root.arg, 0, Sys.address(&raw)) == 0, "a job")
        let job = Handle(adopting: raw)
        var debugger: UInt32 = 0
        check(Sys.call(CROI_SYS_TASK_CREATE_EXCEPTION_CHANNEL, job.arg, UInt64(CROI_EXCEPTION_CHANNEL_DEBUGGER),
                       Sys.address(&debugger)) == 0, "a job debugger")
        let channel = Handle(adopting: debugger)
        let child = ObjectSuite.start(in: job)
        var info = croi_exception_info_t()
        let held = ObjectSuite.exception(on: channel, &info)
        check(held != nil, "the child is held at its start")
        check(take(child.process.arg).status == Status.badState, "alive, it died of nothing")
        check(setNotify(child.process.arg, 1) == Status.accessDenied, "NOTIFY is a process's own")
        check(post(child.process.arg, "interrupt") == 0, "a note posted to it")
        let terminated = UInt32(CROI_SIGNAL_TASK_TERMINATED)
        check(Port.signals(of: child.process, terminated, deadline: Sys.now() + 3_000_000_000) & terminated != 0,
              "kills it")
        var process = croi_info_process_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, child.process.arg, UInt64(CROI_INFO_PROCESS), Sys.address(&process),
                       UInt64(MemoryLayout<croi_info_process_t>.size)) == 0
                  && process.return_code == CROI_TASK_RETCODE_NOTE_KILL, "its return code says a note did")
        let died = take(child.process.arg)
        check(died.status == 0 && same(died.text, "interrupt"), "and which")
        check(post(child.process.arg, "again") == Status.badState, "a dead process takes none")
        _ = consume held
        _ = consume channel
    }
}
