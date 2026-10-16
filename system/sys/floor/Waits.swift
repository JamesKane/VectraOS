// SPDX-License-Identifier: BSD-3-Clause

// croi's futexes and ports for what runs below Sys and can't import it
// (td_floor.h, M6f): tier 1's Swift runtime, whose global executor's
// threads sleep on a port and whose Synchronization.Mutex is a futex lock.
// Results are croi's statuses (0, or negative).
//
// Each thread's waits are on a port of its own (V1 cut the thread waits
// and sleeps, D23, D25): made on first use and kept in its block, a wait
// binds ONCE there and a sleep is its port_wait to a deadline. Nothing
// else binds to it, so a wait's packet is the only one it can hold, and a
// timed-out wait's port_cancel takes its binding and any packet queued.

import CroiSyscall
import Synchronization
import TDNative

/// futex_wait: sleeps while `*word == current`, until a wake or `deadline`
/// (BAD_STATE if it already differs, TIMED_OUT at the deadline).
@c public func td_futex_wait(_ word: UnsafeMutablePointer<UInt32>, _ current: UInt32, _ deadline: Int64) -> Int32 {
  Int32(truncatingIfNeeded: croi_syscall(CROI_SYS_FUTEX_WAIT, UInt64(UInt(bitPattern: word)), UInt64(current), 0,
                                         UInt64(bitPattern: deadline), 0))
}

/// futex_wake: wakes up to `count` threads waiting on `word`.
@c public func td_futex_wake(_ word: UnsafeMutablePointer<UInt32>, _ count: UInt32) -> Int32 {
  Int32(truncatingIfNeeded: croi_syscall(CROI_SYS_FUTEX_WAKE, UInt64(UInt(bitPattern: word)), UInt64(count), 0, 0, 0))
}

/// port_create: a port, in `*port`.
@c public func td_port_create(_ port: UnsafeMutablePointer<UInt32>) -> Int32 {
  Int32(truncatingIfNeeded: croi_syscall(CROI_SYS_PORT_CREATE, 0, UInt64(UInt(bitPattern: port)), 0, 0, 0))
}

/// port_queue: one packet onto `port`.
@c public func td_port_queue(_ port: UInt32, _ packet: UnsafePointer<croi_port_packet_t>) -> Int32 {
  Int32(truncatingIfNeeded: croi_port_queue(port, packet))
}

/// port_wait: the next packet on `port` into `packet`, waiting until
/// `deadline` (TIMED_OUT then).
@c public func td_port_wait(_ port: UInt32, _ deadline: Int64,
                            _ packet: UnsafeMutablePointer<croi_port_packet_t>) -> Int32 {
  Int32(truncatingIfNeeded: croi_port_wait(port, UInt64(bitPattern: deadline), packet, 0))
}

/// port_cancel: the bindings to `port` with `key`, from any source, and
/// their queued packets; NOT_FOUND if there were none.
@c public func td_port_cancel_key(_ port: UInt32, _ key: UInt64) -> Int32 {
  Int32(truncatingIfNeeded: croi_syscall(CROI_SYS_PORT_CANCEL, UInt64(port), 0, key, 0, 0))
}

/// The calling thread's port, made on first use (0 if croi refused).
@c public func td_thread_port() -> UInt32 {
  let current = ThreadBlock.port
  if current != 0 { return current }
  var port: UInt32 = 0
  guard unsafe td_port_create(&port) == 0 else { return 0 }
  ThreadBlock.port = port
  return port
}

/// The key of a thread's waits: one at a time, so any constant.
let waitKey: UInt64 = 1

/// Waits for `item`'s event until `deadline`: a ONCE binding of it (its key
/// the thread's) to the thread's port, cancelled if the deadline passes
/// first. The packet in `*packet` (if not null).
@c public func td_wait_bind(_ item: UnsafePointer<croi_bind_item_t>, _ deadline: Int64,
                            _ packet: UnsafeMutablePointer<croi_port_packet_t>?) -> Int32 {
  let port = td_thread_port()
  guard port != 0 else { return Int32(truncatingIfNeeded: CROI_ERR_NO_RESOURCES) }
  var bind = unsafe item.pointee
  bind.options &= ~CROI_BIND_PERSISTENT
  bind.key = waitKey
  bind.status = 1
  let bound = unsafe withUnsafeMutablePointer(to: &bind) { p in
    unsafe croi_syscall(CROI_SYS_OBJECT_BIND, UInt64(port), UInt64(UInt(bitPattern: p)), 1, 0, 0)
  }
  if bound < 0 { return Int32(truncatingIfNeeded: bound) }
  if bound != 1 { return bind.status }
  var got = croi_port_packet_t()
  let status = unsafe td_port_wait(port, deadline, &got)
  if status != 0 {
    _ = td_port_cancel_key(port, waitKey)
    return status
  }
  if let packet = unsafe packet { unsafe packet.pointee = got }
  return got.status
}

/// Waits for any of `signals` on `handle` until `deadline` (td_wait_bind's
/// SIGNALS): the signals seen in `*observed`.
@c public func td_wait_one(_ handle: UInt32, _ signals: UInt32, _ deadline: Int64,
                           _ observed: UnsafeMutablePointer<UInt32>?) -> Int32 {
  var item = croi_bind_item_t(handle: handle, options: CROI_BIND_SIGNALS, key: 0, trigger: UInt64(signals),
                              status: 0, reserved: 0)
  var packet = croi_port_packet_t()
  let status = unsafe td_wait_bind(&item, deadline, &packet)
  if status == 0, let observed = unsafe observed {
    unsafe observed.pointee = UInt32(truncatingIfNeeded: packet.payload.0 >> 32)
  }
  return status
}

/// Sleeps until `deadline`: the thread's port's wait, which nothing else
/// fills.
@c public func td_sleep(_ deadline: Int64) {
  let port = td_thread_port()
  var packet = croi_port_packet_t()
  while unsafe td_port_wait(port, deadline, &packet) == 0 {}
}

/// The process's executor port, made on first use (two threads racing to
/// make it keep the first; the loser closes its own).
@c public func td_executor_port() -> UInt32 {
  let current = ExecutorPort.handle.load(ordering: .acquiring)
  if current != 0 { return current }
  var port: UInt32 = 0
  guard withUnsafeMutablePointer(to: &port, { unsafe td_port_create($0) }) == 0 else { return 0 }
  let (exchanged, original) = ExecutorPort.handle.compareExchange(expected: 0, desired: port, ordering: .acquiringAndReleasing)
  if exchanged { return port }
  _ = croi_handle_close(port)
  return original
}

enum ExecutorPort {
  static let handle = Atomic<UInt32>(0)
}

/// The CPUs croi runs (its topology page's count).
@c public func td_cpu_count() -> Int { Runtime.cpuCount() }
