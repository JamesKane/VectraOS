// SPDX-License-Identifier: BSD-3-Clause

// The input class's protocol (architecture §13; V2 item 7d, D74): an input
// device's driver host serves `Device` at its tree's `device`: what the
// device is, and `open`, which gives it a reader's ring. Its events (evdev
// codes, as virtio-input and Linux report them) go on the one ring (D43)
// in the reader's VMO, a slot each (InputRing, Ring.swift), not on the
// channel: todhchai's version 1 sent each batch as a channel event, and
// its input service had a ring format of its own (TDIR), which the one
// ring replaces (syscall audit).

import IPC
import Sys

@IPCLibrary(id: "todhchai.input.device", version: 2)
public enum InputDeviceIPC {
  public enum InputError: Int32, IPCErrorCode, Sendable {
    /// The ring isn't one: wrong size, format or slot size.
    case invalid = 1
  }

  public struct DeviceInfo: Equatable, Sendable {
    public var name: String
    /// 1 keyboard, 2 mouse, 3 tablet, 0 other.
    public var kind: UInt8
    public var vendor: UInt16
    public var product: UInt16
    public init(name: String, kind: UInt8, vendor: UInt16, product: UInt16) {
      self.name = name
      self.kind = kind
      self.vendor = vendor
      self.product = product
    }
  }

  /// A reader's ring: a VMO the reader made, holding one ring of `slots`
  /// InputRing slots from its start, and the reader's doorbell, a counter
  /// the driver adds to when it publishes to a reader that sleeps.
  public struct Events: ~Copyable {
    public var memory: Handle
    public var readerBell: Handle
    public var slots: UInt32
    public init(memory: consuming Handle, readerBell: consuming Handle, slots: UInt32) {
      self.memory = memory
      self.readerBell = readerBell
      self.slots = slots
    }
  }

  public protocol Device {
    func info() -> DeviceInfo
    /// Events from now on into `events`' ring. One reader at a time: a
    /// second open replaces the first.
    func open(_ events: consuming Events) throws(InputError)
  }
}
