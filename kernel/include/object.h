// Statuses, rights and object types: the ABI every call shares, kernel
// and user space (user/include/croi/syscall.h includes it). Zircon's values
// (zircon/errors.h, rights.h, types.h). The one source (D45): the kernel's
// Swift enums (Object/Status.swift) must use literals, so a host test
// (kernel/tests/Abi) checks them against this file. Subsystem headers add
// their own: CROI_RIGHT_RESIZE (vmo.h), CROI_RIGHT_CHARGE and
// CROI_OBJ_TYPE_MEMORY_ACCOUNT (account.h), CROI_OBJ_TYPE_SUSPEND_TOKEN
// (task.h); the signals are each object's header's (ipc.h, task.h,
// counter.h).
#pragma once
#include <stdint.h>

enum : int64_t {  // a call's status: 0, or negative
  CROI_OK = 0,
  CROI_ERR_INTERNAL = -1,
  CROI_ERR_NOT_SUPPORTED = -2,
  CROI_ERR_NO_RESOURCES = -3,
  CROI_ERR_NO_MEMORY = -4,
  CROI_ERR_INVALID_ARGS = -10,
  CROI_ERR_BAD_HANDLE = -11,
  CROI_ERR_WRONG_TYPE = -12,
  CROI_ERR_OUT_OF_RANGE = -14,
  CROI_ERR_BUFFER_TOO_SMALL = -15,
  CROI_ERR_BAD_STATE = -20,
  CROI_ERR_TIMED_OUT = -21,
  CROI_ERR_SHOULD_WAIT = -22,
  CROI_ERR_CANCELED = -23,
  CROI_ERR_PEER_CLOSED = -24,
  CROI_ERR_NOT_FOUND = -25,
  CROI_ERR_ALREADY_EXISTS = -26,
  CROI_ERR_ALREADY_BOUND = -27,
  CROI_ERR_UNAVAILABLE = -28,
  CROI_ERR_ACCESS_DENIED = -30,
  CROI_ERR_IO = -40,
  CROI_ERR_IO_DATA_INTEGRITY = -42,
  CROI_ERR_FILE_BIG = -53,
  CROI_ERR_NO_SPACE = -54,
};

enum : uint32_t {  // rights
  CROI_RIGHT_DUPLICATE = 1u << 0,
  CROI_RIGHT_TRANSFER = 1u << 1,
  CROI_RIGHT_READ = 1u << 2,
  CROI_RIGHT_WRITE = 1u << 3,
  CROI_RIGHT_EXECUTE = 1u << 4,
  CROI_RIGHT_MAP = 1u << 5,
  CROI_RIGHT_GET_PROPERTY = 1u << 6,
  CROI_RIGHT_SET_PROPERTY = 1u << 7,
  CROI_RIGHT_ENUMERATE = 1u << 8,
  CROI_RIGHT_DESTROY = 1u << 9,
  CROI_RIGHT_GET_POLICY = 1u << 10,
  CROI_RIGHT_SET_POLICY = 1u << 11,
  CROI_RIGHT_SIGNAL = 1u << 12,
  CROI_RIGHT_NOTE = 1u << 13,  // croi's (D87): post notes to a process
  CROI_RIGHT_WAIT = 1u << 14,
  CROI_RIGHT_INSPECT = 1u << 15,
  CROI_RIGHT_MANAGE_JOB = 1u << 16,
  CROI_RIGHT_MANAGE_PROCESS = 1u << 17,
  CROI_RIGHT_MANAGE_THREAD = 1u << 18,
  CROI_RIGHT_APPLY_PROFILE = 1u << 19,
  CROI_RIGHT_OP_CHILDREN = 1u << 21,
  CROI_RIGHT_ATTACH_VMO = 1u << 23,
  CROI_RIGHT_MANAGE_VMO = 1u << 24,
  CROI_RIGHT_SAME_RIGHTS = 1u << 31,  // handle_duplicate: the source's rights
  CROI_RIGHTS_BASIC = CROI_RIGHT_TRANSFER | CROI_RIGHT_DUPLICATE | CROI_RIGHT_WAIT | CROI_RIGHT_INSPECT,
};

enum : uint32_t {  // object types (CROI_INFO_HANDLE_BASIC's type)
  CROI_OBJ_TYPE_NONE = 0,
  CROI_OBJ_TYPE_PROCESS = 1,
  CROI_OBJ_TYPE_THREAD = 2,
  CROI_OBJ_TYPE_VMO = 3,
  CROI_OBJ_TYPE_CHANNEL = 4,
  CROI_OBJ_TYPE_PORT = 6,
  CROI_OBJ_TYPE_INTERRUPT = 9,
  CROI_OBJ_TYPE_LOG = 12,
  CROI_OBJ_TYPE_RESOURCE = 15,
  CROI_OBJ_TYPE_JOB = 17,
  CROI_OBJ_TYPE_VMAR = 18,
  CROI_OBJ_TYPE_IOMMU = 23,
  CROI_OBJ_TYPE_BTI = 24,
  CROI_OBJ_TYPE_PROFILE = 25,
  CROI_OBJ_TYPE_PMT = 26,
  CROI_OBJ_TYPE_PAGER = 28,
  CROI_OBJ_TYPE_EXCEPTION = 29,
  CROI_OBJ_TYPE_MSI = 32,
  CROI_OBJ_TYPE_COUNTER = 34,
};
