import CroiRuntime

/// object_bind (V1, D20; kernel Bind.swift): batches, the CHANGE doorbell,
/// persistent signal bindings, unbinding, and port_wait's leeway. The
/// older kinds (ONCE signals, VALUE, INTERRUPT, OVERRUN, PRESSURE) are
/// still covered where usertest.c tested their old calls.
enum BindSuite {
    static func run() {
        let port = Port()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        batch(port, counter)
        doorbell(port, counter)
        unbinding(port, counter)
        persistentSignals(port, counter)
        readable(port)
        leeway(port)
        print("swift: bind passed")
    }

    static var change: UInt32 { UInt32(CROI_BIND_CHANGE) | UInt32(CROI_BIND_PERSISTENT) }

    static func add(_ counter: borrowing Handle, _ amount: Int64 = 1) {
        check(croi_counter_add(counter.raw, amount) == 0, "counter_add")
    }

    /// Sets the value: an add of the difference (V1 cut counter_write, D25).
    static func set(_ counter: borrowing Handle, _ value: Int64) {
        var now: Int64 = 0
        check(Sys.call(CROI_SYS_COUNTER_READ, counter.arg, Sys.address(&now)) == 0, "counter_read")
        add(counter, value - now)
    }

    /// A batch runs in order and stops at its first failure, leaving the
    /// rest untouched; a bad count fails the whole call.
    static func batch(_ port: borrowing Port, _ counter: borrowing Handle) {
        var items = InlineArray<3, croi_bind_item_t>(repeating: port.item(counter, change, key: 20))
        items[1] = port.item(counter, UInt32(CROI_BIND_CHANGE), key: 21)  // not PERSISTENT: refused
        items[2] = port.item(counter, UInt32(CROI_BIND_VALUE), key: 22, trigger: 1000)
        check(port.bind(&items) == 1, "a batch stops at its first failure")
        check(items[0].status == 0 && items[1].status == Int32(Status.invalidArgs) && items[2].status == 1,
              "each processed item has its status; the rest are untouched")
        check(port.bind(&items, count: 0) == Status.invalidArgs, "an empty batch is refused")
        var many = InlineArray<65, croi_bind_item_t>(repeating: port.item(counter, change, key: 23))
        check(port.bind(&many) == Status.invalidArgs, "more than CROI_BIND_MAX_ITEMS is refused")
        check(port.bind(counter, UInt32(CROI_BIND_VALUE) | UInt32(CROI_BIND_PERSISTENT), key: 23, trigger: 5)
                  == Status.invalidArgs, "VALUE can't be PERSISTENT")
        check(port.bind(counter, change, key: 23, trigger: 5) == Status.invalidArgs, "CHANGE takes no trigger")
        check(port.bind(counter, UInt32(CROI_BIND_SIGNALS) | 1 << 12, key: 23, trigger: 1) == Status.invalidArgs,
              "unknown flags are refused")
        check(port.empty, "nothing fired yet")
    }

    /// CHANGE (key 20, bound by `batch`): one packet however many adds,
    /// counting them, with the value and time; queued again after a read.
    static func doorbell(_ port: borrowing Port, _ counter: borrowing Handle) {
        let before = Sys.now()
        add(counter)
        add(counter)
        add(counter)
        guard let rung = port.next() else { return check(false, "a doorbell rings") }
        check(rung.type == UInt32(CROI_PKT_TYPE_COUNTER_CHANGE) && rung.key == 20, "a CHANGE packet")
        check(rung.payload.1 == 3 && rung.payload.2 == 3 && rung.payload.3 >= before,
              "one packet: the value, three adds, the time")
        check(port.empty, "coalesced while queued")
        set(counter, 10)
        guard let again = port.next() else { return check(false, "rings again once read") }
        check(again.payload.1 == 10 && again.payload.2 == 1, "rings again, the count from zero")
    }

    /// port_cancel unbinds, taking a queued packet back; closing the handle
    /// a binding was made through unbinds it too.
    static func unbinding(_ port: borrowing Port, _ counter: borrowing Handle) {
        check(port.cancel(counter, key: 20) == 0, "port_cancel")
        add(counter)
        check(port.empty, "nothing after port_cancel")
        check(port.bind(counter, change, key: 24) == 0, "bound again")
        add(counter)
        check(port.cancel(counter, key: 24) == 0 && port.empty, "port_cancel takes a queued packet back")
        do {
            let through = Handle(duplicating: counter)
            check(port.bind(through, change, key: 25) == 0, "bound through a duplicate")
            add(counter)
        }  // the duplicate closes
        add(counter)
        check(port.empty, "closing the handle unbinds and drops its packet")
    }

