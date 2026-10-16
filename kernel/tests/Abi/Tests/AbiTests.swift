// SPDX-License-Identifier: BSD-3-Clause

// The kernel's Swift enums against the ABI headers (D45): object.h is the
// one source, but an enum's raw values must be literals, so this checks
// them. A case missing from a table here fails the sweep.

import CroiAbi
@testable import KernelAbi
import Testing
import TraceFormat

let statuses: [(Status, Int64)] = [
  (.internalError, CROI_ERR_INTERNAL), (.notSupported, CROI_ERR_NOT_SUPPORTED),
  (.noResources, CROI_ERR_NO_RESOURCES), (.noMemory, CROI_ERR_NO_MEMORY),
  (.invalidArgs, CROI_ERR_INVALID_ARGS), (.badHandle, CROI_ERR_BAD_HANDLE), (.wrongType, CROI_ERR_WRONG_TYPE),
  (.outOfRange, CROI_ERR_OUT_OF_RANGE), (.bufferTooSmall, CROI_ERR_BUFFER_TOO_SMALL),
  (.badState, CROI_ERR_BAD_STATE), (.timedOut, CROI_ERR_TIMED_OUT), (.shouldWait, CROI_ERR_SHOULD_WAIT),
  (.canceled, CROI_ERR_CANCELED), (.peerClosed, CROI_ERR_PEER_CLOSED), (.notFound, CROI_ERR_NOT_FOUND),
  (.alreadyExists, CROI_ERR_ALREADY_EXISTS), (.alreadyBound, CROI_ERR_ALREADY_BOUND),
  (.unavailable, CROI_ERR_UNAVAILABLE), (.accessDenied, CROI_ERR_ACCESS_DENIED), (.io, CROI_ERR_IO),
  (.ioDataIntegrity, CROI_ERR_IO_DATA_INTEGRITY), (.fileBig, CROI_ERR_FILE_BIG), (.noSpace, CROI_ERR_NO_SPACE),
]

let objectTypes: [(ObjectType, UInt32)] = [
  (.none, CROI_OBJ_TYPE_NONE), (.process, CROI_OBJ_TYPE_PROCESS), (.thread, CROI_OBJ_TYPE_THREAD),
  (.vmo, CROI_OBJ_TYPE_VMO), (.channel, CROI_OBJ_TYPE_CHANNEL), (.port, CROI_OBJ_TYPE_PORT),
  (.interrupt, CROI_OBJ_TYPE_INTERRUPT), (.log, CROI_OBJ_TYPE_LOG), (.resource, CROI_OBJ_TYPE_RESOURCE),
  (.pager, CROI_OBJ_TYPE_PAGER), (.suspendToken, CROI_OBJ_TYPE_SUSPEND_TOKEN), (.job, CROI_OBJ_TYPE_JOB),
  (.vmar, CROI_OBJ_TYPE_VMAR), (.iommu, CROI_OBJ_TYPE_IOMMU), (.bti, CROI_OBJ_TYPE_BTI), (.pmt, CROI_OBJ_TYPE_PMT),
  (.profile, CROI_OBJ_TYPE_PROFILE), (.exception, CROI_OBJ_TYPE_EXCEPTION), (.msi, CROI_OBJ_TYPE_MSI),
  (.counter, CROI_OBJ_TYPE_COUNTER), (.memoryAccount, CROI_OBJ_TYPE_MEMORY_ACCOUNT),
]

@Test func statusesAreTheHeaders() {
  for (status, value) in statuses { #expect(Int64(status.rawValue) == value, "\(status)") }
  let cases = (-200...0).filter { Status(rawValue: Int32($0)) != nil }
  #expect(cases.count == statuses.count, "a Status case object.h doesn't have")
}

@Test func objectTypesAreTheHeaders() {
  for (type, value) in objectTypes { #expect(type.rawValue == value, "\(type)") }
  let cases = (0...255).filter { ObjectType(rawValue: UInt32($0)) != nil }
  #expect(cases.count == objectTypes.count, "an ObjectType case object.h doesn't have")
}

/// The trace format's constants (TraceFormat, the readers' and writers')
/// are trace.h's (D50): one ring header, slot and format for kernel and
/// user rings.
@Test func traceRingsAreTheHeaders() {
  #expect(TraceFormat.ringHeaderSize == Int(CROI_TRACE_RING_HEADER))
  #expect(TraceFormat.ringHeaderSize == MemoryLayout<croi_trace_ring_t>.size)
  #expect(TraceFormat.slotSize == MemoryLayout<croi_trace_slot_t>.size)
  #expect(TraceFormat.recordSize == MemoryLayout<croi_trace_record_t>.size)
  #expect(TraceFormat.ringFormat == UInt64(CROI_TRACE_RING_FORMAT))
  #expect(TraceFormat.ringMagic == UInt32(CROI_TRACE_RING_MAGIC))
  #expect(TraceFormat.recordsPerPage == Int(CROI_TRACE_RECORDS_PER_PAGE))
  let offsets: [(Int, PartialKeyPath<croi_trace_ring_t>)] = [
    (TraceFormat.ringFrequency, \.frequency), (TraceFormat.ringSession, \.session),
    (TraceFormat.ringDropped, \.drops), (TraceFormat.ringFirstDrop, \.first_drop),
    (TraceFormat.ringLastDrop, \.last_drop), (TraceFormat.ringMode, \.mode), (TraceFormat.ringCPU, \.cpu),
    (TraceFormat.ringMagicOffset, \.magic), (TraceFormat.ringTid, \.thread),
  ]
  for (offset, field) in offsets { #expect(MemoryLayout<croi_trace_ring_t>.offset(of: field) == offset) }
}
