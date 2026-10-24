# D129. The UI libraries' pixel work goes through span kernels, one Swift source built once per D128 tier and chosen at startup, bit-exact with the scalar reference (2026-10-24, for the owner's review; extends D128, D110, D121)

D128 gives user code the CPU's tier and the libc a table of fast paths.
The UI libraries are where most of the CPU's pixel work is, and that
design doesn't reach them as it stands:
- **They are Swift, and mostly tier 0.** UICore (the display list and
  the CPU renderer), Light (D110's blends), the text stack (Raster,
  MSDF, GlyphAtlas, TextLayout) and Radharc's composer are tier 0
  Swift. Radharc links them statically; tier 1 programs bind them as
  shared libraries with Kit (D124). D128's fast paths are C23 in the
  libc, which tier 0 doesn't have.
- **Their interfaces are per pixel.** `PixelTarget` (text/layout)
  takes `blend(x, y, color, coverage)` one pixel at a time; `Light.over`
  blends one pixel through two table lookups a channel; the renderer
  (ui/core/lib/Render.swift) computes each shape's signed distance per
  pixel, in Double. Nothing is vectorized, and a per-pixel call can't be.
- **The CPU renderer is the reference and often the only renderer.**
  The GPU's compose shader is held to it (D121), check-pixels compares
  its frames, and it draws whatever has no GPU: every program today
  without UIGPU, the Sky1 until its Mali has a driver, and any board
  whose GPU never gets one.
- **Nothing measures it.** The desktop's frame budget,
  `theme.compose.4k`, is GPU time under Venus (D121; about 6-7 ms
  against 1.5, roadmap). No budget judges the CPU path, though D127's
  `frame_loop_loaded` row will measure it on the board.

## The decision

- **Span kernels.** The pixel work goes through one module,
  `PixelKernels` (ui/kernels), with a fixed set of operations on rows:
  - fill and copy a span (solid colour, and the composer's opaque
    windows);
  - blend a span in light, D110's `over` in its three forms (a colour
    at per-pixel coverage, premultiplied, straight) and `overText`;
  - coverage of a span from a shape's distance (the renderer's
    rounded, chamfered and cut boxes, and its border and glow bands);
  - sample a span from an atlas: coverage glyphs, distance-field
    glyphs (MSDF's median of three), and images, with bilinear filtering;
  - convert a span: sRGB to light and back, straight to premultiplied,
    and the pixel formats the display class and Loinnir's present copy
    take.

  A caller hands a whole row (or the part a clip leaves) with its
  counts, as principle 12 asks. `PixelTarget` gains span methods
  beside its pixel ones, which stay for code that needs one pixel.
  The renderer, Light's callers, the text stack's glyph drawing and
  Radharc's composer move onto spans; nothing else calls a kernel.
  It replaces the per-pixel loops in those four places; it adds no
  second renderer.
- **One source per tier, not one per arch.** The kernels are written
  once, in Swift's SIMD types (`SIMD8<UInt16>`, `SIMD8<Float>` and the
  like), with lanes converted by hand (the 6.4 pitfall: generic SIMD
  conversions don't inline across files). CMake builds the module once
  per D128 tier (floor, tier 2, tier 3) with that tier's target
  features, under the module names `PixelKernels_<tier>`, so their
  symbols differ by mangling and every copy links into the same
  image. Hand-written intrinsics or assembly come only for an
  operation where a tier's copy is measured short of a target, as C23
  in the same module, with its header naming the tier and the operation
  (the C rule's reason: Swift can't reach that instruction).
- **Chosen once, at startup, through the floor.** The floor reads
  D128's record from the topology page before `main` in tier 0 and
  tier 1 alike (system/sys/floor/Start.swift already reads the page),
  and `PixelKernels` fills a table of the operations from the highest
  tier the CPU meets. The table starts as the floor's copy, so anything
  drawn before it is filled is drawn right. No IFUNCs (D128).
- **Bit-exact with the scalar reference, at every tier.** The scalar
  code stays as the reference (`PixelKernels.reference`), and every
  tier's kernels produce the same bytes from the same inputs. The
  integer paths (fills, copies, Light's blends, its tables, format
  conversions) are exact by construction. The floating paths
  (distances, coverage, filtering) do the same operations in the same
  order in each lane, with FP contraction off, so a tier with FMA rounds
  as the floor does. This keeps check-pixels' references, and the GPU
  shader's comparison, independent of the CPU drawing them.
- **The reference may change, the kernels follow.** Moving the
  distances from Double to Float (twice the lanes, and the precision
  the GPU's shader has) or Light's encode table from a gather to a
  computed curve, is a change to the reference, made in the open, its
  pixel references regenerated in the same change, and then matched by
  every tier. A kernel never drifts from the reference on its own.
- **Measured on the CPU path.** A new budget, `ui.compose_cpu.1080p`,
  times Radharc composing a 1080p frame of the twelve windows
  `theme.compose.4k` uses, on the CPU, reported by boot-rio-kvm (an
  existing boot, not a new profile) and judged on the board at V6's
  exit beside D127's rows. Its limit is set from the floor tier's first
  run, and the kernels land with it. A tier that doesn't beat the floor
  on this budget is not built.
- **Tested at every tier.** A suite in user/test/swift checks each
  operation at each tier the CPU allows against the reference, over
  edges a vector width doesn't divide (a span of 1, of the width less
  one, unaligned starts) and the clip's corners. The floor runs D128
  names (`-cpu IvyBridge`, `cortex-a76`, `rva22s64`) draw the boot-rio
  pixels with the floor tier, `-cpu max` with the top one, against the
  same references.

## Not covered

- **The image codecs.** PNG's unfiltering and inflate, and JPEG's
  IDCT and colour conversion, are bulk work of the same kind, but the
  codecs (`codecs/image`) are manifests for now. When they decode, they
  join `PixelKernels`' tiers and table by the same rules, in their own
  module.
- **Crypto.** `crypto/lib` (SHA-2, BLAKE3, ChaCha20) is also tier 0
  Swift with tiers to gain (D53's AES and SHA on arm64), but it is not
  UI; it follows this pattern when it is measured short.
- **The GPU path.** UIGPU and Loinnir draw on the GPU; only Loinnir's
  present copy through the CPU uses a kernel here.

## Follow-ups, each its own change

D128's baselines and record first, then: `PixelKernels` with the
floor's copy and the reference, and the suite; the renderer, Light's
callers, text and the composer on spans; the per-tier builds and the
table; `ui.compose_cpu.1080p` and its row in docs/performance.md. The
UI libraries' man pages (D86) say what the kernels do and their limits
when they land.
