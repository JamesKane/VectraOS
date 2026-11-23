// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan layer's window system on the SDK (VX): `WindowSystem` and `PresentWindow` over a `Loop` and its windows, which are
// Radharc's. The layer (graphics/vulkan/drivers/core/lib) knows nothing of the SDK; this file, in the registry, is all the
// glue (D174, "Presentation, as designed"). A program that presents through Vulkan has no loop of its own: this one is its,
// owned by the process and driven by the layer's calls (`pump`, `wait`, `present`), never by a callback.
//
// One thread at a time uses a window, as Vulkan asks of a surface.

import Sys
import VulkanCoreDriver
import VX

/// What a present waits for the compositor, in all, before it says the window is lost: a hidden window's frames come about
/// once a second.
private let presentGiveUp: UInt64 = 20_000_000_000

/// The process's loop, made when the first window opens.
final class LoopBox {
  var loop: Loop
  init() throws(LoopError) { loop = try Loop() }
}

final class VXWindows: WindowSystem, @unchecked Sendable {
  var box: LoopBox?
  var windows: [WindowID: VXWindow] = [:]

  func open(title: String, width: Int32, height: Int32) -> (any PresentWindow)? {
    if box == nil { box = try? LoopBox() }
    guard let box else { return nil }
    let id: WindowID
    do { id = try box.loop.openWindow(title, width: width, height: height) } catch { return nil }
    let window = VXWindow(system: self, id: id)
    windows[id] = window
    // Its first configure is the size it has.
    window.pump()
    var waited: UInt64 = 0
    while !window.configured && waited < 5_000_000_000 {
      window.wait(nanoseconds: 10_000_000)
      waited += 10_000_000
    }
    guard window.configured else {
      box.loop.closeWindow(id)
      windows[id] = nil
      return nil
    }
    return window
  }

  /// Gives each event to its window.
  func dispatch(_ events: Events) {
    for e in events { windows[e.window]?.take(e) }
  }
}

final class VXWindow: PresentWindow, @unchecked Sendable {
  unowned let system: VXWindows
  let id: WindowID
  var configured = false
  var pixelWidth: Int32 = 0
  var pixelHeight: Int32 = 0
  /// The window's scale, n/120 (the pointer is in points).
  var scale: Int64 = 120
  var queue: [WindowEvent] = []
  var closed = false

  init(system: VXWindows, id: WindowID) {
    self.system = system
    self.id = id
  }

  var width: Int32 { pixelWidth }
  var height: Int32 { pixelHeight }

  func take(_ e: Event) {
    switch e.payload {
    case .configure(let c):
      let first = !configured
      configured = true
      scale = Int64(c.scale)
      if c.pixelWidth != pixelWidth || c.pixelHeight != pixelHeight {
        pixelWidth = c.pixelWidth
        pixelHeight = c.pixelHeight
        if !first { queue.append(.resize(width: pixelWidth, height: pixelHeight)) }
      }
    case .close: queue.append(.close)
    case .keyDown(let k):
      queue.append(.key(down: true, code: UInt32(k.usage.rawValue), character: k.character, modifiers: UInt32(k.modifiers.rawValue & 15)))
    case .keyUp(let k):
      queue.append(.key(down: false, code: UInt32(k.usage.rawValue), character: k.character, modifiers: UInt32(k.modifiers.rawValue & 15)))
    case .pointer(let p):
      var button: UInt32 = 0
      var pressed = false
      switch p.action {
      case .motion: break
      case .down(let b):
        button = Self.button(b)
        pressed = true
      case .up(let b): button = Self.button(b)
      }
      queue.append(.pointer(x: Int32(p.x * Double(scale) / 120), y: Int32(p.y * Double(scale) / 120), button: button, pressed: pressed))
    case .wheel(let w): queue.append(.wheel(x: Int32(w.dx), y: Int32(w.dy)))
    default: break
    }
  }

  static func button(_ b: PointerButton) -> UInt32 {
    switch b {
    case .left: 1
    case .right: 2
    case .middle: 3
    case .other: 0
    }
  }

  func pump() { system.dispatch(system.box!.loop.poll()) }

  func wait(nanoseconds: UInt64) {
    system.dispatch(system.box!.loop.wait(until: Deadline(ns: Deadline.now.ns &+ nanoseconds)))
  }

  func addImage(vmo: UInt32, width: Int32, height: Int32, stride: Int32, premultiplied: Bool, acquire: UInt32?) -> UInt32? {
    let handle = Handle(raw: vmo)
    let alpha: Loop.ImageAlpha = premultiplied ? .premultiplied : .opaque
    guard let acquire else {
      return try? system.box!.loop.addImage(id, vmo: handle, width: width, height: height, stride: stride, alpha: alpha)
    }
    return try? system.box!.loop.addImage(id, vmo: handle, width: width, height: height, stride: stride, alpha: alpha,
                                          acquire: Handle(raw: acquire))
  }

  func removeImage(_ image: UInt32) { system.box!.loop.removeImage(id, image: image) }

  func isFree(_ image: UInt32) -> Bool { system.box!.loop.imageIsFree(id, image: image) }

  func present(_ image: UInt32, drawnAt: UInt64?) -> PresentOutcome {
    var waited: UInt64 = 0
    while true {
      // Radharc takes one present of a window at a time until its frame comes back: FIFO.
      pump()
      if closed { return .lost }
      if system.box!.loop.canPresent(id) {
        guard let config = system.box!.loop.windowConfiguration(id) else { return .lost }
        do {
          try system.box!.loop.presentImage(id, image: image, configSeq: config.configSeq, drawnAt: drawnAt)
          return .shown
        } catch {
          switch error {
          case .noCredit, .staleConfig: break  // a frame, or the next configure, is on its way
          default: return .lost
          }
        }
      }
      guard waited < presentGiveUp else { return .lost }
      // The frame that gives the credit back comes as an event, if one is asked for.
      system.box!.loop.requestFrame(id)
      wait(nanoseconds: 20_000_000)
      waited += 20_000_000
    }
  }

  func takeEvents() -> [WindowEvent] {
    defer { queue = [] }
    return queue
  }

  func requeue(_ events: [WindowEvent]) { queue = events + queue }

  func now() -> UInt64 { Deadline.now.ns }

  func setFullscreen(_ on: Bool) { system.box!.loop.setFullscreen(id, on) }

  func close() {
    closed = true
    system.box!.loop.closeWindow(id)
    system.windows[id] = nil
  }
}
