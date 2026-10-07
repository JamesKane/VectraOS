# 16 — Swift SDKs over the native API: design notes

_Design notes, 2026-10-07. **Non-binding.** These notes set out how the Swift modules that sit on `libvx`, `vxui` and the engine tier (`VX`, `VXUI`, `VXEngine`, ADR-0034 §2) should be shaped so they do not repeat the habits that make object-oriented code scale badly on modern CPUs. Nothing here changes a rule in 00 or ADR-0034. §5's rules become binding through an ADR when `VX` is scheduled (M6 6e3, with `swift-on-vectra`'s bindings, findings.md §8)._

## 1. The problem

A modern core is fast when it streams through contiguous memory and slow when it waits on it: a miss to main memory costs hundreds of cycles, and the prefetchers only help with predictable access. Conventional object-oriented design works against that in four ways:

- **One heap object per thing.** Each element is its own allocation, scattered, with a header, so a loop over a thousand of them is a thousand pointer chases.
- **Dispatch per element.** Virtual calls and protocol existentials cost an indirect call each, but the larger cost is Casey Muratori's: "the resulting inability to merge code paths, both your inability and the compiler's." The loop can never be specialised, vectorised or reordered.
- **Shared ownership everywhere.** Reference counting adds an atomic operation per reference handed around, and those atomics contend between cores.
- **A lock or a mailbox per object.** Serialising each object on its own makes parallel work into handoffs.

Mike Acton's rule from 2014 still frames the answer: **"where there is one, there are many."** Design for the batch, lay data out for the way it is read, and let the code be a function over the data.

## 2. What research and industry have found

