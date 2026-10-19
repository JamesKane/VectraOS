// SPDX-License-Identifier: BSD-3-Clause

// Undo (M6i part 6, decided 2026-10-12 after the 1990s HIGs: the
// Macintosh's promise that every edit can be taken back). An `UndoStack`
// keeps changes as the values before and after each (a document's state
// is the program's, and Swift's values are cheap to keep); a change in the
// same group as the last one joins it, as typing a word does, so one Undo
// takes the word back. Undo and Redo are declared actions (`edit.undo`,
// Control-Z; `edit.redo`, Control-Shift-Z), so they get their menu items,
// keys, scripting and accessibility entries like any other.
//
// A text field keeps its own stack (by key, as long as it is built) and
// takes Undo and Redo while it has focus: typed text joins into a run
// until a space ends a word, the caret moves, or deleting follows typing;
// the program's own stack takes them otherwise (`editingText` says which).

/// What a stack records: the value before a change and after it.
public struct UndoStack<Value: Sendable>: Sendable {
  struct Entry: Sendable {
    var label: String
    var before: Value
    var after: Value
    var group: UInt64
  }

  var entries: [Entry] = []
  /// Entries below this are done; those from it on, undone (to redo).
  var position = 0
  /// How many changes it keeps.
  public var limit = 200

  public init() {}

  public var canUndo: Bool { position > 0 }
  public var canRedo: Bool { position < entries.count }
  /// What Undo and Redo would take back or do again ("Typing").
  public var undoLabel: String? { canUndo ? entries[position - 1].label : nil }
  public var redoLabel: String? { canRedo ? entries[position].label : nil }

  /// Records a change, `label` naming it; in the same nonzero `group` as
  /// the last change (and nothing undone since), it joins that one.
  public mutating func record(_ label: String, before: Value, after: Value, group: UInt64 = 0) {
    if group != 0, position == entries.count, let last = entries.last, last.group == group {
      entries[entries.count - 1].after = after
      return
    }
    entries.removeSubrange(position...)
    entries.append(Entry(label: label, before: before, after: after, group: group))
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
    position = entries.count
  }

  /// The value to go back to, if there's a change to take back.
  public mutating func undo() -> Value? {
    guard canUndo else { return nil }
    position -= 1
    return entries[position].before
  }

  /// The value to go forward to, if there's a change to do again.
  public mutating func redo() -> Value? {
    guard canRedo else { return nil }
    position += 1
    return entries[position - 1].after
  }

  /// Forgets everything.
  public mutating func clear() {
    entries.removeAll()
    position = 0
  }
}

/// A text field's state, as its undo stack keeps it.
struct FieldState: Sendable {
  var text: [UInt32]
  var caret: Int
  var anchor: Int
}

/// A field's history: its stack, and the run its last edit was in.
struct FieldHistory: Sendable {
  var key: UInt64
  var stack = UndoStack<FieldState>()
  /// The kind of the last edit (1 typing, 2 deleting), where its caret
  /// ended, whether it ended a word, and its group.
  var kind = 0
  var caret = -1
  var wordEnded = false
  var group: UInt64 = 0
  var frame: UInt64 = 0
}

extension UI {
  /// Undo and Redo, declared (if they aren't already) with Control-Z and
  /// Control-Shift-Z.
  public mutating func declareUndo() {
    if actionIndex("edit.undo") == nil {
      declare(Action("edit.undo", label: "Undo", key: KeyPress(.character(0x7A), control: true)))
    }
    if actionIndex("edit.redo") == nil {
      declare(Action("edit.redo", label: "Redo", key: KeyPress(.character(0x7A), shift: true, control: true)))
    }
  }

  /// Cut, Copy and Paste, declared (if they aren't already) with
  /// Control-X, Control-C and Control-V: the focused field's or text
  /// area's, through `clipboard`.
  public mutating func declareEditing() {
    for (name, label, c) in [("edit.cut", "Cut", 0x78), ("edit.copy", "Copy", 0x63), ("edit.paste", "Paste", 0x76)]
    where actionIndex(name) == nil {
      declare(Action(name, label: label, key: KeyPress(.character(UInt32(c)), control: true)))
    }
  }

  /// Whether a text field has focus (it takes Undo and Redo).
  public var editingText: Bool {
    focus != 0 && (slot(focus).map { slots[$0].flags.contains(.editable) } ?? false)
  }

  mutating func history(_ key: UInt64) -> Int {
    if let i = fieldHistories.firstIndex(where: { $0.key == key }) { return i }
    fieldHistories.append(FieldHistory(key: key))
    return fieldHistories.count - 1
  }
}

/// What a field's Cut, Copy and Paste reach: the platform's clipboard
/// (D112), its text.
public struct Clipboard: Sendable {
  public var read: @Sendable () -> String?
  public var write: @Sendable (String) -> Void
  public init(read: @escaping @Sendable () -> String?, write: @escaping @Sendable (String) -> Void) {
    self.read = read
    self.write = write
  }
}
