import CKernel

/// Notes (D87): Plan 9's, text posted to a process. A process that set
/// CROI_PROP_NOTIFY queues them (five, Plan 9's NNOTE), with
/// CROI_SIGNAL_PROCESS_NOTE asserted while any wait, and takes each with
/// object_get_property; one that didn't is killed by the first, as Plan
/// 9's default is, and keeps the note for whoever reads its handle after.
/// Posting needs CROI_RIGHT_NOTE (the proc service's, D79); no syscall is
/// added. Zircon has none: its closest, signals on a task, carry no text.
typealias NoteText = InlineArray<128, UInt8>

enum Notes {
    static var queue: Int { Int(CROI_NOTE_QUEUE) }

    /// A note from user memory: 1 to 127 bytes, none of them NUL.
    static func fromUser(_ address: UInt64, _ size: UInt64) throws(Status) -> NoteText {
        guard size > 0, size < UInt64(CROI_NOTE_MAX) else { throw .invalidArgs }
        var text = NoteText(repeating: 0)
        var span = text.mutableSpan
        let copied = span.withUnsafeMutableBytes { raw in unsafe UserCopy.from(raw.baseAddress!, address, size) }
        guard copied == 0 else { throw .invalidArgs }
        for i in 0..<Int(size) where text[i] == 0 { throw .invalidArgs }
        return text
    }

    /// Posts `text` to the process `object`: queued if it takes notes, and
    /// it is killed by the note if not. SHOULD_WAIT if its queue is full,
    /// BAD_STATE unless it is running.
    static func post(_ object: ObjectPointer, _ text: NoteText) throws(Status) {
        let process = ProcessPointer(object: object)
        let kill = try object.header.lock.withLock { () throws(Status) -> Bool in
            guard process.pointee.state == .running else { throw .badState }
            guard process.pointee.notify else {
                process.pointee.diedOf = text
                return true
            }
            let count = process.pointee.noteCount
            guard count < queue else { throw .shouldWait }
            process.pointee.notes[count] = text
            process.pointee.noteCount = count + 1
            let before = object.header.signals
            object.header.signals = before | Signals.processNote
            Observers.notify(object, before: before)
            return false
        }
        if kill { Processes.kill(process: object, code: TaskReturnCode.noteKill) }
    }

    /// The oldest note the process `object` holds, taken; SHOULD_WAIT if
    /// it holds none.
    static func take(_ object: ObjectPointer) throws(Status) -> NoteText {
        let process = ProcessPointer(object: object)
        return try object.header.lock.withLock { () throws(Status) -> NoteText in
            let count = process.pointee.noteCount
            guard count > 0 else { throw .shouldWait }
            let text = process.pointee.notes[0]
            for i in 1..<count { process.pointee.notes[i - 1] = process.pointee.notes[i] }
            process.pointee.noteCount = count - 1
            if count == 1 {
                let before = object.header.signals
                object.header.signals = before & ~Signals.processNote
                Observers.notify(object, before: before)
            }
            return text
        }
    }

    /// The note the process `object` died of; BAD_STATE if it is alive or
    /// died of something else.
    static func diedOf(_ object: ObjectPointer) throws(Status) -> NoteText {
        let process = ProcessPointer(object: object)
        return try object.header.lock.withLock { () throws(Status) -> NoteText in
            guard process.pointee.state == .dead || process.pointee.state == .dying,
                  process.pointee.returnCode == TaskReturnCode.noteKill else { throw .badState }
            return process.pointee.diedOf
        }
    }

    /// CROI_PROP_NOTIFY: whether the process `object` takes its notes.
    static func setNotify(_ object: ObjectPointer, _ on: Bool) {
        let process = ProcessPointer(object: object)
        object.header.lock.withLock { process.pointee.notify = on }
    }
}
