# Swift 6.4: what the release gives this tree

A review of the [Swift 6.4 release notes](https://www.swift.org/blog/swift-6.4-released/)
against the tree at `be07684`, 2026-11-20. Every claim about the compiler
was checked by compiling with the pinned 6.4.0 toolchain, in Embedded
(`aarch64-none-none-elf`, the kernel's flags) and on the host, unless it
is marked *not checked*. Nothing in the tree was changed.

The tree already uses most of 6.4's ownership work (`UniqueArray`,
`InlineArray`, spans, typed throws, `@c`), so the list is short.

## Summary

| # | Change | Sites | Verdict |
|---|--------|-------|---------|
| 1 | `RawSpan.load` for `unsafe ...unsafeLoadUnaligned` | 74 calls, 8 files | Do |
| 2 | One spelling for the little- and big-endian readers | about 60 helpers, about 25 files | Do |
| 3 | `if let` / `guard let` for `switch consume`, `x?.f()` for take and put back | 9 sites and the IPC macro | Do (not new in 6.4) |
| 4 | `for x in` over `UniqueArray` and `Span` | about 100 loops, nearly all kernel | Do, after one check; never on `InlineArray` |
| 5 | `any P?` without parentheses | 3 | Do |
| 6 | `@_cdecl` to `@c` | 4 | Do (*not checked*) |
| 7 | `borrow`/`mutate` accessors for the kernel's pointer wrappers | 44 | Don't |
| 8 | Everything else in the release notes | | Nothing to change |

Three lines of `docs/kernel/rules.md` and `CLAUDE.md` no longer match the
compiler; see the last section.

## 1. `RawSpan.load` replaces the unsafe loads (SE-0525)

`RawSpan` has `load(fromByteOffset:as:)`, safe and tolerant of
misalignment, and a form that takes a `ByteOrder` (`.littleEndian`,
`.bigEndian`). `MutableRawSpan.storeBytes` and `OutputRawSpan.append`
match it. `system/ipc/wire`, `lib/fdt`, `lib/dtacpi` and `lib/elf`
already use them (23 calls).

74 calls still use the unsafe spelling on a receiver that is already a
`RawSpan`, with an integer type:

    let base = unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 8, as: UInt64.self)
    let base = table.load(fromByteOffset: at + 8, as: UInt64.self)

| File | Calls |
|------|-------|
| `kernel/Kernel/Iommu/SmmuV3.swift` | 46 |
| `kernel/Kernel/Iommu/RiscvIommu.swift` | 14 |
| `kernel/Kernel/Iommu/AmdIommu.swift` | 5 |
| `kernel/Kernel/Iommu/IntelIommu.swift` | 4 |
| `kernel/Kernel/Acpi/Mcfg.swift` | 2 |
| `kernel/Kernel/Object/Dma.swift`, `Iommu/SmmuV2.swift`, `user/lib/loader/Linked.swift:338` | 1 each |

The generated code is the same: at `-Osize` on arm64 the linker folds the
two into one body (a bounds check and one `ldr`), since
`unsafeLoadUnaligned(fromByteOffset:)` checks bounds too. The change
removes 74 `unsafe` markers and nothing else. The kernel was not built
with it; the calls were compiled in scratch only.

What can't move:

- **Structs.** `load` takes only the standard library's own types
  (integers, floats, SIMD vectors, `InlineArray` of those). A Swift
  struct, a C struct or an enum is refused, and so is a conformance of our
  own ("must be defined in the standard library module"). Eight loads of
  `croi_*_t` and descriptor structs stay unsafe
  (`IntelIommu.swift:98`, `:108`, `AmdIommu.swift:64`, `:69`,
  `DebugLog.swift:110`, `ProgramSelfTest.swift:60`,
  `DebuglogSuite.swift:79`, `:120`).
- **Shared and device memory**, 171 calls: ring slots, Node's bulk slots,
  DMA pages, the libc's C structures, the thread block. A raw pointer is
  the honest type there.
- 72 calls on raw pointers to ordinary memory could become spans first.
  That is a larger change for each, and about 16 of them load structs.
  The two that are simple are `fs/taisce/lib/Node.swift:142-149` and
  `system/trace/reader/TraceReader.swift:43-44`; the second was tried and
  builds. It traps on a trace shorter than the read, where today's code
  reads past the end in a release build.

## 2. One spelling for the byte readers (SE-0525)

