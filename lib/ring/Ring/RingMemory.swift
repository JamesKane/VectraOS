import Synchronization

/// An atomic operation's order. A struct, not an enum: an enum is Hashable whether asked or not, and an
/// exported hashValue pulls the stdlib's seeded hashing into a program
/// linked --export-dynamic.
public struct RingOrder: Equatable {
    let raw: UInt8
    public static var relaxed: RingOrder { RingOrder(raw: 0) }
    public static var acquiring: RingOrder { RingOrder(raw: 1) }
    public static var releasing: RingOrder { RingOrder(raw: 2) }
    public static var sequentiallyConsistent: RingOrder { RingOrder(raw: 3) }
}

/// The memory operations a ring makes on shared memory (D43). Ring is
/// generic over them so that RingCheck (lib/ring/check) can take every
/// one: `NativeMemory` everywhere else.
public protocol RingMemory {
    static func load64(_ address: UnsafeRawPointer, _ order: RingOrder) -> UInt64
    static func load32(_ address: UnsafeRawPointer, _ order: RingOrder) -> UInt32
    static func store64(_ address: UnsafeMutableRawPointer, _ value: UInt64, _ order: RingOrder)
    static func store32(_ address: UnsafeMutableRawPointer, _ value: UInt32, _ order: RingOrder)
    static func fence(_ order: RingOrder)
    /// A slot's bytes, copied in or out.
    static func copy(_ to: UnsafeMutableRawPointer, _ from: UnsafeRawPointer, _ count: Int)
}

/// The hardware's atomics.
public enum NativeMemory: RingMemory {
    @inline(__always)
    public static func load64(_ address: UnsafeRawPointer, _ order: RingOrder) -> UInt64 {
        let atomic = unsafe address.assumingMemoryBound(to: Atomic<UInt64>.self)
        switch order {
        case .relaxed: return unsafe atomic.pointee.load(ordering: .relaxed)
        case .acquiring, .releasing: return unsafe atomic.pointee.load(ordering: .acquiring)
        default: return unsafe atomic.pointee.load(ordering: .sequentiallyConsistent)
        }
    }

    @inline(__always)
    public static func load32(_ address: UnsafeRawPointer, _ order: RingOrder) -> UInt32 {
        let atomic = unsafe address.assumingMemoryBound(to: Atomic<UInt32>.self)
        switch order {
        case .relaxed: return unsafe atomic.pointee.load(ordering: .relaxed)
        case .acquiring, .releasing: return unsafe atomic.pointee.load(ordering: .acquiring)
        default: return unsafe atomic.pointee.load(ordering: .sequentiallyConsistent)
        }
    }

    @inline(__always)
    public static func store64(_ address: UnsafeMutableRawPointer, _ value: UInt64, _ order: RingOrder) {
        let atomic = unsafe address.assumingMemoryBound(to: Atomic<UInt64>.self)
        switch order {
        case .relaxed: unsafe atomic.pointee.store(value, ordering: .relaxed)
        case .acquiring, .releasing: unsafe atomic.pointee.store(value, ordering: .releasing)
        default: unsafe atomic.pointee.store(value, ordering: .sequentiallyConsistent)
        }
    }

    @inline(__always)
    public static func store32(_ address: UnsafeMutableRawPointer, _ value: UInt32, _ order: RingOrder) {
        let atomic = unsafe address.assumingMemoryBound(to: Atomic<UInt32>.self)
        switch order {
        case .relaxed: unsafe atomic.pointee.store(value, ordering: .relaxed)
        case .acquiring, .releasing: unsafe atomic.pointee.store(value, ordering: .releasing)
        default: unsafe atomic.pointee.store(value, ordering: .sequentiallyConsistent)
        }
    }

    @inline(__always)
    public static func fence(_ order: RingOrder) {
        switch order {
        case .relaxed: break
        case .acquiring: atomicMemoryFence(ordering: .acquiring)
        case .releasing: atomicMemoryFence(ordering: .releasing)
        default: atomicMemoryFence(ordering: .sequentiallyConsistent)
        }
    }

    @inline(__always)
    public static func copy(_ to: UnsafeMutableRawPointer, _ from: UnsafeRawPointer, _ count: Int) {
        unsafe to.copyMemory(from: from, byteCount: count)
    }
}
