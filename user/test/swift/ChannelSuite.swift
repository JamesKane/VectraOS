import CroiRuntime

/// Channels: what the *_etc forms did, done the one way left. Moved here
/// from usertest.c's small_calls when V1 cut channel_write_etc,
/// channel_read_etc and channel_call_etc (D22).
enum ChannelSuite {
    static func run() {
        narrowedRights()
        mayDiscard()
        print("swift: channel passed")
    }

    static var transfer: UInt32 { 1 << 1 }
    static var read: UInt32 { 1 << 2 }

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
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, vmo.arg, UInt64(read | transfer), Sys.address(&narrowed)) == 0,
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
        check(info.rights == read | transfer && info.type == 3, "it arrives with only those rights")
        var stuck: UInt32 = 0
        check(Sys.call(CROI_SYS_HANDLE_DUPLICATE, vmo.arg, UInt64(read), Sys.address(&stuck)) == 0, "one without TRANSFER")
        let handle = stuck
        check(Sys.call(CROI_SYS_CHANNEL_WRITE, channel.a.arg, 0, 0, 0, Sys.address(&stuck), 1) == Status.accessDenied,
              "can't be sent")
        check(Sys.call(CROI_SYS_HANDLE_CLOSE, UInt64(handle)) == Status.badHandle, "and is consumed")
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