About 78 helpers in about 30 files assemble integers from bytes by hand,
each file with its own `le16`, `le32`, `u64` and so on. The readers
(about 60) all reduce to one call:

    // drivers/bus/acpi/lib/Tables.swift:58
    func le32(_ at: Int) -> UInt32 { UInt32(le16(at)) | UInt32(le16(at + 2)) << 16 }
    func le32(_ at: Int) -> UInt32 { span.bytes.load(fromByteOffset: at, as: UInt32.self, .littleEndian) }

This compiles in Embedded and on the host, with no copy of the array.
Under principle 1 the helpers could go altogether, or become one shared
extension; which is a design choice. Readers are in
`drivers/bus/acpi/lib/Tables.swift:58`, `drivers/usb/lib/Descriptors.swift:285`,
`drivers/virtio/lib/Devices.swift:94`, `Transport.swift:45`,
`drivers/display/virtio-gpu/lib/GPU.swift:108`, `crypto/lib/ChaCha20.swift:22`,
`fs/taisce/lib/Send.swift:76`, `IntentLog.swift:125`, `Inode.swift:128`,
`graphics/venus/lib/Wire.swift:167`, `driver/Context.swift:89`,
`services/9gate` `Fcall.swift:530`, `services/ndb` `Message.swift:268`,
`services/net/lib/Wire.swift:9`, `text/opentype` `Bytes.swift:55`,
`tools/image/lib/Bytes.swift:14`, `tools/dtc` `Tree.swift:252`,
`ui/access` `AccessTree.swift:150`, and copies in three test files.

The writers that append to a growing `[UInt8]` (about 17, such as
`fs/taisce/lib/Send.swift:46`) should stay. No raw output span exists
over an array, and the form that compiles (reserve, take
`mutableSpan.mutableBytes`, `storeBytes`) is longer than the loop it
would replace. Writers into a fixed buffer already use `storeBytes`.

Venus's generated protocol isn't affected: its byte code is the
hand-written `graphics/venus/lib/Wire.swift`, whose generic
`raw<T: BitwiseCopyable>` can't take the new constraint because the
generated callers pass enums and flags.

## 3. Non-copyable optionals without the workarounds

SE-0532 (`Optional.ref`, `.mutableRef`, `put`) is in the release notes
but **not in the 6.4.0 standard library**: `value of type 'H?' has no
member 'mutableRef'`. What the tree's workarounds need already compiles,
on 6.2.3 and 6.3.2 as well, so this is a cleanup the release prompted
rather than one it enabled.

**`switch consume x`** becomes `if let` or `guard let` when `x` is a
consumed parameter or a local:

    switch consume ctl {
    case .some(let h): control = NodeIPC.NodeClient(channel: h)
    case .none: control = nil
    }

    if let h = ctl { control = NodeIPC.NodeClient(channel: h) } else { control = nil }

Sites: `services/fs/server/Device.swift:55`, `:60`;
`system/fdio/lib/FDIO.swift:618`; `system/node/lib/Client.swift:27` (the
`let node = done.node` temporary goes too);
`system/node/lib/Namespace.swift:242`;
`system/ipc/macros/Generator.swift:325`.

**The IPC macro's generator** (`Generator.swift:85`) emits
`let oN = value; switch consume oN { ... }` for a non-copyable optional
and `if let` for a copyable one. The `if let` works for both, so the
`isCopyable` split and its comment go: 13 lines become 3. It is safe
because the struct encoder is `consuming`; it would fail for a
`borrowing` struct, which the macro never emits for such fields.

**Take, use, put back** becomes a use in place:

    guard var f = file.take() else { return .failure(Errno.io) }   // FDIO.swift:230
    let r = body(&f); file = consume f; return r

    guard file != nil else { return .failure(Errno.io) }
    return body(&file!)

Sites: `system/fdio/lib/FDIO.swift:230`,
`shell/tracker/app/Feed.swift:119-130`. The other `take()` calls on
optionals are real moves and stay.

All of the above was applied as a trial: `Node`, `FDIO`, `FsServer`,
`Fs`, `Radharc`, `DisplayDevice` and `TrackerApp` build, and
`IPCMacrosTests` passes (its tests don't reach the changed branch;
compiling `Node` and `Radharc` with the changed macro does). The trial is
`/private/tmp/claude-501/-Users-jkane-Projects-OS-VectraOS/b1e8ebc2-0416-4f69-9064-c6c94cf6b514/scratchpad/s/spike.patch`
(a session scratch directory; it will not survive a reboot).

