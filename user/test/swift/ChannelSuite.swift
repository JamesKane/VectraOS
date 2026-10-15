import CroiRuntime

/// Channels: endpoints, handles in messages, refusals that consume them,
/// and a closed peer, moved here from usertest.c's ipc (mode 7) when V1 cut
/// events and eventpairs (D23); and what the *_etc forms did, done the one
/// way left, from small_calls when V1 cut those (D22).
enum ChannelSuite {
    static func run() {
        endpoints()
        transfer()
        refusals()
        peerClosed()
        narrowedRights()
        mayDiscard()
        print("swift: channel passed")
    }

    static var transferRight: UInt32 { 1 << 1 }
    static var read: UInt32 { 1 << 2 }
    static var wait: UInt32 { 1 << 14 }
    static var sameRights: UInt32 { 1 << 31 }
    static var readable: UInt32 { UInt32(CROI_SIGNAL_READABLE) }
    static var peerClosedSignal: UInt32 { UInt32(CROI_SIGNAL_PEER_CLOSED) }

    /// A message received: the call's status, with its byte and handle
    /// counts in `actual` (bytes | handles << 32).
    struct Received {
        var bytes = InlineArray<64, UInt8>(repeating: 0)
        var handles = InlineArray<4, UInt32>(repeating: 0)
        var actual: UInt64 = 0
        var byteCount: UInt64 { actual & 0xFFFF_FFFF }
        var handleCount: UInt64 { actual >> 32 }

        mutating func read(_ channel: borrowing Handle, bytes capacity: UInt64 = 64, handles slots: UInt64 = 4)
            -> Int64 {
            Sys.call(CROI_SYS_CHANNEL_READ, channel.arg, 0, Sys.address(&bytes), Sys.address(&handles),
                     capacity | slots << 32, Sys.address(&actual))
        }
    }

    /// Writes `text` with `count` handles from `handles`: the call's status.
    static func write(_ channel: UInt64, _ text: StaticString, _ handles: UInt64 = 0, count: UInt64 = 0) -> Int64 {
        unsafe Sys.call(CROI_SYS_CHANNEL_WRITE, channel, 0, UInt64(UInt(bitPattern: text.utf8Start)),
                        UInt64(text.utf8CodeUnitCount), handles, count)
    }

