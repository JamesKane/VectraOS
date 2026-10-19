// SPDX-License-Identifier: BSD-3-Clause

// The accessibility tree (M6i part 4, sdk.md §10): every frame also
// produces, as a side output, the tree an assistive client reads (roles,
// labels, values, states, rectangles, and the action each node performs).
// It is the box tree with the boxes that mean nothing to a reader left out
// (a box without a role; its children go to its nearest ancestor that has
// one), in flat arrays reused frame to frame, a parent before its
// children. Rectangles are the window's, in logical pixels; Radharc's
// `a11y` service puts them in screen coordinates.
//
// A box's role is the widget's (a button, a text field, a list and its
// rows), else from its flags: a clickable box with text is a button, a
// box with text a label. The root is the window, labelled with `title`.

import AccessTree

extension UI {
  /// Describes the box built last for the tree: its role, and a label or
  /// value beyond its text.
  public mutating func accessible(_ role: Role, label: String? = nil, value: String? = nil,
                                  states: AccessStates = [])
  {
    let i = boxes.count - 1
    boxes[i].role = role
    if let label { boxes[i].label = label }
    if let value { boxes[i].value = value }
    boxes[i].states.formUnion(states)
  }

  /// Builds this frame's tree from its boxes (after layout).
  mutating func buildAccessibility() {
    access.removeAll(keepingCapacity: true)
    nodeOf.removeAll(keepingCapacity: true)
    for (i, b) in boxes.enumerated() {
      var role = b.role
      if i == 0 {
        role = .window
      } else if role == .none {
        if b.flags.contains(.clickable) && b.flags.contains(.text) {
          role = .button
        } else if b.flags.contains(.text) {
          role = .label
        }
      }
      // The nearest ancestor in the tree.
      let parent = b.parent >= 0 ? nodeOf[Int(b.parent)] : -1
      guard role != .none else {
        nodeOf.append(parent)
        continue
      }
      var states = b.states
      if b.flags.contains(.focusable) { states.insert(.focusable) }
      if b.flags.contains(.editable) { states.insert(.editable) }
      if b.key == focus && focus != 0 { states.insert(.focused) }
      let label = i == 0 ? title : b.label.isEmpty ? b.text : b.label
      nodeOf.append(Int32(access.count))
      access.append(AccessNode(key: b.key, parent: parent, role: role, label: label, value: b.value, x: b.rect.x,
                               y: b.rect.y, width: b.rect.width, height: b.rect.height, states: states,
                               action: b.action))
    }
  }

  /// This frame's tree with its actions' names, to send (in logical
  /// pixels: scale it to the window's).
  public var accessTree: AccessTree { AccessTree(nodes: access, actions: actions.map { $0.name }) }

  /// The node an assistive client asked to press, by key: its action's
  /// invocation for the next frame, or (with no declared action) a press
  /// of its control, as Enter on it focused would be.
  public mutating func press(_ key: UInt64) throws(PerformError) {
    guard let n = access.first(where: { $0.key == key }) else { throw .noSuchAction }
    if n.action >= 0 {
      try perform(actions[Int(n.action)].name, from: .accessibility)
    } else if n.role == .button || n.role == .menuItem || n.role == .row || n.role == .toggle {
      pressRequest = key
    } else {
      throw .noSuchAction
    }
  }
}