Limits found: `if let` on an optional reached through a borrow or a
pointer is refused ("is borrowed and cannot be consumed"); `switch`
without `consume` works there and binds a borrow. `map` on a
non-copyable optional is refused; only the underscored `_consumingMap`
compiles.

## 4. `for x in` over `UniqueArray` and `Span` (SE-0516)

`Span`, `RawSpan`, `MutableSpan`, `InlineArray` and `UniqueArray` conform
to the new `Iterable`, so `for`-`in` works on them, with `where`,
`break`, `continue` and typed throws, for copyable and non-copyable
elements, and through `p.pointee.items`.

Of the tree's 328 index loops, about 100 use the index only to read the
one collection, and nearly all of those are kernel loops over a
`UniqueArray`:

    for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].base == base {
        return record.pointee.mappings[i].size                 // UserAspace.swift:390
    }
    for m in record.pointee.mappings where m.base == base { return m.size }

    for i in 0..<freed.count { pmm.free(freed[i]) }            // Pager.swift:733, Vmo.swift:1017
    for page in freed { pmm.free(page) }

Most are in `Vm/UserAspace.swift` (12), `Vm/Reclaim.swift` (12),
`User/InfoTopics.swift` (11), `Object/Pager.swift` (10),
`Object/Process.swift` (9), `Vm/Vmo.swift` (7), `Object/Debug.swift` (5).
The count comes from a classifier over all 328 with about 60 read by
hand; 30 of the 100 rest on a collection type that was inferred. The
other 220 need the index (parallel arrays, writes in place, a count that
isn't the collection's).

Three things to know before doing it:

- **Not on `InlineArray`.** `for x in table` copies the whole array to
  the stack first: a 2 KB table reached through a pointer got a 2 KB
  frame and a `memcpy`, where the indexed loop had neither. The kernel's
  15 `InlineArray` loops stay indexed. Converting two such loops in
  `lib/dtacpi` grew its text by 664 bytes.
- **The loop's setup is larger.** Over a span, 24 instructions against 9
  at `-Osize`: more trap checks and a chunked outer loop. The inner loop
  is the same load, add and branch. No calls, no allocation, no ARC.
- **Exclusivity is not checked in the kernel**
  (`-enforce-exclusivity=unchecked`, `cmake/toolchain.cmake`). With
  checking on, changing the array inside the loop is a compile error. The
  spike did not test the kernel's setting, so a loop whose body, or a
  callee, appends to or removes from the array through the pointer may
  compile and then iterate freed storage. The indexed loops re-read
  `count` each pass and are safe against that. Check this before
  converting, and convert only loops whose bodies can't reach the array.