    static func duplicate(_ handle: borrowing Handle, _ rights: UInt32) -> UInt32 {
        var out: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, handle.arg, UInt64(rights), Sys.address(&out)) == 0, "a duplicate")
        return out
    }

    static func closed(_ raw: UInt32) -> Bool { croi_handle_close(raw) == Status.badHandle }

    /// Two endpoints, each the other's related koid; nothing to read yet.
    static func endpoints() {
        let channel = Pair()
        var a = croi_info_handle_basic_t(), b = croi_info_handle_basic_t()
        let size = UInt64(MemoryLayout<croi_info_handle_basic_t>.size)
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, channel.a.arg, UInt64(CROI_INFO_HANDLE_BASIC), Sys.address(&a), size)
                  == 0 && Sys.call(CROI_SYS_OBJECT_GET_INFO, channel.b.arg, UInt64(CROI_INFO_HANDLE_BASIC),
                                   Sys.address(&b), size) == 0, "both ends' info")
        check(a.related_koid == b.koid && b.related_koid == a.koid && a.type == 4, "each end's peer is the other")
        var nothing = Received()
        check(nothing.read(channel.b) == Status.shouldWait, "nothing to read")
    }

    /// A handle in a message leaves our table, arrives, and works there:
    /// an add through it is seen through the original.
    static func transfer() {
        let channel = Pair()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var sent = duplicate(counter, sameRights)
        check(write(channel.a.arg, "hello", Sys.address(&sent), count: 1) == 0, "a message with a handle")
        check(closed(sent), "the handle left our table")
        check(Port.signals(of: channel.b, readable, deadline: Sys.now() + 1_000_000_000) & readable != 0, "READABLE")
        var message = Received()
        check(message.read(channel.b, bytes: 2, handles: 1) == Status.bufferTooSmall && message.byteCount == 5
                  && message.handleCount == 1, "too small: the sizes it needs")
        check(message.read(channel.b) == 0 && message.byteCount == 5 && message.handleCount == 1
                  && message.bytes[0] == UInt8(ascii: "h") && message.bytes[4] == UInt8(ascii: "o"), "received")
        let arrived = Handle(adopting: message.handles[0])
        check(Sys.call(CROI_SYS_COUNTER_ADD, arrived.arg, 1) == 0, "an add through the handle that arrived")
        check(Port.signals(of: counter, UInt32(CROI_COUNTER_POSITIVE), deadline: Sys.now() + 1_000_000_000)
                  & UInt32(CROI_COUNTER_POSITIVE) != 0, "is seen through the original")
        check(Port.signals(of: channel.b, readable) & readable == 0, "nothing more to read")
    }

    /// Refusals consume the handles listed, as Zircon's do, unless the list
    /// can't be read: without TRANSFER (the first error wins, the rest go
    /// too), a repeat (gone by the second look), a bad channel handle.
    static func refusals() {
        let channel = Pair()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var two = InlineArray<2, UInt32>(repeating: 0)
        two[0] = duplicate(counter, wait)
        two[1] = duplicate(counter, sameRights)
        check(write(channel.a.arg, "x", Sys.address(&two), count: 2) == Status.accessDenied
                  && closed(two[0]) && closed(two[1]), "without TRANSFER: both consumed")
        two[0] = duplicate(counter, sameRights)
        two[1] = two[0]
        check(write(channel.a.arg, "x", Sys.address(&two), count: 2) == Status.badHandle && closed(two[0]),
              "a repeat: consumed")
        two[0] = duplicate(counter, sameRights)
        check(write(0x7FFF_FFF0, "x", Sys.address(&two), count: 1) == Status.badHandle && closed(two[0]),
              "a bad channel: consumed")
        two[0] = duplicate(counter, sameRights)
        check(write(channel.a.arg, "x", 0x10, count: 1) == Status.invalidArgs, "an unreadable list")
        check(croi_handle_close(two[0]) == 0, "keeps its handles")
    }

    /// An endpoint can't travel in its own channel, and is consumed, which
    /// closes it: its peer sees PEER_CLOSED, refuses writes (consuming
    /// them), and reads drain before they refuse.
    static func peerClosed() {
        var a: UInt32 = 0, b: UInt32 = 0
        check(Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&a), Sys.address(&b)) == 0, "a channel")
        let other = Handle(adopting: b)
        check(write(UInt64(a), "bye") == 0, "a last message")
        check(write(UInt64(a), "x", Sys.address(&a), count: 1) == Status.notSupported && closed(a),
              "an endpoint in its own channel: refused, consumed")
        check(Port.signals(of: other, peerClosedSignal, deadline: Sys.now() + 1_000_000_000) & peerClosedSignal != 0,
              "PEER_CLOSED")
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var sent = duplicate(counter, sameRights)
        check(write(other.arg, "x", Sys.address(&sent), count: 1) == Status.peerClosed && closed(sent),
              "writes refused, consuming")
        var message = Received()
        check(message.read(other) == 0 && message.byteCount == 3, "the last message drains")
        check(message.read(other) == Status.peerClosed, "then reads refuse")
    }

    struct Pair: ~Copyable {
        let a: Handle
        let b: Handle

        init() {
            var a: UInt32 = 0, b: UInt32 = 0
            check(Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&a), Sys.address(&b)) == 0, "a channel")
            self.a = Handle(adopting: a)
            self.b = Handle(adopting: b)
        }
    }

    /// A handle's rights are narrowed with handle_duplicate before it is
    /// sent (a DUPLICATE disposition did both), and arrive as such; one
    /// without TRANSFER is refused and consumed.
    static func narrowedRights() {
        let channel = Pair()
        let vmo = Handle(vmo: pageSize)
        var narrowed: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, vmo.arg, UInt64(read | transferRight), Sys.address(&narrowed)) == 0,
              "a duplicate with fewer rights")
        check(Sys.call(CROI_SYS_CHANNEL_WRITE, channel.a.arg, 0, 0, 0, Sys.address(&narrowed), 1) == 0, "sent")
        var received: UInt32 = 0
        var actual: UInt64 = 0
        check(Sys.call(CROI_SYS_CHANNEL_READ, channel.b.arg, 0, 0, Sys.address(&received), 1 << 32,
                       Sys.address(&actual)) == 0 && actual == 1 << 32, "received")
        let arrived = Handle(adopting: received)
        var info = croi_info_handle_basic_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, arrived.arg, UInt64(CROI_INFO_HANDLE_BASIC), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_handle_basic_t>.size)) == 0, "its info")
        check(info.rights == read | transferRight && info.type == 3, "it arrives with only those rights")
        var stuck: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, vmo.arg, UInt64(read), Sys.address(&stuck)) == 0, "one without TRANSFER")
        let handle = stuck
        check(Sys.call(CROI_SYS_CHANNEL_WRITE, channel.a.arg, 0, 0, 0, Sys.address(&stuck), 1) == Status.accessDenied,
              "can't be sent")
        check(croi_handle_close(handle) == Status.badHandle, "and is consumed")
    }

    /// channel_read: a message that doesn't fit stays, unless MAY_DISCARD
    /// drops it; any other option is NOT_SUPPORTED.
    static func mayDiscard() {
        let channel = Pair()
        let text: StaticString = "long message"
        let length = UInt64(text.utf8CodeUnitCount)
        let bytes = unsafe UInt64(UInt(bitPattern: text.utf8Start))
        var buffer = InlineArray<16, UInt8>(repeating: 0)
        var actual: UInt64 = 0
        func receive(_ options: UInt64, capacity: UInt64) -> Int64 {
            Sys.call(CROI_SYS_CHANNEL_READ, channel.b.arg, options, Sys.address(&buffer), 0, capacity,
                     Sys.address(&actual))
        }
        check(Sys.call(CROI_SYS_CHANNEL_WRITE, channel.a.arg, 0, bytes, length, 0, 0) == 0, "written")
        check(receive(2, capacity: 16) == Status.notSupported, "an unknown option")
        check(receive(0, capacity: 4) == Status.bufferTooSmall && actual == length, "too small: the size it needs")
        check(receive(0, capacity: 16) == 0 && actual == length && buffer[0] == UInt8(ascii: "l"), "and it stays")
        check(Sys.call(CROI_SYS_CHANNEL_WRITE, channel.a.arg, 0, bytes, length, 0, 0) == 0, "written again")
        check(receive(UInt64(CROI_CHANNEL_READ_MAY_DISCARD), capacity: 4) == Status.bufferTooSmall && actual == length,
              "MAY_DISCARD: too small, the size it needed")
        check(receive(0, capacity: 16) == Status.shouldWait, "and it is gone")
    }
}