    /// SIGNALS PERSISTENT: at once if asserted (not with EDGE), then each
    /// time a trigger signal rises, coalesced; an event that leaves it set
    /// (an add to a positive counter) fires nothing (CHANGE is the
    /// every-add binding).
    static func persistentSignals(_ port: borrowing Port, _ counter: borrowing Handle) {
        let positive = UInt32(CROI_COUNTER_POSITIVE)
        let before = Sys.now()
        let options = UInt32(CROI_BIND_SIGNALS) | UInt32(CROI_BIND_PERSISTENT) | UInt32(CROI_BIND_TIMESTAMP)
        check(port.bind(counter, options, key: 26, trigger: UInt64(positive)) == 0, "a persistent signal binding")
        guard let now = port.next() else { return check(false, "fires at once while asserted") }
        check(now.type == UInt32(CROI_PKT_TYPE_SIGNAL) && now.key == 26 && now.payload.1 == 1,
              "a signal packet with a count")
        check(UInt32(truncatingIfNeeded: now.payload.0) == positive && UInt32(now.payload.0 >> 32) & positive != 0
                  && now.payload.2 >= before, "the trigger, what was observed, and the time")
        add(counter)
        add(counter)
        check(port.empty, "nothing while the signal stays set")
        set(counter, -1)
        check(port.empty, "nothing while no trigger signal is asserted")
        set(counter, 1)
        set(counter, -1)
        set(counter, 1)
        guard let twice = port.next() else { return check(false, "fires when the signal rises") }
        check(twice.payload.1 == 2 && port.empty, "two rises, one packet")
        check(port.cancel(counter, key: 26) == 0, "unbound")

        let edge = UInt32(CROI_BIND_SIGNALS) | UInt32(CROI_BIND_PERSISTENT) | UInt32(CROI_BIND_EDGE)
        set(counter, -1)
        check(port.bind(counter, edge, key: 27, trigger: UInt64(CROI_COUNTER_NON_POSITIVE)) == 0 && port.empty,
              "EDGE: not at once")
        set(counter, -2)
        check(port.empty, "EDGE: not while the signal stays set")
        set(counter, 1)
        set(counter, -2)
        guard let later = port.next() else { return check(false, "EDGE: fires when the signal rises") }
        check(later.key == 27 && later.payload.1 == 1 && later.payload.2 == 0, "no time unless asked")
        check(port.cancel(counter, key: 27) == 0, "unbound")
        check(port.cancel(counter, key: 27) == Status.notFound, "port_cancel by source: NOT_FOUND when nothing is left")
    }

    /// A persistent READABLE binding on a channel: a packet when the queue
    /// fills, none at a read that leaves messages queued (until V2, every
    /// such read queued one), and one again once emptied and written.
    static func readable(_ port: borrowing Port) {
        var a: UInt32 = 0, b: UInt32 = 0
        check(Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&a), Sys.address(&b)) == 0, "a channel")
        let writer = Handle(adopting: a), reader = Handle(adopting: b)
        let options = UInt32(CROI_BIND_SIGNALS) | UInt32(CROI_BIND_PERSISTENT)
        check(port.bind(reader, options, key: 28, trigger: UInt64(CROI_SIGNAL_READABLE)) == 0 && port.empty,
              "bound while empty")
        var word: UInt32 = 7
        for _ in 0..<3 {
            check(Sys.writeChannel(writer.arg, bytes: Sys.address(&word), count: 4, handles: 0, handleCount: 0) == 0,
                  "written")
        }
        guard let filled = port.next() else { return check(false, "fires when the queue fills") }
        check(filled.key == 28 && filled.payload.1 == 1 && port.empty, "one packet for three writes")
        var actual: UInt64 = 0
        for _ in 0..<3 {
            check(Sys.readChannel(reader.arg, 0, bytes: Sys.address(&word), handles: 0, capacity: 4, &actual) == 0,
                  "read")
            check(port.empty, "a read fires nothing")
        }
        check(Sys.writeChannel(writer.arg, bytes: Sys.address(&word), count: 4, handles: 0, handleCount: 0) == 0,
              "written again")
        check(port.next()?.key == 28 && port.empty, "fires again once emptied and written")
        check(port.cancel(reader, key: 28) == 0, "unbound")
    }

    /// port_wait's leeway lets a timeout run late, never early; a thread
    /// on a deadline profile gets none (moved from mode 8's timers when V1
    /// cut timer objects, D25). test_profile binds the deadline context
    /// runSuites lends.
    static func leeway(_ port: borrowing Port) {
        var deadline = Sys.now() + 1_000_000
        check(port.next(deadline: deadline, leeway: 1_000_000) == nil && Sys.now() >= deadline,
              "a leeway never ends a wait early")
        check(Sys.call(CROI_SYS_TEST, 1) == 0, "bound to the deadline context")
        deadline = Sys.now() + 5_000_000
        let timedOut = port.next(deadline: deadline, leeway: 500_000_000) == nil
        let woke = Sys.now()
        check(Sys.call(CROI_SYS_TEST, 2) == 0, "and back")
        check(timedOut && woke >= deadline && woke < deadline + 200_000_000,
              "a deadline thread's half second of leeway is ignored")
    }
}
