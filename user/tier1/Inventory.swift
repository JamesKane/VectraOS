// SPDX-License-Identifier: BSD-3-Clause

// A library module for bin/swift-hello (M6e): generic types and protocols
// with associated types, used and specialized from another module.

public protocol Weighed {
  associatedtype Unit: Numeric & Comparable
  var weight: Unit { get }
}

public struct Shelf<Item: Weighed> {
  public private(set) var items: [Item] = []
  public init() {}
  public mutating func put(_ item: Item) { items.append(item) }
  public var total: Item.Unit { items.reduce(0) { $0 + $1.weight } }
  public func heaviest() -> Item? { items.max { $0.weight < $1.weight } }
}

/// A class whose deinit says it ran.
open class Tracked {
  public static var alive = 0
  public let name: String
  public init(name: String) {
    self.name = name
    Tracked.alive += 1
  }
  deinit { Tracked.alive -= 1 }
  open func describe() -> String { "tracked \(name)" }
}
