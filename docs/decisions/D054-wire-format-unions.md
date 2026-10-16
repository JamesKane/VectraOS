# D54. The wire format gains unions (2026-10-16, decided)

D18 makes a Node message a batch of operations, and each operation is
one of several kinds with values of its own. The wire format (D6) had
structs, enums, vectors and optionals, but nothing that holds one of
several shapes. It gains strict tagged unions, so that a batch is a vector
of them; there is still one wire format (principle 7), now with one more
type.
- **In a library,** a union is an enum without an integer raw type,
  whose cases may carry values: `enum Op { case walk(names: [String]),
  case remove }`. The macro, idlc's C header (a struct with `tag` and an
  anonymous union of the cases' values), pages and baselines know it.
- **On the wire** it is 16 bytes inline: the tag (the case's place, from
  1) and a box's presence marker; out of line, the case's values laid out
  as a struct's fields, absent for a case without values
  (`docs/wire-format.md`). The values ride in an ordinary box, not FIDL's
  envelopes: like our enums, every union is strict, so a receiver never
  skips a case it doesn't know, and a new case is a new type behind a new
  method version.
- **No handles in unions** (v1): a union is copyable, so a vector can
  hold it. Node's batch carries its one handle beside the results.
- **Rejected:** a flat operation struct (every kind's fields in one
  struct, most unused, about 100 bytes inline each, frozen into Node v1
  by principle 16), and batching at the IPC layer (several requests in
  one message), which would need a Node-specific hook for a later
  operation to use an earlier one's node.
- **Tests:** the test library's `Step` (each kind of value, inline in a
  struct, in vectors, optional): Swift and C encode the same bytes,
  decode alike and agree on 20,000 mutated replies (IDLTests); the
  baseline records each case's values in order, and adding, removing or
  reordering a case breaks it; the macro refuses handles, an empty
  union, raw values and unknown types; `draw` runs hosted (IPCTests) and
  natively from Swift and C (bin/ipc-test).
