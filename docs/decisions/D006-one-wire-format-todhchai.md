# D6. One wire format: todhchai's IPC wire format, not FlatBuffers (2026-10-15, proposed)

The paper asks for FlatBuffers so ring payloads can be read in place. The IPC
wire format already gives that: little-endian, 8-byte aligned and decoded in
place. It is also what the Node protocol uses. Adopting FlatBuffers as well
would mean two encodings (principle 7).

- **Ring payloads** use the wire format's layout rules, with no message
  header.