- **Measured gains from layout alone.** Andrew Kelley's data-oriented rewrite of Zig's compiler (indices instead of pointers; `MultiArrayList`, a struct of arrays behind an `ArrayList`'s interface, so switching layout is a "5-character change") cut wall-clock time by 20% in tokenising and parsing and 40% in IR generation.
- **Archetype tables.** "The Essence of Entity Component System" (ACM SAC '26) measured one simulation at 36 fps as objects, 62 as an array of structs, 66 as archetype struct-of-arrays and 110 with that parallelised, with steadier frame times. Its API advice: separate data from behaviour, declare each system's reads and writes, defer structural changes to synchronisation points, and parallelise both between systems and within them. Bevy's ECS made the same choice: archetype tables, one column per component and one row per entity, for iteration, with sparse sets kept for components that come and go often.
- **Struct-of-arrays as a language feature.** Odin's `#soa` is in the language. Rust has `soa_derive` and `soa-rs`. Barry Revzin built `SoaVector<T>` with C++26 reflection (2025), with one size and capacity for all columns rather than one vector per field.
- **Ids, not pointers, at boundaries.** The platform API study found three independent designs (sokol, Godot, bevy) converging on index-plus-generation handles (study/shapes.md C9). 09 §4.4 adopted it.
- **Swift has the pieces now.** `InlineArray` (fixed-size, stored inline, SE-0453) and `Span` and `MutableSpan` (bounds-checked views that do not own or copy, SE-0447, SE-0467) arrived with Swift 6.2. Noncopyable types (`~Copyable`) and non-escapable types (`~Escapable`, SE-0446) give ownership and borrowed views the compiler checks, with lifetime dependencies still experimental. `BitwiseCopyable` (SE-0426) marks types that copy as plain bytes, with no reference counting. The performance annotations `@_noAllocation` and `@_noLocks` make the compiler reject allocation or locking in a function. Apple's own guidance (WWDC24, "Explore Swift performance") is that inline or out-of-line storage sets a value's copy cost and its ARC traffic.
- **A cautionary half-way house.** RealityKit is Apple's ECS in Swift: its components are structs, but its `Entity` is a class in a hierarchy, so every entity still carries a heap object and its reference counting.

## 3. Where Swift's defaults cost the most

| Pattern | What it costs |
|---|---|
| A `class` instance per element | A heap block per element with a 16-byte header (metadata and reference count), scattered; an atomic retain and release for references passed around |
| `[any Protocol]` | A 40-byte existential container per element, sometimes boxed on the heap, and dispatch through a witness table the optimiser cannot see through |
| A class hierarchy with overrides | Muratori's unmerged paths: no specialisation, no vectorisation |
| An `actor` per entity | An executor hop and a queued job for each interaction |
| `String` or `Array` fields inside each element | An out-of-line buffer per field, each reference counted and copy-on-write checked |
| Escaping closures stored per element | A heap-allocated context per closure |
| A shared `VX` built with library evolution (findings.md §8.5) | Non-`@frozen` structs reached through metadata for their size and layout, and no specialisation of generics across the library boundary |

The last row matters to us in particular: 09 §4.8 makes `libvx` and `vxui` shared libraries once the loader exists (M6 6f), and a resilient Swift module over them would pay that cost on every hot type unless it is designed for it (§7).

## 4. The C API is already the right shape

09 was written with the same aims, so the Swift layer extends it rather than fighting it:

| 09 | Already data-oriented because |
|---|---|
| §4.3: `libvx` never allocates behind the caller; arenas, pools, an explicit `vx_heap` | Memory is the program's, laid out by the program |
| §4.4: index-plus-generation ids across processes | No pointers to chase or to dangle |
| §4.6: hot calls take arrays and counts | The batch is the unit |
| §4.7: one 64-byte event record; variable data as a slice valid until the next wait | Events are a dense array, and their payloads are borrowed |
| §3: the one-hop rule | Costs are visible, so they can be batched |
| 03 §6: `vxui`, immediate-mode with a retained cache keyed by stable ids; a per-frame arena | No widget objects at all |

The risk is a Swift layer that wraps each of these in a class "for convenience" and undoes it.

## 5. Seven rules for the Swift SDKs

**1. Plural by default.** An SDK call that touches data takes and returns batches: `Span` in, `MutableSpan` or a caller's buffer out. `loop.wait(into: &events)` fills many events; `files.submit(requests)` sends many requests. The reference's examples are written for many items, never one.

**2. Identity is an id.** Things the SDK hands out by identity are values:

```swift
@frozen public struct ID<Tag>: BitwiseCopyable, Hashable, Sendable {
  public let index: UInt32
  public let generation: UInt32
}
```

Eight bytes, never reference counted, and a stale one fails with `BAD_HANDLE` as 09 §4.4's do. Many things are held in a `Pool<Tag, Element>` of slots, not in a graph of objects.

**3. Columns, with plain elements.** A `@Columns` macro on a plain struct generates its struct-of-arrays storage:

```swift
@Columns struct Particle {
  var position: SIMD2<Float>
  var velocity: SIMD2<Float>
  var life: Float
}

var particles = Particle.Columns(capacity: 4096, in: arena)
particles.append(Particle(position: p, velocity: v, life: 1))
particles.withColumns { position, velocity, life in   // MutableSpans
  for i in position.indices { position[i] += velocity[i] * dt; life[i] -= dt }
}
```

- One count and one capacity for every column, as Revzin's design has it.
- Backed by a `libvx` arena or a VMO, never by one Swift `Array` per field.
- Every column's element is `BitwiseCopyable`, which the macro checks, so a loop over a column can never retain, release or check uniqueness. Text goes in as an id into an interned-string arena, or as a slice of one.
- Changing a type between an array of structs and columns is a one-line change, as it is with Zig's `MultiArrayList`.

**4. Closed sets are enums; behaviour is a function over a column.** For variation, in order of preference:

- an `enum` with payloads and an exhaustive `switch`, for a closed set of kinds;
- a partition by kind, each kind in its own columns, one tight loop per kind (archetypes, as Bevy's tables are);
- generics with `some P`, specialised at compile time.

`any P` belongs only at cold edges (registering a plug-in, reading configuration), never in a collection or a loop.

**5. Classes and ARC per subsystem, never per element.** ADR-0034 §4 already keeps ARC for shared ownership. The rule of thumb in the SDK: a class may own a whole table (a document, a session, a `Loop`), and nothing a row holds is a class.

**6. Borrowed views cannot escape.** 09 §4.7's "valid until the next wait" is exactly a non-escapable `Span` whose lifetime depends on borrowing the loop, so the compiler enforces what 09 states in prose. Scratch arenas (`withScratch { arena in … }`) are the same, and handles stay `~Copyable` with `deinit` closing them (findings.md §8.4).

**7. Concurrency over chunks, not objects.** Actors and `@MainActor` serialise subsystems. Bulk work is a task group splitting a column into disjoint `MutableSpan` chunks, so Swift's strict concurrency checks that no two tasks share a chunk. Jobs declare the columns they read and write, as the ECS paper's systems do, so a small scheduler can run jobs that do not conflict at the same time, on the `throughput` pool (ADR-0034 §3).

## 6. What it means for each module

- **`VX`** (over `libvx`): batch-first calls; ids and `~Copyable` handles; events borrowed from the loop; `throws(VX.Error)` at the boundary as findings.md §8.4 plans. No class per file or per request: a `File` is a noncopyable handle, a batch of reads is a span of requests.
- **`VXUI`** (over `vxui`, M7): calls as flat as the C (`ui.button("Run")`), non-escaping closures only for nesting scopes (`ui.row { … }`), the same stable ids, and no retained tree of view objects or observable object graph. The app's state is its own data, often columns, and the UI reads it each frame. Layout and paint carry `@_noAllocation`.
- **`VXEngine`** (the engine tier): columns, pools and the chunked job scheduler as building blocks, and the event and frame records as 03 §4 defines them. An archetype store may come later as a library, but no ECS framework is imposed: a game chooses its own.
- **`VXData`**, a small module the others share: `@Columns`, `ID`, `Pool`, `ArenaArray<T: BitwiseCopyable>`, interned strings. One vocabulary, so `VX`, `VXUI`, `VXEngine` and an app pass the same layouts to each other without converting.

## 7. Shared libraries, `@frozen` and `@inlinable`

When `libvx` and `vxui` become shared (09 §4.8), a shared `VX` needs library evolution to be updated with the release (findings.md §8.5). Library evolution makes every non-`@frozen` struct opaque to its clients and stops generics specialising across the boundary, which is the cost §3's last row names.

The way through is a split by temperature:

- **Hot types are `@frozen` and their operations `@inlinable`:** `ID`, the column views, `Span`-taking batch calls, the event view. They compile into the app, as header-only code does, and the boundary costs nothing in a loop.
- **Cold calls cross the boundary:** opening, configuring, spawning, dialling. These cost one call more than in a static link, which 09 §4.8 already accepts.
- **Freezing is an ABI promise.** A frozen type's layout is part of the release's ABI from then on, so which types are frozen, and when one may change, belongs beside 09 §4.8's ABI levels in the same decision.

## 8. Enforcing it

`./build check` grows Swift checks beside ADR-0034 §4's:

- no `any` in a public SDK signature on a path marked hot;
- no class, `String` or `Array` as a column element (the macro refuses it; the check catches hand-written columns);
- performance annotations on frame, layout and audio paths, checked by the compiler;
- a benchmark per data structure in `VXData`, with numbers kept in the tree; under risk-based testing it runs when that structure changes, and in the full matrix at a milestone's end.

## 9. Open questions

1. **Lifetime dependencies are experimental.** §5 rule 6 relies on them. Until they are official, the fallback is closure-scoped access (`loop.withEvents { span in … }`), which gives the same guarantee with clumsier calls. Does `VX` ship that first and move later, or wait?
2. **Which types are frozen,** and is that list part of the ABI level (09 §4.8), or a separate promise?
3. **The macro's home.** Swift macros run at build time as a separate program. `./build` runs the pinned toolchain only (ADR-0034 §4); the `@Columns` macro's plug-in is first-party Swift built by `./build` itself, which needs saying in ADR-0034's build rules.
4. **An archetype store in `VXEngine`, or not.** The building blocks are certain; whether the base system also ships a store, and which one, waits for the first engine-tier program that needs it.
5. **Embedded Swift.** Drivers and boot-path servers use Embedded Swift with `-no-allocations` (ADR-0034 §2). `VXData`'s columns and pools work there if they are backed by arenas a server sets up at start; checking that is part of `VXData`'s first tests.

## 10. Sources

- Mike Acton, "Data-Oriented Design and C++", CppCon 2014 ([keynote](https://cppcon.org/third-keynote-2014/)).
- Casey Muratori, ["Clean" Code, Horrible Performance](https://www.computerenhance.com/p/clean-code-horrible-performance) (2023), and [on merging code paths](https://x.com/cmuratori/status/1925981691140505694?lang=en).
- Andrew Kelley's data-oriented work on Zig: [MultiArrayList](https://news.ycombinator.com/item?id=30617471), and [a practical guide](https://community.tmpdir.org/t/a-practical-guide-to-applying-data-oriented-design/560).
- [The Essence of Entity Component System](https://arxiv.org/html/2606.14919v1), ACM SAC '26.
- Bevy: [archetypes and storage](https://deepwiki.com/bevyengine/bevy/2.7-archetypes-and-storage), [ECS V2](https://github.com/bevyengine/bevy/pull/1525).
- Barry Revzin, [Implementing a Struct of Arrays](https://brevzin.github.io/c++/2025/05/02/soa/) (C++26 reflection).
- [Odin](https://en.wikipedia.org/wiki/Odin_(programming_language)); [soa_derive](https://docs.rs/soa_derive); [soa-rs](https://docs.rs/soa-rs/latest/soa_rs/).
- Apple: [Explore Swift performance](https://developer.apple.com/videos/play/wwdc2024/10217/) (WWDC24); [Improve memory usage and performance with Swift](https://developer.apple.com/videos/play/wwdc2025/312/) (WWDC25).
- Swift: [lifetime dependencies, experimental in 6.2](https://forums.swift.org/t/experimental-support-for-lifetime-dependencies-in-swift-6-2-and-beyond/78638); [SE-0465](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0465-nonescapable-stdlib-primitives.md); [performance annotations](https://forums.swift.org/t/performance-annotations/54441).
- RealityKit's ECS: [an overview](https://medium.com/macoclock/realitykit-911-entity-component-system-ecs-bfe0520e0e8e).
- In this tree: 09 §3–§4.8; 03 §6; study/shapes.md C9, C11, C12; ADR-0034; `swift-on-vectra`'s findings.md §8–§9.
