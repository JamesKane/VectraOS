# The IPC wire format, version 1

This is the contract between every client and server, in any language.
`system/ipc/wire` (`IPCWire`) implements it in Swift, and the C encoders that
`idlc` emits implement it in C. Neither is the definition: this file is.
The rules follow FIDL's wire format (studied, not copied; principle 29),
with the differences listed at the end.

## Messages

A message is a byte array of at most 65,536 bytes plus a side array of at
most 64 handles. Its length is a multiple of 8. All integers are
little-endian.

### Header (16 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Transaction id |
| 4 | 1 | Kind |
| 5 | 1 | Wire version: 1 |
| 6 | 2 | Flags |
| 8 | 8 | Method ordinal |

| Kind | Value | Transaction id | Body |
|---|---|---|---|
| request | 1 | nonzero for a call (set by `channel_call`); 0 for a one-way request | the method's arguments |
| reply | 2 | the request's | the method's result, or none if `canceled` |
| event | 3 | 0 | the event's arguments |
| cancel | 4 | the request to cancel | none |
| epitaph | 5 | 0 | the closing status |

- **Flags.** Two bits are defined, both on replies only:
  - bit 0, `canceled`: the request was cancelled, and there is no body;
  - bit 1, `error`: the call failed, and the body is the error (below).

  Every other bit must be zero.
- **Unknown values.** A receiver rejects a message whose version, kind or
  flags it does not know.
- **Transaction ids.** A call goes through `channel_call`, which writes a
  txid of the kernel's own into the first four bytes, with bit 31 set, and
  delivers the reply that echoes it to the caller alone. Ids a client
  assigns itself (C clients that write and read the channel) have bit 31
  clear, so the two never collide. A reply that arrives after its call gave
  up is dropped. Both ends compute the call's trace flow id from the txid
  ([trace-format.md](trace-format.md), "IPC flow ids").

### Ordinals

A protocol's id is its library's id and its name: protocol `Node` of
library `todhchai.node` is `todhchai.node.Node`. A method's ordinal is the
64-bit FNV-1a hash of `"<protocol id>.<method name>"` in UTF-8, with bit
63 cleared:
- FNV offset basis 0xcbf29ce484222325;
- FNV prime 0x100000001b3.

Ordinals with bit 63 set are reserved for the system. The `@IPCLibrary`
macro and `idlc` reject a protocol in which two methods' ordinals collide.

A protocol may compose others (`protocol Directory: NodeIPC.Node`, FIDL's
`compose`). A composed method keeps the ordinal of the protocol that
declares it, so `walk` has the same ordinal on a Directory channel as on
a Node channel, and a Node client works on either. `idlc` rejects a
composition whose methods' names or ordinals collide.

### Cancellation

A client may send `cancel` for any call it has in flight. The server then
sends exactly one of these:
- the call's normal reply;
- a reply with `canceled` set and no body.

