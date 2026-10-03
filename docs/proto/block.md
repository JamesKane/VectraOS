# The `block` class protocol

Status: draft, written for M5 step 1 (11 §10). Frozen when `fsd` (step 4) is its first file-system client. `lib/vx-driver/blockproto.h` is its C definition.

A block driver serves a disk on its post (`/srv/disk0`, `/srv/disk1`, …, in the order `devmgr` finds the devices). A client opens a session on a connector, and the session is a ring (01 §4.3) that reaches one **window** of the disk: a range of its sectors, perhaps read-only. A session never reaches outside its window. The driver's own post gives the whole disk; partitions are windows that `partd` hands out on posts of their own (§6).

## 1. Opening a session

The connector's one request is `CONNECT` (`0x6b6c_6263`, "cblk"), sent with `channel_call`:

| Field | Bytes | Meaning |
|---|---|---|
| header | 16 | `vx_msg_header`, ordinal `CONNECT` |
| `first` | 8 | the window's first sector, counted in the connector's own window |
| `count` | 8 | its sectors; 0 for all of them from `first` |
| `flags` | 4 | `READONLY` (1): the session may not write |
| reserved | 4 | zero |

- **The reply** is a `vx_msg_header` with two handles: the client's ring end and the ring's memory, as for every ring session (`lib/vx-ring/session.c`).
- **A refusal** has `flags` set and no handles: a window outside the connector's (`RANGE`), a write session on a read-only device or window (`ACCESS`), or no room for another session (`NO_MEMORY`). A driver serves at least 8 sessions at once.
- **Windows nest:** a connector that itself reaches only a window (§6) counts `first` from that window's start, and caps `count` at its end.

The ring's parameters (`VX_BLOCK_PARAMS`):

| Parameter | Value |
|---|---|
| Submission and completion queues | 128 entries each |
| Entries | `vx_sqe` (64 bytes) and `vx_cqe` (32) |
| Client arena | 1 MiB: the buffers every transfer reads from or writes into |
| Server arena | none |

## 2. Requests

Every request is one `vx_sqe`, and is completed exactly once by one `vx_cqe` with the same `user_data`. Completions come in any order; nothing is ordered between requests but what `FLUSH` says (§3).

| Opcode | Request | Completion |
|---|---|---|
| `INFO` (1) | nothing | `result` the most bytes one transfer may move; `aux` the sector size in bytes; `aux2` the window's sectors; `flags` `INFO_READONLY` (1), `INFO_CACHE` (2: the device has a volatile write cache, so `FLUSH` matters), `INFO_DISCARD` (4: `DISCARD` reaches the device) |
| `READ` (2) | `target` the first sector, in the window; `arena_off` and `len` (with `VX_SQE_DREF`) the client-arena range to fill | `result` the bytes read, `len`, or a negative status |
| `WRITE` (3) | as `READ`: the range to write from | `result` the bytes written, or a negative status |
| `WRITE_FUA` (4) | as `WRITE` | as `WRITE`, but complete only once this write is durable |
| `FLUSH` (5) | nothing | `result` 0, once every write that completed before the `FLUSH` was submitted is durable |
| `DISCARD` (6) | `target` the first sector; `offset` the number of sectors | `result` 0. The sectors' contents are undefined until written again. A device that cannot discard completes it at once, as success: a discard is a hint |

**Transfers.** For `READ`, `WRITE` and `WRITE_FUA`:
- `len` is a multiple of the sector size, at least one sector, and at most `INFO`'s `result`.
- `arena_off` is a multiple of the sector size, and `[arena_off, arena_off + len)` lies inside the client arena.
- `[target, target + len / sector)` lies inside the window.

Anything else completes with `INVALID` (alignment, a length) or `RANGE` (outside the window or the arena) without reaching the device. A write in a read-only session completes with `ACCESS`.

**Zero copy.** The driver gives the client arena to the device through its DMA domain (01 §7.1). The device reads and writes it directly, and the driver never copies a transfer. A client must not touch a range while a request on it is outstanding: what it reads back then is undefined, and what reaches the disk from it is whatever the device saw.

**Errors.** A device error is `IO` (`VX_ERR_IO`). A request the driver cannot take now is not refused: the driver stops reading the session's submissions until it can, so a client keeps at most 128 requests outstanding (the completion queue's size). A driver whose completion queue for a session is full drops that session.

## 3. Durability

- **Completion is not durability.** A completed `WRITE` may still sit in the device's volatile cache. It is durable once a `FLUSH` submitted after its completion has completed, or if it was a `WRITE_FUA`.
- **This is all a file system needs.** `fsd`'s commit (11 §6) submits its writes, waits for their completions, and submits `FLUSH`: a barrier.
- **A device without a volatile cache** (`INFO_CACHE` clear) completes `FLUSH` at once, and `WRITE_FUA` as `WRITE`.
- **A device without FUA** gets a `WRITE` followed by a flush, and the client's `WRITE_FUA` completes after both. virtio-blk is such a device.

## 4. Restarts

A driver that exits loses its sessions: clients see `PEER_CLOSED` on their ring ends. `devmgr` starts it again on the same post (01 §7.4).
- A client dials again, sends `INFO`, and submits every request it had not seen complete. The driver keeps nothing across a restart.
- A write that was in flight may or may not have reached the disk, so resubmitting it is safe: writes are idempotent.

## 5. Sessions and their windows

The session's window is fixed when it is opened. The session itself is a capability: whoever holds the ring end and its memory reaches the window, and nothing else.

## 6. Partitions: `partd`

Partitions are windows handed out by `partd`, so no server sees sectors outside its own:
1. `partd` holds a connector to the whole disk (its manifest's `connect=disk0`).
2. It reads the GPT through a session of its own (`lib/vx-gpt`, primary header first, the backup if the primary is damaged; both are checked against their CRCs).
3. It claims one post per partition that its manifest names, as `part=POST type=GUID` or `part=POST name=NAME`, matched against each GPT entry's type GUID or name.
4. A `CONNECT` on a partition's post is answered by `partd`, which opens a session on the disk with the window narrowed to that partition, passes the driver's reply through unchanged, and keeps nothing of it. A client's `first` and `count` are counted in the partition.

Two partition types matter:

| Partition | Type GUID |
|---|---|
| The EFI system partition | `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` |
| The VectraOS system volume (`fsd`, 11 §10) | `7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35`, VectraOS's own |

`partd` refuses a GPT whose entries overlap, or lie outside the disk's usable range, and serves none of its partitions.

## 7. Conformance

`tests/user/blktest.c`, in `tests/qemu/block.ndb`, checks a driver against this protocol:
- `INFO`;
- reads and writes across sector and page boundaries;
- `FLUSH` and `WRITE_FUA`;
- every refusal in §2;
- several sessions at once;
- a read-only window;
- the driver killed with requests in flight, and the session dialled again.

The same test runs against `partd`'s posts for the windows of §6.
