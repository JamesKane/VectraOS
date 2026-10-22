// SPDX-License-Identifier: BSD-3-Clause

// What feeds a window (M6j part 3e): a thread that reads a folder's watch
// or a query's live changes and delivers them to its window, then wakes
// the loop. It owns its own Volume (its own channel to the volume: a
// channel can't be shared or duplicated), and waits on a port of its own
// for its channel's changes (key 1) or the window's word (key 2): stop,
// or run a query anew. Waiting costs nothing: no wakeups while nothing
// changes.

import Fs
import Node
import Synchronization
import Sys
import Tracker

/// A watch, to hand to a thread.
final class WatchBox: @unchecked Sendable {
  var watch: Volume.Watch?
  init(_ w: consuming Volume.Watch) { watch = consume w }
  func take() -> Volume.Watch? { watch.take() }
}

/// A value handed to one thread, which then owns it.
final class Handed<T>: @unchecked Sendable {
  var value: T?
  init(_ v: T) { value = v }
  func take() -> T? {
    defer { value = nil }
    return value
  }
}

public final class Feed: Sendable {
  let port: UInt32
  let stopping = Atomic<Bool>(false)
  /// A query's text to run and its generation (the latest asked).
  let wanted = Mutex<(text: String, generation: UInt64)?>(nil)
  static let changesKey: UInt64 = 1, wordKey: UInt64 = 2

  init() throws(Status) { port = try Port.create().release() }

  deinit { _ = Handle(raw: port) }

  func word() { withPort { p in try? Port.queue(p, Packet(key: Self.wordKey)) } }

  /// The port, borrowed (it stays the feed's).
  func withPort<R>(_ body: (borrowing Handle) -> R) -> R {
    let h = Handle(raw: port)
    let r = body(h)
    _ = h.release()
    return r
  }

  /// Stops the thread (its channel closes with it).
  public func stop() {
    stopping.store(true, ordering: .sequentiallyConsistent)
    word()
  }

  /// A query's text to run (again), its changes tagged `generation`.
  public func run(_ text: String, generation: UInt64) {
    wanted.withLock { $0 = (text, generation) }
    word()
  }

  /// A folder's feed: `volume`'s watch on `path`, into `window`.
  public static func folder(_ path: String, volume: Volume, window: FolderWindow,
                            wake: @escaping @Sendable () -> Void) throws(Status) -> Feed
  {
    let feed = try Feed()
    // Watching from now (before the thread runs: a change made meanwhile
    // would be missed), the watch handed to the thread with its volume.
    guard let watch = try? volume.watch(path) else { throw .badState }
    let handed = Handed((volume, WatchBox(watch)))
    _ = try Thread.spawn {
      guard let (v, box) = handed.take(), var watch = box.take() else { return }
      _ = v
      while !feed.stopping.load(ordering: .sequentiallyConsistent) {
        feed.withPort { port in
          watch.withChannel { h in
            try? h.bind(port: port, key: Feed.changesKey, signals: Signals.readable | Signals.peerClosed, persistent: false)
          }
        }
        guard let p = feed.withPort({ port in try? Port.wait(port) }), p.key == Feed.changesKey else { continue }
        let changes = watch.changes()
        if !changes.isEmpty {
          window.deliver(changes)
          wake()
        }
      }
    }
    return feed
  }

  /// A query's feed: `volume`'s live query of what `run` asks, into
  /// `window`, each run's changes under its generation.
  public static func query(volume: Volume, window: QueryWindow, wake: @escaping @Sendable () -> Void) throws(Status)
    -> Feed
  {
    let feed = try Feed()
    let handed = Handed(volume)
    _ = try Thread.spawn {
      guard let v = handed.take() else { return }
      var generation: UInt64 = 0
      var live: Volume.LiveQuery? = nil
      while !feed.stopping.load(ordering: .sequentiallyConsistent) {
        // A new run asked: the old live query goes (its channel closes).
        if let w = feed.wanted.withLock({ $0 }), w.generation != generation {
          generation = w.generation
          live = nil
          do throws(TrackerError) {
            live = try v.live(w.text)
          } catch {
            window.failed(error, generation: generation)
            wake()
          }
        }
        if let l = live.take() {
          feed.withPort { port in
            l.withChannel { h in
              try? h.bind(port: port, key: Feed.changesKey, signals: Signals.readable | Signals.peerClosed, persistent: false)
            }
          }
          live = consume l
        }
        guard let p = feed.withPort({ port in try? Port.wait(port) }), p.key == Feed.changesKey, var l = live.take()
        else { continue }
        let changes = l.changes()
        live = consume l
        if !changes.isEmpty {
          window.deliver(changes, generation: generation)
          wake()
        }
      }
    }
    return feed
  }
}