It never sends both, and never neither (9P's `Tflush` rule). A client that
receives a normal reply after cancelling uses it.

### Error replies

A reply with the `error` flag has an 8-byte body: a 4-byte signed code,
then 4 bytes of zero padding.
- **Positive codes** are the method's own error type. A Swift method
  declared `throws(E)` uses an `Int32`-backed enum whose cases are positive.
- **Negative codes** are the framework's, the transport's status values.
  For example, a server answers a call to a method it doesn't know with
  `-2` (not supported).

### Epitaph

An epitaph is the last message before a channel closes. Its body is a
4-byte signed status and 4 bytes of zero padding.

## Bodies

A body is an **inline part** followed by **out-of-line data**.

- **The inline part** has a fixed size that the method's signature
  determines, rounded up to a multiple of 8. Each field is at an offset
  generated code knows, naturally aligned (a 4-byte integer at a multiple
  of 4).
- **Out-of-line data** is appended after the inline part, in the order the
  fields that refer to it are encoded (depth-first). Each object starts on
  an 8-byte boundary.
- **Padding.** Every padding byte, inline or out of line, is zero.
  Receivers check this.

| Type | Inline (size, alignment) | Out of line |
|---|---|---|
| Integers (`UInt8`…`Int64`) | the value (its size, its size) | — |
| `Bool` | 1 byte, 0 or 1 (1, 1) | — |
| Enum | its raw integer (its raw type's) | — |
| Byte string `[UInt8]`, `String` (UTF-8, validated by the receiver) | the count (u64), then the presence marker (u64, all ones) (16, 8) | the bytes, padded to 8 |
| Vector `[T]` | the count, then the presence marker (16, 8) | the elements, each T's inline size, then each element's own out-of-line data |
| Handle | 4 bytes: 0 if absent, all ones if present (4, 4) | the handle, next in the side array |
| Struct | its fields, laid out as a body's are (its size, its largest field's alignment) | its fields' |
| Union | 16 bytes: the tag (u64), then the presence marker (16, 8) | its case's values, laid out as a struct's fields and padded to 8, then their out-of-line data; none for a case without values |
| `T?`, T a string, vector or handle | T's, with the marker zero (and the count zero) when absent | T's, when present |
| `T?`, any other T (a box) | 8 bytes: the presence marker (8, 8) | T's inline part, padded to 8, then its out-of-line data |

- **Structs.** Fields are laid out in declaration order, each naturally
  aligned; the size is rounded up to the struct's alignment, the largest of
  its fields'. Padding is zero, as everywhere.
- **Order.** Out-of-line objects follow depth-first, in the order their
  fields are encoded: a vector's element block, then the first element's
  data, then the second's; a box's value, then its data.
- **Absent values.** An absent box, vector or string has an all-zero inline
  part. A receiver rejects any other marker, and a nonzero count with an
  absent marker.
- **Enums** are strict: a receiver rejects a value its enum doesn't list,
  so adding a case changes the type (the baseline records each enum's
  values).
- **Unions** are enums whose cases may carry values (FIDL's strict
  unions). A case's tag is its place in the declaration, from 1, and a
  receiver rejects a tag the union doesn't list. A case with values has
  the marker present and its values in a box; a case without has it
  absent, as an absent box's. Values are laid out by position, so their
  labels are not on the wire, but their order is: adding, removing or
  reordering a case changes the type (the baseline records each case's
  values in order).
- **Limits.** Vectors' elements and unions can't carry handles, and
  events can't carry handles yet. A vector's count is bounded by what the
  message holds.

Handles appear in the side array in the order their markers are encoded.
A receiver rejects a message that leaves bytes or handles unconsumed.

## Libraries

Types and protocols are declared together, in an enum marked
`@IPCLibrary(id:version:)`: its structs, integer-backed enums, unions (the
other enums), error enums (`Int32`, `IPCErrorCode`, positive codes) and
protocols. The macro sees the
whole library, so every layout is fixed when the code is generated, and
`idlc` reads the same declarations for C headers, pages and baselines. A
struct that holds handles is `~Copyable` and moves when sent.

## Differences from FIDL

- **The header.** It has a kind byte, with cancel and epitaph as kinds.
  FIDL has no cancel, and marks epitaphs with a reserved ordinal.
- **Ordinals use FNV-1a instead of SHA-256.** Ordinals are computed at
  build time by our own tools, and FNV-1a needs no cryptography code before
  the crypto foundation exists. Collisions within a protocol fail the
  build. Across protocols they don't matter, because a channel speaks one
  protocol.
- **Handles carry no rights or types on the wire.** The transport checks
  them (M0c).
- **Unions are strict and boxed.** FIDL's unions put each value in an
  envelope (its byte and handle counts) so that a flexible union's receiver
  can skip a case it doesn't know. Ours are all strict, like our enums, so
  a case's values go in an ordinary box, and a library that adds a case
  adds a method version that uses the new type.