Missing on these types: `enumerated()`, `reversed()`, `zip`, `contains`,
`first(where:)`, `reduce`. And `for x in a.span` or
`for x in s.extracting(1..<3)` is refused ("lifetime-dependent variable
escapes its scope"); bind the span to a local first.

## 5. `any P?` (SE-0521)

New in 6.4 (6.3.2 refuses it). Three sites:

    var presentation: (any LoinnirPresentation)?       // graphics/loinnir/lib/Loinnir.swift:33
    var presentation: any LoinnirPresentation?

    var connect: (() -> (any VenusTransport)?)?        // graphics/venus/driver/Driver.swift:15, :28
    var connect: (() -> any VenusTransport?)?

## 6. `@_cdecl` to `@c`

`lib/ring/check/Checker/Checker.swift:474-490` has the tree's last four
`@_cdecl("name")`. The rest of the tree spells this `@c(name)` (593
uses). *Not checked* in this target.

## 7. Borrow and mutate accessors (SE-0507): leave the wrappers alone

The kernel's 44 pointer wrappers are

    var pointee: IoDomain {
        unsafeAddress { unsafe UnsafePointer<IoDomain>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<IoDomain>(bitPattern: UInt(address))! }
    }

`borrow` and `mutate` need no flag, but they may return only a stored
property, another such accessor or a global `let`. Through a raw address
they are refused ("invalid return value from a borrow accessor") unless
both carry `@_unsafeSelfDependentResult`, the attribute the standard
library uses for `MutableRef.value`:

    @_unsafeSelfDependentResult borrow { unsafe UnsafePointer<IoDomain>(bitPattern: UInt(address))!.pointee }
    @_unsafeSelfDependentResult nonmutating mutate { unsafe &UnsafeMutablePointer<IoDomain>(bitPattern: UInt(address))!.pointee }

With that, `IoDomainPointer` was converted and the arm64 kernel built
and passed the no-ARC, OptionSet and AMO checks, with no new `memcpy`.
The kernel grew 6.8 KB from different inlining in ten functions; speed
was not measured.

It isn't worth doing: the lines get longer, no call site changes, one
underscored spelling replaces another, and the kernel grows.

`ui/core/lib/Chrome.swift:116` (`get` with `nonmutating _modify`, the
tree's only `_modify`) could take the same form and lose the copy its
`get` makes, at the same price of the attribute. Optional.

No property in the tree returns a `Span`, so the accessors' advertised
use doesn't arise. The closure-taking helpers (`withEnvironment`,
`withPhysicalBytes`, `Locked.withLock`, `withSnapshot`) need to run code
after the body and can't become accessors.

## 8. Nothing to change

| Release note | Why not |
|--------------|---------|
| `Ref`, `MutableRef` (SE-0519) | In the library and they compile in Embedded. Every stored pointer in the tree outlives a scope (firmware protocols, cache arrays, C records, shared pages), so none is a borrow. |
| `Optional` views (SE-0532) | Not in 6.4.0; see 3. |
| Non-copyable `Equatable`, `Comparable`, `Hashable` (SE-0499) | Works, but no `~Copyable` type in the tree has a hand-written comparison. `Optional<K> == Optional<K>`, `min` and `CustomStringConvertible` are still refused. |
| `withTemporaryAllocation` with a span (SE-0524) | 42 scratch buffers are scope-bounded, but each feeds a raw-pointer interface (rings, queues, syscalls, the libc under test), so the pointer and its `unsafe` stay; most are over 1024 bytes and would take the heap path. The loader's ban stands for runtime sizes. |
| Module selectors (SE-0491) | `Sys.Thread`, `Radharc.Rect` and the like already read well with a dot, and none needs `::` to compile. Also accepted by 6.3.2. |
| `@diagnose` (SE-0522) | Warnings are set by group on the command line and nothing in the sources silences one. |
| Embedded existentials | The kernel forbids them (no ARC) and already builds with `-Werror EmbeddedRestrictions`. |
| `@c` safe wrappers, `Span` to `std::span` | The C boundary is libc and Vulkan ABI, fixed by C headers; no C++ on the device. |
| Async `defer`, cancellation shields | No async code in the tree. |
| Subprocess 1.0 | Would replace nine `Process()` uses in tests at the cost of a second SwiftPM dependency. |
| Swift Testing, `Observable`, ProgressManager, SBOMs, Swift Build, debug info, Java, Wasm, Android | No XCTest to migrate; a flaky check is removed, not repeated; the rest doesn't touch the tree. |

## Corrections to our own notes

Found while checking; each is a doc change, none was made.

- `docs/kernel/rules.md`, Conventions: "Reading a `~Copyable` value
  through an `unsafeAddress` accessor makes the owner unconsumable
  afterwards in 6.4.0; use `_read { yield ... }`". The tree has no
  `_read`, all 44 wrappers use `unsafeAddress`, and the failure did not
  reproduce in 6.4.0 across seven shapes. Either the note is stale or it
  needs its reproducer recorded.
- The same paragraph: "`borrow` accessors can't return through a raw
  pointer's `pointee`" is still true, and could add that
  `@_unsafeSelfDependentResult` lifts it.
- `CLAUDE.md`, Toolchain pitfalls: "`#expect` and `#require` can't take
  an expression on a `~Copyable` value" still holds in 6.4.0, now with
  `Equatable` operands too (`requires that 'K' conform to
  'BidirectionalCollection'`).
- `UnsafeRawBufferPointer.loadUnaligned` is no longer `@unsafe`, so
  `unsafe $0.loadUnaligned(...)` inside `withUnsafeBytes` draws "no
  unsafe operations occur within 'unsafe' expression". The sites were
  not counted.
- On this Mac, `swift test --filter` builds every test product and stops
  at `graphics/vulkan`'s tests ("unable to resolve module dependency:
  'Glibc'"), so the spikes' host tests were run only for
  `IPCMacrosTests`, built alone.
- swift.org lists 6.4.2; the tree pins 6.4.0. Whether 6.4.2 changes any
  pitfall above was not looked at.
